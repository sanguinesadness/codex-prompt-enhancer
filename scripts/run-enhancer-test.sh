#!/bin/zsh

set -euo pipefail

if (( $# < 2 || $# > 3 )); then
  echo "Usage:"
  echo "  $0 <prompt-file> <result-file> [workspace]"
  exit 64
fi

CODEX_BIN="${CODEX_BIN:-$HOME/.local/bin/codex}"
INPUT_PROMPT="$1"
OUTPUT_RESULT="$2"
INPUT_WORKSPACE="${3:-$PWD}"

if [[ ! -x "$CODEX_BIN" ]]; then
  echo "Codex executable not found or not executable:"
  echo "  $CODEX_BIN"
  exit 127
fi

if [[ ! -f "$INPUT_PROMPT" ]]; then
  echo "Prompt file not found:"
  echo "  $INPUT_PROMPT"
  exit 66
fi

if [[ ! -d "$INPUT_WORKSPACE" ]]; then
  echo "Workspace directory not found:"
  echo "  $INPUT_WORKSPACE"
  exit 72
fi

PROMPT_DIR="$(cd "$(dirname "$INPUT_PROMPT")" && pwd)"
PROMPT_FILE="$PROMPT_DIR/$(basename "$INPUT_PROMPT")"

WORKSPACE="$(cd "$INPUT_WORKSPACE" && pwd)"

RESULT_DIR="$(dirname "$OUTPUT_RESULT")"
mkdir -p "$RESULT_DIR"
RESULT_DIR="$(cd "$RESULT_DIR" && pwd)"
RESULT_FILE="$RESULT_DIR/$(basename "$OUTPUT_RESULT")"

LOG_DIR="$(dirname "$RESULT_FILE")/../logs"
mkdir -p "$LOG_DIR"
LOG_DIR="$(cd "$LOG_DIR" && pwd)"

RESULT_BASENAME="$(basename "$RESULT_FILE")"
LOG_FILE="$LOG_DIR/${RESULT_BASENAME%.*}.log"

rm -f "$RESULT_FILE" "$LOG_FILE"

echo "Prompt:    $PROMPT_FILE"
echo "Workspace: $WORKSPACE"
echo "Result:    $RESULT_FILE"
echo "Log:       $LOG_FILE"
echo
echo "Running Codex..."

set +e

"$CODEX_BIN" exec \
  --ephemeral \
  --sandbox read-only \
  --cd "$WORKSPACE" \
  --color never \
  --output-last-message "$RESULT_FILE" \
  - \
  < "$PROMPT_FILE" \
  > /dev/null \
  2> "$LOG_FILE"

EXIT_CODE=$?

set -e

if (( EXIT_CODE != 0 )); then
  echo
  echo "Codex failed with exit code $EXIT_CODE."
  echo
  echo "Last log lines:"
  tail -n 40 "$LOG_FILE"
  exit "$EXIT_CODE"
fi

if [[ ! -s "$RESULT_FILE" ]]; then
  echo
  echo "Codex exited successfully but produced an empty result."
  echo
  echo "Last log lines:"
  tail -n 40 "$LOG_FILE"
  exit 1
fi

echo
echo "Enhancement completed."
echo
echo "----- Enhanced prompt -----"
cat "$RESULT_FILE"
printf '\n'
echo "----- End of prompt -----"
