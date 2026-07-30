#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(
  cd "$(dirname "$0")/.." &&
  pwd
)"

SOURCE="$PROJECT_DIR/native/PromptAccessibility.swift"
OUTPUT_DIR="$PROJECT_DIR/bin"
TEMP_OUTPUT="$OUTPUT_DIR/prompt-accessibility-helper.new"
FINAL_OUTPUT="$OUTPUT_DIR/prompt-accessibility-helper"

mkdir -p "$OUTPUT_DIR"
rm -f "$TEMP_OUTPUT"

echo "Compiling PromptAccessibility.swift..."

xcrun swiftc \
  -O \
  -framework AppKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  "$SOURCE" \
  -o "$TEMP_OUTPUT"

echo "Signing helper..."

codesign \
  --force \
  --sign - \
  "$TEMP_OUTPUT"

mv "$TEMP_OUTPUT" "$FINAL_OUTPUT"

echo
echo "Built:"
echo "  $FINAL_OUTPUT"
