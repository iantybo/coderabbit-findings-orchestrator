#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  ${script_name} [--summary] [--ttl-minutes N] [--output FILE] [INPUT_FILE]
  ${script_name} --remove-id ISSUE_ID [--output FILE]
  ${script_name} --claim-lock DIR --agent NAME [--ttl-minutes N]
  ${script_name} --check-lock DIR
  ${script_name} --release-lock DIR [--agent NAME]
  ${script_name} --sign-up
  ${script_name} --my-dirs --agent NAME
  ${script_name} --claim-next --agent NAME [--ttl-minutes N]
  ${script_name} --takeover DEAD_AGENT_ID --agent NEW_AGENT_ID
  ${script_name} --adopt-abandoned --agent NAME
  ${script_name} --clear-all-locks
  ${script_name} --print-agent-prompt [--output FILE] [--ttl-minutes N]
  ${script_name} --status [--output FILE]
  ${script_name} --clean

Default behavior:
  - Parse CodeRabbit output
  - Sort findings by directory/file/line
  - Write markdown report to sorted-coderabbit-findings.md
  - Write .agent-dir-list with ordered directory names

Agent sign-up:
  Each agent runs --sign-up to claim the next available agent number.
  The sign-up sheet (.agent-signup-sheet) is created in the current directory.
  Returns the assigned agent number (e.g., "agent-1", "agent-2", ...).
  The --agent value for all subsequent commands MUST match a sign-up sheet entry.

Agent directory assignment:
  --my-dirs   Lists the directories assigned to this agent (based on agent number
              and total agent count). No manual math needed.
  --claim-next  Claims the next available directory. Tries the agent's own lane
                first, then steals from ANY unclaimed/unlocked directory globally.
                Agents never stop while work remains.

Status:
  --status    Show a table of all findings with their done/not-done status.
              Auto-finds the latest sorted-coderabbit-findings-*.md file,
              or use --output FILE to specify a specific report.

Clean:
  --clean     Full reset: removes all locks, signup sheet, sorted findings
              files, and the agent directory list.

Human override:
  --clear-all-locks   Removes ALL .agent.lock files, the signup sheet lock,
                      and the signup sheet itself. Use this to reset the entire
                      agent coordination state (e.g., between runs).

Agent takeover (for recovering from failed agents):
  --takeover DEAD_AGENT_ID --agent NEW_AGENT_ID
              Inherits the dead agent's lane number and directory assignments.
              The new agent replaces the dead agent on the signup sheet,
              transfers or removes locks, and updates done files.
  --adopt-abandoned --agent NAME
              Scans ALL directories for expired locks (regardless of lane).
              Claims the first expired-lock directory found. Use this as a
              simpler fallback when you just want to grab any orphaned work.

Examples:
  ${script_name} coderabbit.txt
  coderabbit review --plain --no-color --type all --base main | ${script_name}
  ${script_name} --remove-id CR-a1b2c3d4
  ${script_name} --claim-lock internal/service --agent agent-1 --ttl-minutes 50
  AGENT_ID=\$(${script_name} --sign-up)
  ${script_name} --my-dirs --agent "\$AGENT_ID"
  DIR=\$(${script_name} --claim-next --agent "\$AGENT_ID")
  ${script_name} --status
  ${script_name} --clean
USAGE
}


summary_only=0
input="-"
output_file="sorted-coderabbit-findings-$(date -u '+%Y-%m-%dT%H%M%SZ').md"
ttl_minutes=50
agent=""
claim_dir=""
check_dir=""
release_dir=""
remove_id=""
sign_up_only=0
print_agent_prompt_only=0
my_dirs_only=0
claim_next_only=0
takeover_target=""
adopt_abandoned_only=0
clear_all_locks_only=0
status_only=0
clean_only=0

script_name="$(basename "$0")"
signup_sheet=".agent-signup-sheet"
dir_list_file=".agent-dir-list"
done_issues_file=".agent-done-issues"

sign_up_agent() {
  local sheet="$signup_sheet"
  local lock="${sheet}.lock"
  local next_num
  local agent_id

  # Simple file-based spinlock for atomicity
  local attempts=0
  local stale_lock_threshold=30  # seconds before considering lock stale
  while ! (set -C; echo $$ > "$lock") 2>/dev/null; do
    attempts=$((attempts + 1))
    if [[ "$attempts" -ge 50 ]]; then
      # Stale lock - verify staleness before removing
      # Check if lock file still exists
      if [[ -f "$lock" ]]; then
        local lock_pid lock_mtime lock_now
        # Read PID from lock file
        lock_pid="$(cat "$lock" 2>/dev/null || true)"
        # Check if PID is alive
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
          # Process is still running, don't remove - another agent holds the lock
          sleep 0.1
          continue
        fi
        # Check file mtime against staleness threshold
        lock_mtime="$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo 0)"
        lock_now="$(date +%s)"
        if [[ "$lock_now" -lt "$((lock_mtime + stale_lock_threshold))" ]]; then
          # Lock is not stale yet, wait and retry
          sleep 0.1
          continue
        fi
      fi
      # Lock is truly stale - file gone, PID dead, and mtime indicates staleness
      rm -f "$lock"
    fi
    sleep 0.1
  done
  trap 'rm -f "$lock"' EXIT

  if [[ ! -f "$sheet" ]]; then
    echo "# Agent Sign-Up Sheet" > "$sheet"
    echo "# Each line: agent-N <random-id> <timestamp>" >> "$sheet"
  fi

  local current_count
  current_count="$(grep -c '^agent-' "$sheet" 2>/dev/null || true)"
  : "${current_count:=0}"
  next_num=$(( current_count + 1 ))
  agent_id="agent-${next_num}"
  local rand_id
  rand_id="$(gen_random_hex8)"
  echo "${agent_id} ${rand_id} $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$sheet"

  rm -f "$lock"
  trap - EXIT

  echo "$agent_id"
}

