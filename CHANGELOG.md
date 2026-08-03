# Changelog

## Unreleased

- Limits clipboard snapshots to 128 MiB, 32 items, and 128 representations before mutation and centralizes restoration across success and handled failures.
- Restores helper-owned temporary clipboard state during cooperative `SIGTERM` and `SIGINT`, with a five-second helper grace period and a two-second Codex grace period.
- Prevents duplicate termination escalation timers and preserves concurrent user clipboard changes.
- Adds safe clipboard-count diagnostics plus native and TypeScript lifecycle regression coverage.
- Validates focused and fallback composer targets, rejects identifiable non-composer contexts, and binds replacement to the exact composer fingerprint read at the start of enhancement.
- Accepts Cursor’s directly focused composer when its accessibility tree omits composer-specific semantic labels.
- Adds native Swift regression tests for composer evidence, fallback geometry, ambiguity handling, and target fingerprinting.
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
