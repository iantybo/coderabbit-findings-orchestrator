#!/usr/bin/env bash
set -euo pipefail

OUTPUT_FILE="${1:-coderabbit-raw.txt}"
BASE_BRANCH="${2:-main}"

echo "Running CodeRabbit review (base: ${BASE_BRANCH})..."
echo "Output: ${OUTPUT_FILE}"
echo

coderabbit review \
  --plain \
  --no-color \
  --type all \
  --base "$BASE_BRANCH" \
  | tee "$OUTPUT_FILE"

echo
echo "Review saved to ${OUTPUT_FILE}"
echo "Next step: ./orchestrator ${OUTPUT_FILE}"