epoch_to_iso() {
  local epoch="$1"
  date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ'
}

lock_path_for_dir() {
  local dir="$1"
  printf "%s/.agent.lock" "${dir%/}"
}

read_lock_field() {
  local file="$1"
  local key="$2"
  awk -F '=' -v k="$key" '$1 == k { sub(/^[[:space:]]+/, "", $2); print $2; exit }' "$file"
}

acquire_spinlock() {
  local lock="$1"
  local stale_lock_threshold="${2:-30}"
  local attempts=0

  while ! (set -C; echo $$ > "$lock") 2>/dev/null; do
    attempts=$((attempts + 1))
    if [[ "$attempts" -ge 50 ]]; then
      if [[ -f "$lock" ]]; then
        local lock_pid lock_mtime lock_now
        lock_pid="$(cat "$lock" 2>/dev/null || true)"
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
          sleep 0.1
          continue
        fi
        lock_mtime="$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo 0)"
        lock_now="$(date +%s)"
        if [[ "$lock_now" -lt "$((lock_mtime + stale_lock_threshold))" ]]; then
          sleep 0.1
          continue
        fi
      fi
      rm -f "$lock"
    fi
    sleep 0.1
  done
}

release_spinlock() {
  local lock="$1"
  rm -f "$lock"
}

print_agent_prompt() {
  cat <<PROMPT
You are a CodeRabbit findings agent. Your job: fix code issues found by
CodeRabbit, one directory at a time, until every finding is resolved.

SETUP (run once):
  AGENT_ID=\$(./${script_name} --sign-up)

WORK LOOP (repeat until ALL_DONE):
  1. Claim next directory:
     DIR=\$(./${script_name} --claim-next --agent "\$AGENT_ID")
     - Tries your assigned lane first, then steals unclaimed work globally.
     - If output is empty or says ALL_DONE, you are finished.

  2. Verify lock:
     ./${script_name} --check-lock "\$DIR"

  3. Read ${output_file} and fix ONLY findings in "\$DIR".
     - Read each finding's prompt carefully. It tells you what to change.
     - Verify the issue exists before fixing (CodeRabbit can have false positives).
     - Make the minimal correct fix. Do not refactor unrelated code.
     - write tests before updating code if required
     - only focus on critical or major issues
     - ensure tests pass
     - ensure the app compiles frequently as long as no other agents are working on it, so look at the agents that have locks and if that code will be compiled, if it does not, pause the fix, and try a new approach
     - never read coderabbit-raw.txt

  4. After fixing each finding, mark it done:
     ./${script_name} --remove-id <ISSUE_ID> --output ${output_file}

  5. Release the directory when all its findings are fixed:
     ./${script_name} --release-lock "\$DIR" --agent "\$AGENT_ID"

  6. Go to step 1.

RULES:
  - NEVER skip a finding without fixing it or confirming it's a false positive.
  - If you finish your lane's directories, --claim-next automatically picks up
    unclaimed directories from other lanes. You do NOT stop early.
  - Lock TTL is ${ttl_minutes} minutes. If you need more time, re-claim the dir.
  - If blocked on a directory, release its lock so others can take it.
  - The --agent value MUST be the exact ID returned by --sign-up.
  - Focus on critical findings first that are related to production code
  - Less critical findings are things like docs, and admin files like Makefiles etc.

RECOVERY (if another agent died):
  ./${script_name} --adopt-abandoned --agent "\$AGENT_ID"
  Or: ./${script_name} --takeover "<dead-agent-id>" --agent "\$AGENT_ID"
PROMPT
}

check_lock_common() {
  local dir="$1"
  local lock_file
  local now
  local owner
  local expires_epoch
  local expires_iso

  lock_file="$(lock_path_for_dir "$dir")"
  now="$(date +%s)"

  if [[ ! -f "$lock_file" ]]; then
    echo "UNLOCKED: $dir"
    return 1
  fi

  owner="$(read_lock_field "$lock_file" owner)"
  expires_epoch="$(read_lock_field "$lock_file" expires_epoch)"
  expires_iso="$(read_lock_field "$lock_file" expires_iso)"

  if [[ -z "$expires_epoch" ]]; then
    echo "EXPIRED: $dir (owner=${owner:-unknown}, expired_at=${expires_iso:-unknown}, expires_epoch=empty)"
    return 2
  fi

  # Validate that expires_epoch is a numeric integer
  if ! [[ "$expires_epoch" =~ ^[0-9]+$ ]]; then
    echo "EXPIRED: $dir (owner=${owner:-unknown}, expires_epoch=$expires_epoch (non-numeric), expires_iso=${expires_iso:-unknown})"
    return 2
  fi

  if [[ "$expires_epoch" -le "$now" ]]; then
    echo "EXPIRED: $dir (owner=${owner:-unknown}, expired_at=${expires_iso:-unknown})"
    return 2
  fi

  echo "LOCKED: $dir (owner=${owner:-unknown}, expires_at=${expires_iso:-unknown})"
  return 0
}

