#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(
  cd "$(dirname "$0")/.." &&
  pwd
)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-prompt-enhancer-native-tests.XXXXXX")"
MODULE_CACHE="$TEMP_DIR/module-cache"
TEST_MAIN="$TEMP_DIR/main.swift"
TEST_BINARY="$TEMP_DIR/composer-validation-tests"
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
}

trap cleanup EXIT

mkdir -p "$MODULE_CACHE"
cp \
  "$PROJECT_DIR/tests/native/ComposerValidationTests.swift" \
  "$TEST_MAIN"

xcrun swiftc \
  -target "$SWIFT_TARGET" \
  -module-cache-path "$MODULE_CACHE" \
  "$PROJECT_DIR/native/ComposerValidation.swift" \
  "$TEST_MAIN" \
  -o "$TEST_BINARY"

"$TEST_BINARY"
