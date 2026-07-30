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
  --target "$TARGET" \
  --out "$VSIX_PATH"

[[ -s "$VSIX_PATH" ]] \
  || fail "VSIX package was not created."

echo "Verifying VSIX contents..."

python3 - "$VSIX_PATH" <<'PY'
from pathlib import Path
import stat
import sys
import zipfile

vsix_path = Path(sys.argv[1])

required_files = {
    "extension/package.json",
    "extension/dist/extension.js",
    "extension/bin/prompt-accessibility-helper",
}

with zipfile.ZipFile(vsix_path) as archive:
    entries = {
        info.filename: info
        for info in archive.infolist()
    }

    missing = sorted(
        required_files.difference(entries)
    )

    if missing:
        print(
            "VSIX is missing required files:",
            file=sys.stderr,
        )

        for name in missing:
            print(f"  - {name}", file=sys.stderr)

        print(
            "\nPackaged files:",
            file=sys.stderr,
        )

        for name in sorted(entries):
            print(f"  {name}", file=sys.stderr)

        raise SystemExit(1)

    helper_info = entries[
        "extension/bin/prompt-accessibility-helper"
    ]

    unix_mode = (
        helper_info.external_attr >> 16
    ) & 0o777

    if unix_mode != 0 and not (
        unix_mode
        & (
            stat.S_IXUSR
            | stat.S_IXGRP
            | stat.S_IXOTH
        )
    ):
        raise SystemExit(
            "Native helper lost its executable "
            f"permission in the VSIX: {oct(unix_mode)}"
        )

print("PASS: compiled extension is packaged")
print("PASS: native helper is packaged")
print("PASS: extension manifest is packaged")
PY

echo
echo "VSIX created successfully:"
printf '%s\n' "$VSIX_PATH"
