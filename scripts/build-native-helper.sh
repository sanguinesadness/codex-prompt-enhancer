#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(
  cd "$(dirname "$0")/.." &&
  pwd
)"

MAIN_SOURCE="$PROJECT_DIR/native/PromptAccessibility.swift"
VALIDATION_SOURCE="$PROJECT_DIR/native/ComposerValidation.swift"
CLIPBOARD_SAFETY_SOURCE="$PROJECT_DIR/native/ClipboardSafety.swift"
OUTPUT_DIR="$PROJECT_DIR/bin"
TEMP_OUTPUT="$OUTPUT_DIR/prompt-accessibility-helper.new"
FINAL_OUTPUT="$OUTPUT_DIR/prompt-accessibility-helper"
VERSION="$(
  node -p 'require(process.argv[1]).version' \
    "$PROJECT_DIR/package.json"
)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-prompt-enhancer-build.XXXXXX")"
GENERATED_SOURCE="$TEMP_DIR/main.swift"
MODULE_CACHE="$TEMP_DIR/module-cache"
ARCHITECTURE="$(uname -m)"

case "$ARCHITECTURE" in
  arm64|x86_64)
    SWIFT_TARGET="${ARCHITECTURE}-apple-macosx13.0"
    ;;
  *)
    echo "Unsupported macOS architecture: $ARCHITECTURE" >&2
    exit 65
    ;;
esac

cleanup() {
  rm -rf "$TEMP_DIR"
  rm -f "$TEMP_OUTPUT"
}

trap cleanup EXIT

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid package version: $VERSION" >&2
  exit 65
fi

sed \
  "s/__CODEX_PROMPT_ENHANCER_VERSION__/$VERSION/" \
  "$MAIN_SOURCE" \
  > "$GENERATED_SOURCE"
mkdir -p "$MODULE_CACHE"

mkdir -p "$OUTPUT_DIR"
rm -f "$TEMP_OUTPUT"

echo "Compiling PromptAccessibility.swift..."

xcrun swiftc \
  -O \
  -target "$SWIFT_TARGET" \
  -module-cache-path "$MODULE_CACHE" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  "$VALIDATION_SOURCE" \
  "$CLIPBOARD_SAFETY_SOURCE" \
  "$GENERATED_SOURCE" \
  -o "$TEMP_OUTPUT"

echo "Signing helper..."

codesign \
  --force \
  --sign - \
  "$TEMP_OUTPUT"

mv "$TEMP_OUTPUT" "$FINAL_OUTPUT"

BUILT_VERSION="$(
  "$FINAL_OUTPUT" version \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["version"])'
)"

if [[ "$BUILT_VERSION" != "$VERSION" ]]; then
  echo "Helper version mismatch: expected $VERSION, got $BUILT_VERSION" >&2
  exit 1
fi

echo
echo "Built:"
echo "  $FINAL_OUTPUT"
echo "  version $BUILT_VERSION"