claim_lock() {
  local dir="$1"
  local lock_file
  local now
  local expires
  local created_iso
  local expires_iso
  local owner
  local claim_guard
  local tmp_lock

  if [[ -z "$agent" ]]; then
    echo "--agent is required with --claim-lock" >&2
    return 1
  fi

  validate_agent_on_sheet "$agent" || return 1

  if ! [[ "$ttl_minutes" =~ ^[0-9]+$ ]] || [[ "$ttl_minutes" -le 0 ]]; then
    echo "--ttl-minutes must be a positive integer" >&2
    return 1
  fi

  mkdir -p "$dir"
  lock_file="$(lock_path_for_dir "$dir")"
  claim_guard="${lock_file}.claiming"

  acquire_spinlock "$claim_guard"

  now="$(date +%s)"
  if [[ -f "$lock_file" ]]; then
      owner="$(read_lock_field "$lock_file" owner)"
      if check_lock_common "$dir" >/dev/null 2>&1; then
        if [[ "$owner" != "$agent" ]]; then
          check_lock_common "$dir"
          echo "Cannot claim lock: held by $owner" >&2
          release_spinlock "$claim_guard"
          return 1
        fi
      fi
  fi

  expires=$((now + ttl_minutes * 60))
  created_iso="$(epoch_to_iso "$now")"
  expires_iso="$(epoch_to_iso "$expires")"
  tmp_lock="${lock_file}.tmp.$$.$RANDOM"

  if ! {
    echo "owner=$agent"
    echo "created_epoch=$now"
    echo "created_iso=$created_iso"
    echo "expires_epoch=$expires"
    echo "expires_iso=$expires_iso"
    echo "ttl_minutes=$ttl_minutes"
  } > "$tmp_lock"; then
    rm -f "$tmp_lock"
    release_spinlock "$claim_guard"
    echo "Cannot write temporary lock file: $tmp_lock" >&2
    return 1
  fi

  if ! mv "$tmp_lock" "$lock_file"; then
    rm -f "$tmp_lock"
    release_spinlock "$claim_guard"
    echo "Cannot install lock file: $lock_file" >&2
    return 1
  fi

  release_spinlock "$claim_guard"

  echo "LOCKED: $dir (owner=$agent, expires_at=$expires_iso)"
}

release_lock() {
  local dir="$1"
  local lock_file
  local owner

  lock_file="$(lock_path_for_dir "$dir")"

  if [[ ! -f "$lock_file" ]]; then
    echo "UNLOCKED: $dir"
    return 0
  fi

  if [[ -n "$agent" ]]; then
    owner="$(read_lock_field "$lock_file" owner)"
    if [[ -n "$owner" && "$owner" != "$agent" ]]; then
      echo "Cannot release lock for $dir: owned by $owner" >&2
      exit 1
    fi
  fi

  # Mark directory as done (agent finished their work here)
  if [[ -n "$agent" ]]; then
    local done_file
    done_file="$(done_path_for_dir "$dir")"
    {
      echo "completed_by=$agent"
      echo "completed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } > "$done_file"
  fi

  rm -f "$lock_file"
  echo "RELEASED: $dir (marked done)"
}

done_path_for_dir() {
  local dir="$1"
  printf "%s/.agent.done" "${dir%/}"
}

is_dir_done() {
  local dir="$1"
  local done_file
  done_file="$(done_path_for_dir "$dir")"
  [[ -f "$done_file" ]]
}

gen_random_hex8() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 4
  else
    LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 8
    echo
  fi
}

validate_agent_on_sheet() {
  local agent_name="$1"
  if [[ ! -f "$signup_sheet" ]]; then
    echo "No sign-up sheet found. Run --sign-up first." >&2
    return 1
  fi
  if ! grep -q "^${agent_name} " "$signup_sheet" 2>/dev/null; then
    echo "Agent '${agent_name}' not found on sign-up sheet (${signup_sheet}). Run --sign-up first." >&2
    return 1
  fi
  return 0
}

get_agent_number() {
  local agent_name="$1"
  # Extract N from "agent-N"
  echo "${agent_name#agent-}"
}

get_total_agents() {
  grep -c '^agent-' "$signup_sheet" 2>/dev/null || echo 0
}

get_dir_list() {
  if [[ ! -f "$dir_list_file" ]]; then
    echo "No directory list found (${dir_list_file}). Run the report generator first." >&2
    return 1
  fi
  cat "$dir_list_file"
}

get_my_dirs() {
  local agent_name="$1"
  local agent_num total_agents dir_index

  validate_agent_on_sheet "$agent_name" || exit 1

  agent_num="$(get_agent_number "$agent_name")"
  total_agents="$(get_total_agents)"

  if [[ "$total_agents" -eq 0 ]]; then
    echo "No agents registered." >&2
    exit 1
  fi

  dir_index=0
  while IFS= read -r dir; do
    dir_index=$((dir_index + 1))
    # agent-N gets dirs where ((pos-1) % total) + 1 == N
    local assigned=$(( (dir_index - 1) % total_agents + 1 ))
    if [[ "$assigned" -eq "$agent_num" ]]; then
      echo "$dir"
    fi
  done < <(get_dir_list)
}

