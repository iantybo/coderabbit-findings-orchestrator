# CodeRabbit Findings Orchestrator

Parse CodeRabbit review output into a sorted findings report, then use the generated prompt to coordinate multiple AI agents to fix issues concurrently.

## Quick Start

### 1. Run the review

```bash
./run-review.sh
```

This runs `coderabbit review` and saves the raw output to `coderabbit-raw.txt`.

### 2. Generate the findings report

```bash
./orchestrator.sh coderabbit-raw.txt
```

This produces:
- A sorted findings report (`sorted-coderabbit-findings-<timestamp>.md`)
- A directory list for agent assignment (`.agent-dir-list`)
- **A prompt** printed to stdout that you copy/paste into N agents (Claude Code, Cursor, etc.)

Each agent gets the same prompt. The orchestrator's sign-up and locking system ensures they don't step on each other — agents claim directories, fix findings, and release locks automatically.

That's it. Two commands.

---

## Prerequisites

- Bash 4+
- [CodeRabbit CLI](https://docs.coderabbit.ai/guides/cli/) installed and configured
- `openssl` (for random ID generation, falls back to `/dev/urandom`)

## Other Ways to Get Findings

**Custom output file / base branch:**

```bash
./run-review.sh my-output.txt develop
```

**Set up a review workspace for an open-source repo:**

```bash
./setup-review.sh \
  --repo https://github.com/org/project.git \
  --dir src/module \
  --shallow \
  --run-review
```

This clones the repo, creates a base branch without the target directory, creates a feature branch with it, and optionally runs CodeRabbit review.

**Pipe directly (skip the file):**

```bash
coderabbit review --plain --no-color --type all --base main | ./orchestrator.sh
```

## Orchestrator Reference

### Report Generation

```bash
./orchestrator.sh coderabbit-raw.txt              # parse and generate report
./orchestrator.sh --output custom-report.md coderabbit-raw.txt  # custom output name
./orchestrator.sh --summary coderabbit-raw.txt     # summary only (no report file)
```

### Agent Lifecycle

```bash
AGENT_ID=$(./orchestrator.sh --sign-up)                      # sign up, returns "agent-1"
DIR=$(./orchestrator.sh --claim-next --agent "$AGENT_ID")     # claim next directory
./orchestrator.sh --my-dirs --agent "$AGENT_ID"               # list assigned directories
./orchestrator.sh --print-agent-prompt                        # print the agent system prompt
```

### Lock Management

```bash
./orchestrator.sh --claim-lock internal/service --agent agent-1 --ttl-minutes 60
./orchestrator.sh --check-lock internal/service       # returns LOCKED, UNLOCKED, or EXPIRED
./orchestrator.sh --release-lock internal/service --agent agent-1
```

### Issue Tracking

```bash
./orchestrator.sh --remove-id CR-a1b2c3d4 --output sorted-coderabbit-findings-*.md
./orchestrator.sh --status
```

### Recovery

```bash
./orchestrator.sh --takeover agent-2 --agent agent-3      # take over a dead agent's lane
./orchestrator.sh --adopt-abandoned --agent agent-1        # grab any expired-lock directory
```

### Cleanup

```bash
./orchestrator.sh --clear-all-locks    # reset agent coordination state (keeps reports)
./orchestrator.sh --clean              # full reset: locks, reports, dir list, ledger
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

Each directory gets a `.agent.lock` file containing the owner, creation time, and expiry. Locks have a configurable TTL (default 50 minutes). Expired locks can be claimed by any agent. A `.agent.done` file is written when a directory's lock is released, preventing re-processing.

### File Artifacts

| File | Purpose |
|------|---------|
| `.agent-signup-sheet` | Registry of active agents |
| `.agent-dir-list` | Ordered directory list from the report |
| `.agent-done-issues` | Ledger of resolved findings |
| `<dir>/.agent.lock` | Per-directory lock file |
| `<dir>/.agent.done` | Per-directory completion marker |

## setup-review.sh Reference

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
