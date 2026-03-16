#!/usr/bin/env bash
set -euo pipefail

# setup-review.sh
# Clones an open source repo, extracts a target directory, sets up a base branch
# without it, then adds it back on a feature branch for CodeRabbit review.

usage() {
  cat <<'EOF'
Usage:
  setup-review.sh --repo <git-url> --dir <path/in/repo> [OPTIONS]

Required:
  --repo <url>          Git URL of the open source repo to clone
  --dir <path>          Directory path within the repo to review

Options:
  --branch <name>       Name for the feature branch (default: review/<dir-basename>)
  --base <name>         Name for the base branch (default: main)
  --workspace <path>    Working directory for the clone (default: ./review-workspace)
  --shallow             Use shallow clone (depth=1) for speed
  --run-review          Run coderabbit review after setup
  -h, --help            Show this help

What it does:
  1. Clones the repo into a workspace directory
  2. Moves the target directory to a temp location
  3. Commits the removal on the base branch
  4. Creates a feature branch and restores the directory
  5. Commits the addition on the feature branch
  6. Optionally runs: coderabbit review --prompt-only --base <base-branch>

Examples:
  setup-review.sh --repo https://github.com/org/project.git --dir src/module
  setup-review.sh --repo https://github.com/org/project.git --dir lib --shallow --run-review
EOF
}

repo_url=""
target_dir=""
feature_branch=""
base_branch="main"
workspace="./review-workspace"
shallow=0
run_review=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --repo)
      shift
      [[ $# -gt 0 ]] || { echo "Error: missing value for --repo" >&2; exit 1; }
      repo_url="$1"
      shift
      ;;
    --dir)
      shift
      [[ $# -gt 0 ]] || { echo "Error: missing value for --dir" >&2; exit 1; }
      target_dir="$1"
      shift
      ;;
    --branch)
      shift
      [[ $# -gt 0 ]] || { echo "Error: missing value for --branch" >&2; exit 1; }
      feature_branch="$1"
      shift
      ;;
    --base)
      shift
      [[ $# -gt 0 ]] || { echo "Error: missing value for --base" >&2; exit 1; }
      base_branch="$1"
      shift
      ;;
    --workspace)
      shift
      [[ $# -gt 0 ]] || { echo "Error: missing value for --workspace" >&2; exit 1; }
      workspace="$1"
      shift
      ;;
    --shallow)
      shallow=1
      shift
      ;;
    --run-review)
      run_review=1
      shift
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Validate required args
if [[ -z "$repo_url" ]]; then
  echo "Error: --repo is required" >&2
  usage >&2
  exit 1
fi

if [[ -z "$target_dir" ]]; then
  echo "Error: --dir is required" >&2
  usage >&2
  exit 1
fi

# Sanitize target_dir: strip leading/trailing slashes
target_dir="${target_dir#/}"
target_dir="${target_dir%/}"

if [[ -z "$target_dir" ]]; then
  echo "Error: --dir cannot be empty or root" >&2
  exit 1
fi

# Default feature branch name based on target dir
dir_basename="$(basename "$target_dir")"
if [[ -z "$feature_branch" ]]; then
  feature_branch="review/${dir_basename}"
fi

# Create temp dir for holding the extracted directory
tmp_holder="$(mktemp -d)"
trap 'rm -rf "$tmp_holder"' EXIT

echo "=== Setup Review ==="
echo "Repo:           $repo_url"
echo "Target dir:     $target_dir"
echo "Base branch:    $base_branch"
echo "Feature branch: $feature_branch"
echo "Workspace:      $workspace"
echo ""

# Step 1: Clone the repo
if [[ -d "$workspace" ]]; then
  echo "Workspace already exists: $workspace"
  echo "Removing it to start fresh..."
  rm -rf "$workspace"
fi

echo "Step 1: Cloning repository..."
clone_args=(git clone)
if [[ "$shallow" -eq 1 ]]; then
  clone_args+=(--depth 1)
fi
clone_args+=("$repo_url" "$workspace")
"${clone_args[@]}"
echo ""

cd "$workspace"

# Detach from any remote tracking to work with local branches only
# Get the current branch name from the clone
current_branch="$(git rev-parse --abbrev-ref HEAD)"

# Step 2: Verify the target directory exists
if [[ ! -d "$target_dir" ]]; then
  echo "Error: directory '$target_dir' not found in the cloned repo" >&2
  echo "Available top-level directories:" >&2
  find . -maxdepth 1 -type d ! -name '.' ! -name '.git' | sed 's|^\./||' >&2
  exit 1
fi

# If the cloned default branch isn't our desired base, try to fetch it or rename
if [[ "$current_branch" != "$base_branch" ]]; then
  if [[ "$shallow" -eq 1 ]]; then
    echo "Note: shallow clone limits branch access. Renaming '$current_branch' to '$base_branch' locally."
    git branch -m "$current_branch" "$base_branch"
  else
    # Try to fetch the actual remote branch
    if git fetch origin "$base_branch":"$base_branch" 2>/dev/null; then
      git checkout "$base_branch"
    else
      echo "Note: remote branch '$base_branch' not found. Renaming '$current_branch' to '$base_branch' locally."
      git branch -m "$current_branch" "$base_branch"
    fi
  fi
fi

# Step 3: Move the target directory out
echo "Step 3: Moving '$target_dir' to temp storage..."
cp -R "$target_dir" "$tmp_holder/extracted"
git rm -rf "$target_dir"
echo ""

# Step 4: Commit the removal on the base branch
echo "Step 4: Committing removal on '$base_branch'..."
git commit -m "Remove $target_dir for review baseline"
echo ""

# Step 5: Create feature branch and restore the directory
echo "Step 5: Creating feature branch '$feature_branch' and restoring '$target_dir'..."
git checkout -b "$feature_branch"

# Restore the directory
mkdir -p "$(dirname "$target_dir")"
cp -R "$tmp_holder/extracted" "$target_dir"
git add "$target_dir"
echo ""

# Step 6: Commit the addition
echo "Step 6: Committing addition on '$feature_branch'..."
git commit -m "Add $target_dir for review"
echo ""

echo "=== Setup Complete ==="
echo "Base branch:    $base_branch  (without $target_dir)"
echo "Feature branch: $feature_branch  (with $target_dir)"
echo "Working dir:    $(pwd)"
echo ""

# Step 7: Optionally run CodeRabbit review
if [[ "$run_review" -eq 1 ]]; then
  if ! command -v coderabbit >/dev/null 2>&1; then
    echo "Error: 'coderabbit' CLI not found in PATH" >&2
    exit 1
  fi

  echo "Step 7: Running CodeRabbit review..."
  echo ""
  coderabbit review \
    --prompt-only \
    --base "$base_branch" \
    --no-color
else
  echo "To run the review:"
  echo "  cd $(pwd)"
  echo "  coderabbit review --prompt-only --base $base_branch --no-color"
fi
