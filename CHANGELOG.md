# Changelog

## Unreleased

- Requires Codex CLI 0.145.0 or newer and disables shell, browser, app, computer-use, multi-agent, hook, and workspace-dependency capabilities during prompt enhancement.
- Limits Codex and native-helper subprocess environments to explicit runtime, authentication, proxy, and certificate allowlists.
- Replaces raw child-process diagnostics with structured, prompt-free failure metadata.
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
