# Changelog

## Unreleased

- Removes legacy probe binaries, backup sources, captured prompt artifacts, and the development-only runner command.
- Adds synthetic unit tests, TypeScript linting, repository privacy checks, macOS CI, and stricter VSIX verification.
- Aligns VS Code 1.85 type compatibility and generates the native helper version from the extension manifest.

## 0.1.0

- Initial local macOS release.
- Enhances the focused unsent Codex prompt with Cmd+Shift+R.
- Preserves inline references and attachment chips.
- Uses a read-only, ephemeral Codex CLI invocation.
- Adds stale-prompt, timeout, cancellation, and clipboard-restoration safeguards.
- Keeps status-bar UI informational and avoids success/progress popups over the composer.
