#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.."
  pwd
)"

cd "$ROOT_DIR"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

case "$(uname -m)" in
  arm64)
    TARGET="darwin-arm64"
    ;;
  x86_64)
    TARGET="darwin-x64"
    ;;
  *)
    fail "Unsupported macOS architecture: $(uname -m)"
    ;;
esac

VERSION="$(
  node -p "require('./package.json').version"
)"

RELEASE_DIR="$ROOT_DIR/release"

VSIX_PATH="$RELEASE_DIR/codex-prompt-enhancer-${VERSION}-${TARGET}.vsix"

mkdir -p "$RELEASE_DIR"

# Never verify a package left over from an earlier run.
rm -f "$VSIX_PATH"

echo "Building native helper and extension..."

npm run build

[[ -s "$ROOT_DIR/dist/extension.js" ]] \
  || fail "Compiled extension is missing: dist/extension.js"

[[ -x "$ROOT_DIR/bin/prompt-accessibility-helper" ]] \
  || fail "Native helper is missing or not executable."

echo "Creating VSIX package..."

npx vsce package \
  --allow-missing-repository \
  --no-rewrite-relative-links \
  --target "$TARGET" \
  --out "$VSIX_PATH"

[[ -s "$VSIX_PATH" ]] \
  || fail "VSIX package was not created."

echo "Verifying VSIX contents..."

python3 scripts/verify-package.py "$VSIX_PATH"

echo
echo "VSIX created successfully:"
printf '%s\n' "$VSIX_PATH"
