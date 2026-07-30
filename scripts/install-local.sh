#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VSIX_PATH="${1:-}"
if [[ -z "$VSIX_PATH" ]]; then
  VSIX_PATH="$(find "$ROOT_DIR/release" -maxdepth 1 -name '*.vsix' -type f -print0 \
    | xargs -0 ls -t 2>/dev/null | head -n 1 || true)"
fi

[[ -n "$VSIX_PATH" && -f "$VSIX_PATH" ]] \
  || { echo "No VSIX package found. Run npm run package:vsix first." >&2; exit 1; }

if command -v cursor >/dev/null 2>&1; then
  CURSOR_CLI="$(command -v cursor)"
elif [[ -x "/Applications/Cursor.app/Contents/Resources/app/bin/cursor" ]]; then
  CURSOR_CLI="/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
else
  echo "Cursor shell command was not found." >&2
  echo "Install manually with: Extensions: Install from VSIX..." >&2
  echo "$VSIX_PATH"
  exit 2
fi

"$CURSOR_CLI" --install-extension "$VSIX_PATH" --force

EXTENSION_ID="$(node -p "const p=require('./package.json'); p.publisher+'.'+p.name")"
EXTENSION_DIR="$("$CURSOR_CLI" --locate-extension "$EXTENSION_ID" 2>/dev/null | tail -n 1 || true)"

if [[ -z "$EXTENSION_DIR" || ! -d "$EXTENSION_DIR" ]]; then
  EXTENSION_DIR="$(find "$HOME/.cursor/extensions" -maxdepth 1 -type d \
    -name "${EXTENSION_ID}-*" -print 2>/dev/null | sort | tail -n 1 || true)"
fi

echo
echo "Installed: $EXTENSION_ID"
echo "VSIX: $VSIX_PATH"

if [[ -n "$EXTENSION_DIR" && -d "$EXTENSION_DIR" ]]; then
  HELPER="$EXTENSION_DIR/bin/prompt-accessibility-helper"
  chmod +x "$HELPER" 2>/dev/null || true
  echo "Extension directory: $EXTENSION_DIR"
  echo "Native helper: $HELPER"

  if [[ -x "$HELPER" ]]; then
    if "$HELPER" permission 2>/dev/null | grep -q '"trusted"[[:space:]]*:[[:space:]]*true'; then
      echo "Accessibility permission: already granted"
    else
      echo "Accessibility permission: required for the installed helper"
      open -R "$HELPER"
      open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true
    fi
  fi
fi
