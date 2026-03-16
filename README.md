# CodeRabbit Findings Orchestrator

A set of bash scripts that parse CodeRabbit review output, generate a sorted findings report, and coordinate multiple AI agents to fix issues concurrently using file-based locking.

## Scripts

| Script | Purpose |
|--------|---------|
| `run-review.sh` | Runs `coderabbit review` and saves raw output to a file |
| `setup-review.sh` | Clones a repo and sets up a base/feature branch pair for targeted CodeRabbit review |
| `orchestrator.sh` | Parses findings, generates reports, and manages multi-agent coordination |

## Prerequisites

- Bash 4+
- [CodeRabbit CLI](https://docs.coderabbit.ai/guides/cli/) installed and configured
- `openssl` (for random ID generation, falls back to `/dev/urandom`)

## Quick Start

### 1. Get CodeRabbit findings

**Option A** — Run a review directly:

```bash
./run-review.sh                          # defaults: output=coderabbit-raw.txt, base=main
./run-review.sh my-output.txt develop    # custom output file and base branch
```

**Option B** — Set up a review workspace for an open-source repo:

```bash
./setup-review.sh \
  --repo https://github.com/org/project.git \
  --dir src/module \
  --shallow \
  --run-review
```

This clones the repo, creates a base branch without the target directory, creates a feature branch with it, and optionally runs CodeRabbit review.

**Option C** — Pipe directly:

```bash
coderabbit review --plain --no-color --type all --base main | ./orchestrator.sh
```

### 2. Generate the sorted findings report

```bash
./orchestrator.sh coderabbit-raw.txt
```

This produces:
- `sorted-coderabbit-findings-<timestamp>.md` — the full report with issue IDs, prompts, and agent instructions
- `.agent-dir-list` — ordered list of directories for agent assignment

### 3. Run agents

```bash
# Each agent signs up (run once per agent)
AGENT_ID=$(./orchestrator.sh --sign-up)

# Work loop
while true; do
  DIR=$(./orchestrator.sh --claim-next --agent "$AGENT_ID")
  [[ -z "$DIR" ]] && break

  # ... fix findings in $DIR ...

  # Mark individual findings done
  ./orchestrator.sh --remove-id CR-a1b2c3d4 --output sorted-coderabbit-findings-*.md

  # Release the directory lock when done
  ./orchestrator.sh --release-lock "$DIR" --agent "$AGENT_ID"
done
```

## Orchestrator Reference

### Report Generation

```bash
# Parse and generate report (from file or stdin)
./orchestrator.sh coderabbit-raw.txt
./orchestrator.sh --output custom-report.md coderabbit-raw.txt

# Summary only (no report file)
./orchestrator.sh --summary coderabbit-raw.txt
```

### Agent Lifecycle

```bash
# Sign up — returns an agent ID like "agent-1"
AGENT_ID=$(./orchestrator.sh --sign-up)

# See which directories are assigned to you
./orchestrator.sh --my-dirs --agent "$AGENT_ID"

# Claim the next available directory (own lane first, then work-stealing)
DIR=$(./orchestrator.sh --claim-next --agent "$AGENT_ID")

# Print the agent system prompt (for pasting into an LLM)
./orchestrator.sh --print-agent-prompt
```

### Lock Management

```bash
# Claim a specific directory (default TTL: 50 minutes)
./orchestrator.sh --claim-lock internal/service --agent agent-1 --ttl-minutes 60

# Check lock status (returns LOCKED, UNLOCKED, or EXPIRED)
./orchestrator.sh --check-lock internal/service

# Release a lock (marks directory as done)
./orchestrator.sh --release-lock internal/service --agent agent-1
```

### Issue Tracking

```bash
# Mark a finding as resolved (removes it from the report, records in ledger)
./orchestrator.sh --remove-id CR-a1b2c3d4 --output sorted-coderabbit-findings-2025-01-01T120000Z.md

# Show status of all findings
./orchestrator.sh --status
```

### Recovery

```bash
# Take over a dead agent's lane and locks
./orchestrator.sh --takeover agent-2 --agent agent-3

# Grab any directory with an expired lock
./orchestrator.sh --adopt-abandoned --agent agent-1
```

### Cleanup

```bash
# Remove all locks and the signup sheet (keeps reports)
./orchestrator.sh --clear-all-locks

# Full reset: locks, signup sheet, reports, dir list, done ledger
./orchestrator.sh --clean
```

## How Agent Coordination Works

### Directory Assignment

Directories are assigned round-robin based on agent number and total agent count:

```
agent-1 gets dirs 1, 4, 7, ...
agent-2 gets dirs 2, 5, 8, ...
agent-3 gets dirs 3, 6, 9, ...
```

When an agent finishes its own lane, `--claim-next` automatically steals unclaimed directories from other lanes.

### Locking

Each directory gets a `.agent.lock` file containing the owner, creation time, and expiry. Locks have a configurable TTL (default 50 minutes). Expired locks can be claimed by any agent.

A `.agent.done` file is written when a directory's lock is released, preventing re-processing.

### Work Stealing

`--claim-next` follows a two-phase strategy:
1. Try the agent's own assigned directories first
2. Scan all directories for anything unclaimed or with an expired lock

This ensures no agent idles while work remains.

### File Artifacts

| File | Purpose |
|------|---------|
| `.agent-signup-sheet` | Registry of active agents |
| `.agent-dir-list` | Ordered directory list from the report |
| `.agent-done-issues` | Ledger of resolved findings |
| `<dir>/.agent.lock` | Per-directory lock file |
| `<dir>/.agent.done` | Per-directory completion marker |

## setup-review.sh Reference

Sets up a local git workspace for reviewing a specific directory from any repo.

```bash
./setup-review.sh --repo <git-url> --dir <path/in/repo> [OPTIONS]
```

| Option | Default | Description |
|--------|---------|-------------|
| `--repo <url>` | *required* | Git URL to clone |
| `--dir <path>` | *required* | Directory within the repo to review |
| `--branch <name>` | `review/<dir-basename>` | Feature branch name |
| `--base <name>` | `main` | Base branch name |
| `--workspace <path>` | `./review-workspace` | Clone destination |
| `--shallow` | off | Shallow clone (depth=1) |
| `--run-review` | off | Run `coderabbit review` after setup |

### What it does

1. Clones the repo into the workspace
2. Removes the target directory and commits on the base branch
3. Creates a feature branch and restores the directory
4. Optionally runs CodeRabbit review against the diff

This creates a clean diff that contains only the target directory's files, making CodeRabbit review it in isolation.

```bash
# Example: review the "internal/auth" package from a Go project
./setup-review.sh \
  --repo https://github.com/org/goservice.git \
  --dir internal/auth \
  --shallow \
  --run-review

# Then generate the orchestrator report
cd review-workspace
../orchestrator.sh coderabbit-raw.txt
```