try_claim_from_list() {
  local agent_name="$1"
  local dir_source="$2"

  while IFS= read -r dir; do
    if is_dir_done "$dir"; then
      continue
    fi

    local lock_file
    lock_file="$(lock_path_for_dir "$dir")"
    if [[ -f "$lock_file" ]]; then
      local owner
      owner="$(read_lock_field "$lock_file" owner)"
      if check_lock_common "$dir" >/dev/null 2>&1; then
        if [[ "$owner" == "$agent_name" ]]; then
          echo "$dir"
          return 0
        fi
        continue
      fi
    fi
    agent="$agent_name"
    if claim_lock "$dir" >&2; then
      echo "$dir"
      return 0
    fi
  done <<< "$dir_source"

  return 1
}

claim_next_dir() {
  local agent_name="$1"

  validate_agent_on_sheet "$agent_name" || exit 1

  # Phase 1: try own lane first
  local my_dirs
  my_dirs="$(get_my_dirs "$agent_name")"
  if [[ -n "$my_dirs" ]]; then
    local result
    if result="$(try_claim_from_list "$agent_name" "$my_dirs")"; then
      echo "$result"
      return 0
    fi
  fi

  # Phase 2: work-steal — scan ALL directories for anything unclaimed/expired
  local all_dirs
  all_dirs="$(get_dir_list)"
  if [[ -n "$all_dirs" ]]; then
    local result
    if result="$(try_claim_from_list "$agent_name" "$all_dirs")"; then
      echo "STEAL: $result" >&2
      echo "$result"
      return 0
    fi
  fi

  echo "ALL_DONE: No more directories to claim for ${agent_name}." >&2
  return 0
}

