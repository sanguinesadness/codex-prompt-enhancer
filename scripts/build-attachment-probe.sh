#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.."
  pwd
)"

SOURCE_FILE="$ROOT_DIR/native/AttachmentProbe.swift"
OUTPUT_FILE="$ROOT_DIR/bin/attachment-accessibility-probe"

mkdir -p "$ROOT_DIR/bin"

echo "Compiling AttachmentProbe.swift..."

swiftc \
  -O \
  -framework AppKit \
  -framework ApplicationServices \
  "$SOURCE_FILE" \
  -o "$OUTPUT_FILE"

chmod +x "$OUTPUT_FILE"

echo "Built: $OUTPUT_FILE"