takeover_agent() {
  local new_agent="$1"
  local dead_agent="$2"

  validate_agent_on_sheet "$new_agent" || exit 1
  validate_agent_on_sheet "$dead_agent" || exit 1

  if [[ "$new_agent" == "$dead_agent" ]]; then
    echo "Cannot takeover yourself." >&2
    exit 1
  fi

  # Extract the dead agent's number (the lane we want to inherit)
  local dead_num
  dead_num="$(get_agent_number "$dead_agent")"

  # Replace dead agent's line with new agent keeping the same agent-N number
  local dead_line new_line
  dead_line="$(grep "^${dead_agent} " "$signup_sheet")"
  # Build new line: keep agent-N number from dead agent, use new agent's random id
  local new_rand new_ts
  new_rand="$(gen_random_hex8)"
  new_ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  new_line="agent-${dead_num} ${new_rand} ${new_ts} (takeover: ${new_agent} replaced ${dead_agent})"

  # Replace dead agent's line in signup sheet
  local tmp_sheet
  tmp_sheet="$(mktemp)"
  sed "s|^${dead_agent} .*|${new_line}|" "$signup_sheet" > "$tmp_sheet"
  # Remove the new agent's original signup line (they're now using the dead agent's slot)
  sed -i.bak "/^${new_agent} /d" "$tmp_sheet"
  rm -f "${tmp_sheet}.bak"
  mv "$tmp_sheet" "$signup_sheet"

  # Scan directories for locks and done files owned by dead agent
  if [[ -f "$dir_list_file" ]]; then
    local inherited_dirs=()
    while IFS= read -r dir; do
      local lock_file done_file
      lock_file="$(lock_path_for_dir "$dir")"
      done_file="$(done_path_for_dir "$dir")"

      # Transfer or remove locks
      if [[ -f "$lock_file" ]]; then
        local owner
        owner="$(read_lock_field "$lock_file" owner)"
        if [[ "$owner" == "$dead_agent" ]]; then
          if check_lock_common "$dir" >/dev/null 2>&1; then
            # Active lock - transfer ownership
            sed -i.bak "s|^owner=${dead_agent}$|owner=agent-${dead_num}|" "$lock_file"
            rm -f "${lock_file}.bak"
            inherited_dirs+=("$dir (lock transferred)")
          else
            # Expired lock - remove it
            rm -f "$lock_file"
            inherited_dirs+=("$dir (expired lock removed)")
          fi
        fi
      fi

      # Transfer done files
      if [[ -f "$done_file" ]]; then
        local completed_by
        completed_by="$(read_lock_field "$done_file" completed_by)"
        if [[ "$completed_by" == "$dead_agent" ]]; then
          sed -i.bak "s|^completed_by=${dead_agent}$|completed_by=agent-${dead_num}|" "$done_file"
          rm -f "${done_file}.bak"
        fi
      fi
    done < "$dir_list_file"

    echo "TAKEOVER: agent-${dead_num} lane inherited by ${new_agent} (replaced ${dead_agent})"
    if [[ ${#inherited_dirs[@]} -gt 0 ]]; then
      echo "Inherited directories:"
      for d in "${inherited_dirs[@]}"; do
        echo "  $d"
      done
    fi
  else
    echo "TAKEOVER: agent-${dead_num} lane inherited by ${new_agent} (replaced ${dead_agent})"
    echo "Warning: no directory list found, no locks to transfer."
  fi

  echo ""
  echo "Use 'agent-${dead_num}' as your --agent value for all subsequent commands."
}

adopt_abandoned_dir() {
  local agent_name="$1"

  validate_agent_on_sheet "$agent_name" || exit 1

  if [[ ! -f "$dir_list_file" ]]; then
    echo "No directory list found (${dir_list_file}). Run the report generator first." >&2
    exit 1
  fi

  while IFS= read -r dir; do
    if is_dir_done "$dir"; then
      continue
    fi

    local lock_file
    lock_file="$(lock_path_for_dir "$dir")"

    if [[ -f "$lock_file" ]]; then
      # Skip actively locked dirs
      if check_lock_common "$dir" >/dev/null 2>&1; then
        continue
      fi
    fi

    # Unlocked or expired lock — try to claim
    agent="$agent_name"
    if claim_lock "$dir" >&2; then
      echo "$dir"
      return 0
    fi
  done < "$dir_list_file"

  echo "NO_ABANDONED: No available directories found." >&2
  return 0
}

find_latest_sorted_findings() {
  ls -t sorted-coderabbit-findings-*.md 2>/dev/null | head -1
}

show_status() {
  local file="$output_file"

  # If output_file is the default (timestamped), find the latest one
  if [[ "$file" == sorted-coderabbit-findings-*.md ]]; then
    file="$(find_latest_sorted_findings)"
  fi

  if [[ -z "$file" || ! -f "$file" ]]; then
    echo "No findings report found. Run the report generator first." >&2
    exit 1
  fi

  local total=0 done_count=0 pending_count=0
  local rows=()

  # Collect done issues from ledger
  if [[ -f "$done_issues_file" ]]; then
    while IFS=$'\t' read -r id typ fpath line_info completed_at; do
      total=$((total + 1))
      done_count=$((done_count + 1))
      rows+=("$(printf "%-14s  %-20s  %-55s  %-14s  %-9s  %s" "$id" "$typ" "$fpath" "$line_info" "DONE" "$completed_at")")
    done < "$done_issues_file"
  fi

  # Collect pending issues from report
  while IFS= read -r marker_line; do
    local id typ fpath line_info
    id="$(echo "$marker_line" | sed 's/.*ISSUE_START: \(CR-[a-f0-9]*\).*/\1/')"

    local detail_line
    detail_line="$(grep -A1 -F "$marker_line" "$file" | tail -1)"

    typ="$(echo "$detail_line" | sed 's/.*`CR-[a-f0-9]*` `\([^`]*\)`.*/\1/')"
    line_info="$(echo "$detail_line" | sed 's/.*`Line: \([^`]*\)`.*/\1/')"

    fpath="$(awk -v id="$id" '
      /^#### File:/ { current_file = $0; gsub(/^#### File: `/, "", current_file); gsub(/`$/, "", current_file) }
      index($0, "ISSUE_START: " id) { print current_file; exit }
    ' "$file")"

    total=$((total + 1))
    pending_count=$((pending_count + 1))
    rows+=("$(printf "%-14s  %-20s  %-55s  %-14s  %s" "$id" "$typ" "$fpath" "$line_info" "PENDING")")
  done < <(grep 'ISSUE_START:' "$file")

  echo ""
  echo "Report: $file"
  echo ""
  printf "%-14s  %-20s  %-55s  %-14s  %-9s  %s\n" "ID" "TYPE" "FILE" "LINE" "STATUS" "COMPLETED"
  printf "%-14s  %-20s  %-55s  %-14s  %-9s  %s\n" "--------------" "--------------------" "-------------------------------------------------------" "--------------" "---------" "--------------------"

  for row in "${rows[@]}"; do
    echo "$row"
  done

  echo ""
  echo "Total: $total | Done: $done_count | Pending: $pending_count"
}

clean_all() {
  clear_all_locks

  # Remove sorted findings files
  local count=0
  local f
  for f in sorted-coderabbit-findings-*.md; do
    if [[ -f "$f" ]]; then
      rm -f "$f"
      echo "Removed $f"
      count=$((count + 1))
    fi
  done

  # Remove agent dir list
  if [[ -f "$dir_list_file" ]]; then
    rm -f "$dir_list_file"
    echo "Removed $dir_list_file"
    count=$((count + 1))
  fi

  # Remove done-issues ledger
  if [[ -f "$done_issues_file" ]]; then
    rm -f "$done_issues_file"
    echo "Removed $done_issues_file"
    count=$((count + 1))
  fi

  echo ""
  echo "Clean complete. Removed ${count} additional file(s)."
}

clear_all_locks() {
  local count=0

  # Remove signup sheet lock
  if [[ -f "${signup_sheet}.lock" ]]; then
    rm -f "${signup_sheet}.lock"
    echo "Removed ${signup_sheet}.lock"
    count=$((count + 1))
  fi

  # Remove signup sheet itself
  if [[ -f "$signup_sheet" ]]; then
    rm -f "$signup_sheet"
    echo "Removed ${signup_sheet}"
    count=$((count + 1))
  fi

  # Remove all .agent.lock and .agent.done files listed in the dir list
  if [[ -f "$dir_list_file" ]]; then
    while IFS= read -r dir; do
      local lock_file done_file
      lock_file="$(lock_path_for_dir "$dir")"
      done_file="$(done_path_for_dir "$dir")"
      if [[ -f "$lock_file" ]]; then
        rm -f "$lock_file"
        echo "Removed $lock_file"
        count=$((count + 1))
      fi
      if [[ -f "$done_file" ]]; then
        rm -f "$done_file"
        echo "Removed $done_file"
        count=$((count + 1))
      fi
    done < "$dir_list_file"
  fi

  # Also find any stray .agent.lock / .agent.done files not in the dir list
  local stray
  while IFS= read -r stray; do
    rm -f "$stray"
    echo "Removed $stray"
    count=$((count + 1))
  done < <(find . -name ".agent.lock" -o -name ".agent.done" 2>/dev/null || true)

  echo ""
  echo "Cleared ${count} file(s). Agent coordination state is reset."
}

remove_issue_from_file() {
  local id="$1"
  local file="$2"
  local start_marker
  local end_marker
  local tmp_file

  start_marker="<!-- ISSUE_START: ${id} -->"
  end_marker="<!-- ISSUE_END: ${id} -->"

  if [[ ! -f "$file" ]]; then
    echo "Cannot remove issue: file not found: $file" >&2
    exit 1
  fi

  if ! grep -Fq "$start_marker" "$file"; then
    echo "Issue ID not found in report: $id" >&2
    exit 1
  fi

  # Extract metadata before removing so we can track it as done
  local issue_detail issue_type issue_line issue_file
  issue_detail="$(grep -A1 -F "$start_marker" "$file" | tail -1)"
  issue_type="$(echo "$issue_detail" | sed 's/.*`CR-[a-f0-9]*` `\([^`]*\)`.*/\1/')"
  issue_line="$(echo "$issue_detail" | sed 's/.*`Line: \([^`]*\)`.*/\1/')"
  issue_file="$(awk -v id="$id" '
    /^#### File:/ { current_file = $0; gsub(/^#### File: `/, "", current_file); gsub(/`$/, "", current_file) }
    index($0, "ISSUE_START: " id) { print current_file; exit }
  ' "$file")"

  # Record in done-issues ledger
  printf "%s\t%s\t%s\t%s\t%s\n" "$id" "$issue_type" "$issue_file" "$issue_line" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$done_issues_file"

  tmp_file="$(mktemp)"

  if ! awk -v s="$start_marker" -v e="$end_marker" '
  BEGIN { skip = 0 }
  $0 == s { skip = 1; next }
  $0 == e { skip = 0; next }
  skip { next }
  { print }
  END {
    if (skip == 1) {
      print "Malformed issue block: missing ISSUE_END marker" > "/dev/stderr"
      exit 2
    }
  }
  ' "$file" > "$tmp_file"; then
    rm -f "$tmp_file"
    exit 1
  fi

  mv "$tmp_file" "$file"
  echo "Removed issue ${id} from ${file}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -s|--summary)
      summary_only=1
      shift
      ;;
    -o|--output)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --output" >&2; exit 1; }
      output_file="$1"
      shift
      ;;
    --ttl-minutes)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --ttl-minutes" >&2; exit 1; }
      ttl_minutes="$1"
      shift
      ;;
    --agent)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --agent" >&2; exit 1; }
      agent="$1"
      shift
      ;;
    --claim-lock)
      shift
      [[ $# -gt 0 ]] || { echo "Missing DIR for --claim-lock" >&2; exit 1; }
      claim_dir="$1"
      shift
      ;;
    --check-lock)
      shift
      [[ $# -gt 0 ]] || { echo "Missing DIR for --check-lock" >&2; exit 1; }
      check_dir="$1"
      shift
      ;;
    --release-lock)
      shift
      [[ $# -gt 0 ]] || { echo "Missing DIR for --release-lock" >&2; exit 1; }
      release_dir="$1"
      shift
      ;;
    --remove-id)
      shift
      [[ $# -gt 0 ]] || { echo "Missing ISSUE_ID for --remove-id" >&2; exit 1; }
      remove_id="$1"
      shift
      ;;
    --sign-up)
      sign_up_only=1
      shift
      ;;
    --my-dirs)
      my_dirs_only=1
      shift
      ;;
    --claim-next)
      claim_next_only=1
      shift
      ;;
    --print-agent-prompt)
      print_agent_prompt_only=1
      shift
      ;;
    --takeover)
      shift
      [[ $# -gt 0 ]] || { echo "Missing AGENT_ID for --takeover" >&2; exit 1; }
      takeover_target="$1"
      shift
      ;;
    --adopt-abandoned)
      adopt_abandoned_only=1
      shift
      ;;
    --clear-all-locks)
      clear_all_locks_only=1
      shift
      ;;
    --status)
      status_only=1
      shift
      ;;
    --clean)
      clean_only=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      input="$1"
      shift
      ;;
  esac
done

if [[ $# -gt 0 ]]; then
  echo "Unexpected extra argument(s): $*" >&2
  usage >&2
  exit 1
fi

action_count=0
[[ -n "$claim_dir" ]] && action_count=$((action_count + 1))
[[ -n "$check_dir" ]] && action_count=$((action_count + 1))
[[ -n "$release_dir" ]] && action_count=$((action_count + 1))
[[ -n "$remove_id" ]] && action_count=$((action_count + 1))
[[ "$sign_up_only" -eq 1 ]] && action_count=$((action_count + 1))
[[ "$my_dirs_only" -eq 1 ]] && action_count=$((action_count + 1))
[[ "$claim_next_only" -eq 1 ]] && action_count=$((action_count + 1))
[[ "$print_agent_prompt_only" -eq 1 ]] && action_count=$((action_count + 1))
[[ -n "$takeover_target" ]] && action_count=$((action_count + 1))
[[ "$adopt_abandoned_only" -eq 1 ]] && action_count=$((action_count + 1))
[[ "$clear_all_locks_only" -eq 1 ]] && action_count=$((action_count + 1))
[[ "$status_only" -eq 1 ]] && action_count=$((action_count + 1))
[[ "$clean_only" -eq 1 ]] && action_count=$((action_count + 1))

if [[ "$action_count" -gt 1 ]]; then
  echo "Use only one action at a time: --claim-lock, --check-lock, --release-lock, --remove-id, --sign-up, --my-dirs, --claim-next, --print-agent-prompt, --takeover, --adopt-abandoned, --clear-all-locks, --status, --clean" >&2
  exit 1
fi

if [[ "$clean_only" -eq 1 ]]; then
  clean_all
  exit 0
fi

if [[ "$clear_all_locks_only" -eq 1 ]]; then
  clear_all_locks
  exit 0
fi

if [[ "$status_only" -eq 1 ]]; then
  show_status
  exit 0
fi

if [[ "$sign_up_only" -eq 1 ]]; then
  sign_up_agent
  exit 0
fi

if [[ "$my_dirs_only" -eq 1 ]]; then
  if [[ -z "$agent" ]]; then
    echo "--agent is required with --my-dirs" >&2
    exit 1
  fi
  get_my_dirs "$agent"
  exit 0
fi

if [[ "$claim_next_only" -eq 1 ]]; then
  if [[ -z "$agent" ]]; then
    echo "--agent is required with --claim-next" >&2
    exit 1
  fi
  claim_next_dir "$agent"
  exit 0
fi

if [[ "$print_agent_prompt_only" -eq 1 ]]; then
  print_agent_prompt
  exit 0
fi

if [[ -n "$takeover_target" ]]; then
  if [[ -z "$agent" ]]; then
    echo "--agent is required with --takeover" >&2
    exit 1
  fi
  takeover_agent "$agent" "$takeover_target"
  exit 0
fi

if [[ "$adopt_abandoned_only" -eq 1 ]]; then
  if [[ -z "$agent" ]]; then
    echo "--agent is required with --adopt-abandoned" >&2
    exit 1
  fi
  adopt_abandoned_dir "$agent"
  exit 0
fi

if [[ -n "$claim_dir" ]]; then
  claim_lock "$claim_dir"
  exit 0
fi

if [[ -n "$check_dir" ]]; then
  check_lock_common "$check_dir"
  exit $?
fi

if [[ -n "$release_dir" ]]; then
  release_lock "$release_dir"
  exit 0
fi

if [[ -n "$remove_id" ]]; then
  remove_issue_from_file "$remove_id" "$output_file"
  exit 0
fi

if ! [[ "$ttl_minutes" =~ ^[0-9]+$ ]] || [[ "$ttl_minutes" -le 0 ]]; then
  echo "--ttl-minutes must be a positive integer" >&2
  exit 1
fi

tmp_raw="$(mktemp)"
tmp_sorted="$(mktemp)"
tmp_with_ids="$(mktemp)"
tmp_report="$(mktemp)"
trap 'rm -f "$tmp_raw" "$tmp_sorted" "$tmp_with_ids" "$tmp_report"' EXIT

awk '
function ltrim(s) { sub(/^[[:space:]]+/, "", s); return s }
function rtrim(s) { sub(/[[:space:]]+$/, "", s); return s }
function trim(s)  { return rtrim(ltrim(s)) }

function reset_block() {
  file = ""
  line = ""
  typ  = ""
  prompt = ""
  in_prompt = 0
}

function line_start(raw,   n, s) {
  if (match(raw, /[0-9]+/)) {
    n = RLENGTH
    s = substr(raw, RSTART, n)
    return s + 0
  }
  return 999999999
}

function escape_field(s) {
  gsub(/\\/, "\\\\", s)
  gsub(/\t/, "\\t", s)
  gsub(/\r/, "", s)
  gsub(/\n/, "\\n", s)
  return s
}

function dirname_of(path,   d) {
  d = path
  sub(/\/[^\/]+$/, "", d)
  if (d == path || d == "") return "."
  return d
}

function flush_block(   dir, start, esc_prompt) {
  if (file == "") return

  prompt = trim(prompt)
  dir = dirname_of(file)
  start = line_start(line)
  esc_prompt = escape_field(prompt)

  printf "%s\t%s\t%d\t%s\t%s\t%s\n", dir, file, start, line, typ, esc_prompt
  reset_block()
}

BEGIN {
  reset_block()
}

/^=+$/ {
  flush_block()
  next
}

/^File:[[:space:]]*/ {
  file = trim(substr($0, index($0, ":") + 1))
  in_prompt = 0
  next
}

/^Line:[[:space:]]*/ {
  line = trim(substr($0, index($0, ":") + 1))
  next
}

/^Type:[[:space:]]*/ {
  typ = trim(substr($0, index($0, ":") + 1))
  next
}

/^Prompt for AI Agent:/ {
  in_prompt = 1
  next
}

{
  if (in_prompt) {
    if (prompt == "") prompt = $0
    else prompt = prompt "\n" $0
  }
}

END {
  flush_block()
}
' "$input" > "$tmp_raw"

if [[ ! -s "$tmp_raw" ]]; then
  echo "No findings parsed. Check input format." >&2
  exit 1
fi

if [[ "$summary_only" -eq 1 ]]; then
  echo "Directory summary:"
  cut -f1 "$tmp_raw" | sort | uniq -c | awk '{ printf "- %s: %d finding(s)\n", $2, $1 }'

  echo
  echo "File summary:"
  cut -f2 "$tmp_raw" | sort | uniq -c | awk '{ $1=$1; c=$1; sub(/^[0-9]+ /, "", $0); printf "- %s: %d finding(s)\n", $0, c }'
  exit 0
fi

sort -t $'\t' -k1,1 -k2,2 -k3,3n "$tmp_raw" > "$tmp_sorted"

# Write the canonical directory list so agents don't parse markdown
cut -f1 "$tmp_sorted" | awk '!seen[$0]++' > "$dir_list_file"
echo "Wrote directory list to $dir_list_file"

> "$tmp_with_ids"
while IFS=$'\t' read -r c1 c2 c3 c4 c5 c6; do
  id=""
  while [[ -z "$id" ]]; do
    id="CR-$(gen_random_hex8)"
    if grep -Fq $'\t'"${id}"'$' "$tmp_with_ids"; then
      id=""
    fi
  done
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$c1" "$c2" "$c3" "$c4" "$c5" "$c6" "$id" >> "$tmp_with_ids"
done < "$tmp_sorted"

{
  cat <<HEADER
# Sorted CodeRabbit Findings

- Generated (UTC): $(date -u '+%Y-%m-%dT%H:%M:%SZ')
- Source: ${input}
- Default lock TTL: ${ttl_minutes} minutes
- Helper script: ${script_name}

## Shared Agent Prompt (Copy/Paste)

\`\`\`text
$(print_agent_prompt)
\`\`\`

## Findings
HEADER

  awk -F '\t' -v script="$script_name" -v ttl="$ttl_minutes" -v out="$output_file" '
function unescape_field(s) {
  gsub(/\\n/, "\n", s)
  gsub(/\\t/, "\t", s)
  gsub(/\\\\/, "\\", s)
  return s
}

function print_prompt_block(s,   n, i, lines) {
  n = split(s, lines, /\n/)
  for (i = 1; i <= n; i++) {
    printf "%s\n", lines[i]
  }
}

{
  dir  = $1
  file = $2
  line = $4
  typ  = $5
  prm  = unescape_field($6)
  id   = $7

  if (dir != last_dir) {
    dir_idx++
    if (NR > 1) print ""
    printf "### Directory %d: `%s`\n\n", dir_idx, dir
    printf "- Assignment: agent whose `(dir_position - 1) %% total_agents + 1 == N`  (position=%d)\n", dir_idx
    print "- Report lock: `[ ] CLAIMED_BY=________ EXPIRES_AT=________`"
    printf "- Lockfile: `%s/.agent.lock`\n", dir
    printf "- Claim: `./%s --claim-lock \"%s\" --agent \"$AGENT_ID\" --ttl-minutes %s`\n", script, dir, ttl
    printf "- Check: `./%s --check-lock \"%s\"`\n", script, dir
    printf "- Release: `./%s --release-lock \"%s\" --agent \"$AGENT_ID\"`\n", script, dir
    last_dir = dir
    last_file = ""
  }

  if (file != last_file) {
    printf "\n#### File: `%s`\n\n", file
    last_file = file
  }

  printf "<!-- ISSUE_START: %s -->\n", id
  printf "- [ ] `%s` `%s` `Line: %s`\n", id, typ, line
  printf "- Remove when done: `./%s --remove-id %s --output %s`\n", script, id, out
  print "- Prompt:"
  print "```text"
  if (prm != "") {
    print_prompt_block(prm)
  }
  print "```"
  printf "<!-- ISSUE_END: %s -->\n", id
}
' "$tmp_with_ids"
} > "$tmp_report"

mv "$tmp_report" "$output_file"

# Print ticket summary
total_tickets="$(wc -l < "$tmp_with_ids" | tr -d ' ')"
total_dirs="$(cut -f1 "$tmp_with_ids" | sort -u | wc -l | tr -d ' ')"
total_files="$(cut -f2 "$tmp_with_ids" | sort -u | wc -l | tr -d ' ')"

echo "Wrote sorted findings to $output_file"
echo ""
echo "=== Ticket Summary ==="
echo "Total: ${total_tickets} findings across ${total_files} files in ${total_dirs} directories"
echo ""
printf "%-14s  %-20s  %-50s  %s\n" "ID" "TYPE" "FILE" "LINE"
printf "%-14s  %-20s  %-50s  %s\n" "--------------" "--------------------" "--------------------------------------------------" "--------"
awk -F '\t' '{
  printf "%-14s  %-20s  %-50s  %s\n", $7, $5, $2, $4
}' "$tmp_with_ids"

echo ""
echo "Shared agent prompt (copy/paste):"
print_agent_prompt
