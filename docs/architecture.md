# Architecture and security model

## Overview

Codex Prompt Enhancer consists of three cooperating parts:

| Component | Responsibility |
| --- | --- |
| Cursor extension | Shortcut handling, orchestration, validation, configuration, progress UI |
| Native Swift helper | Reading and replacing the focused Codex composer through macOS Accessibility |
| Codex CLI runner | Running the `$prompt-enhancer` skill in an isolated, read-only enhancement pass |

The native helper exists because the Codex webview composer is not exposed through the standard VS Code extension API.

## End-to-end sequence

### 1. Command activation

The user focuses the Codex composer and presses **Cmd+Shift+R**.

The extension:

- rejects concurrent runs;
- updates the informational status-bar item;
- starts the enhancement operation;
- does not move focus intentionally.

### 2. Canonical prompt read

The Swift helper locates the frontmost Cursor process and validates that the explicitly focused accessibility element is a readable, enabled, selectable `AXTextArea`. Cursor does not consistently expose composer-specific semantic labels on the focused field, so direct focus is treated as the user’s targeting signal.

Known editor, terminal, search, quick-input, output, debug, rename, and SCM contexts are rejected when Cursor exposes those identifiers through Accessibility. Because the real composer may expose no semantic label, an explicitly focused readable and selectable `AXTextArea` remains eligible unless a forbidden context is detected. If Cursor explicitly reports another focused control, the helper fails instead of searching for and focusing a different text area.

Window traversal remains available only when `AXFocusedUIElement` cannot be resolved. Unlike direct focus, a fallback candidate must have strong Codex-specific semantic evidence, composer-like geometry, the minimum score, and an unambiguous score margin.

To obtain Cursor’s canonical serialized representation, it uses:

```text
Cmd+A
Cmd+C
```

This is important because the rendered accessibility value contains only visible reference labels, while the clipboard serialization contains the full Markdown-style reference targets.

Before modifying the pasteboard, the helper snapshots at most 128 MiB across 32 items and 128 representations. Exceeding any limit returns `clipboard_snapshot_limit_exceeded` before the pasteboard is cleared or changed. The helper restores an accepted snapshot after reading.

The read response also contains a SHA-256 target fingerprint derived from prompt-free structural metadata such as the Cursor PID, window and element frames, accessibility role path, stable identifiers, and matched evidence names.

### 3. Inline reference protection

The extension parses local references such as:

```text
[LoginPageContent](/Users/example/project/LoginPageContent)
```

and replaces each with a unique placeholder such as:

```text
⟦CODEX_REF_ABC123_1:LoginPageContent⟧
```

The absolute path is therefore excluded from the model request.

Each placeholder must appear exactly once in the model output. Missing, duplicated, or unknown placeholders abort the operation.

### 4. Isolated Codex invocation

The extension starts the Codex CLI with `spawn()` and `shell: false`.

The process:

- must report Codex CLI version 0.145.0 or newer;
- receives its prompt through stdin;
- runs in a new empty temporary directory;
- skips repository discovery;
- uses a read-only sandbox;
- receives only allowlisted runtime, authentication, proxy, and certificate environment variables;
- disables shell, browser, app, computer-use, image-generation, multi-agent, hook, and workspace-dependency capabilities;
- does not request approval;
- uses an ephemeral session;
- writes only the final assistant message to a temporary output file;
- has a configurable timeout;
- is terminated on cancellation.

The enhancement instructions explicitly require the model to:

- rewrite only;
- preserve language and intent;
- avoid answering or implementing;
- avoid tools and repository inspection;
- preserve every reference placeholder;
- return only the enhanced prompt.

## 5. Reference restoration

After the model returns:

- every placeholder is validated;
- each original serialized reference is restored byte-for-byte;
- unknown placeholders cause a hard failure;
- the original composer remains untouched when validation fails.

## 6. Target and stale-prompt protection

Before replacement, the helper re-reads the current canonical composer value.

It first recomputes the composer target fingerprint. If the user switched chats, windows, or composer targets, the helper returns `composer_target_changed` before accessing the clipboard.

Replacement proceeds only when it exactly matches the text read at the beginning of the operation.

When the user edits the prompt while enhancement is running, the helper returns `stale_prompt`, and nothing is overwritten.

## 7. Replacement

The helper:

1. snapshots the clipboard within the fixed safety limits;
2. selects the composer text with `Cmd+A`;
3. verifies the original serialized prompt;
4. validates a deterministic plan of at most 32 chunks, each no larger than 1,800 UTF-16 units and ending at an existing paragraph, line, or whitespace boundary;
5. writes and pastes each chunk with `Cmd+V`;
6. waits up to five seconds for each changed rendered accessibility value to stabilize;
7. re-copies the complete composer and accepts exact serialized equality or one Cursor-added ASCII space immediately beside a reference chip where the expected text has no whitespace;
8. issues at most one `Cmd+Z` per helper paste and verifies the exact original prompt if a partial replacement fails;
9. restores the clipboard;
10. collapses the selection.

Using an actual paste is necessary for Cursor to reconstruct clickable inline references.

Cursor may convert a sufficiently large single clipboard paste into a text-file attachment instead of inserting it into the composer. Bounded sequential paste prevents that behavior while retaining keyboard paste so clickable references are reconstructed. The planner never splits words, Unicode pairs, local references, Markdown links or images, autolinks, inline code, fenced code blocks, or paired emphasis and strikethrough spans. An indivisible structure over the chunk limit fails before the helper starts.

After every paste the helper waits for the rendered accessibility value to stabilize and explicitly places the caret at the composer end. Canonical serialized verification remains authoritative. Reference-chip normalization is accepted only when the ordered raw references and all non-reference text remain identical and the sole differences are permitted single ASCII spaces next to reference tokens; line breaks and all other edits fail verification.

Rollback never repastes the original. The helper records its own paste count and last rendered value, confirms that the same live focused AX element remains unchanged, and undoes only its own bounded paste events. It stops when the original rendered value returns and then requires an exact canonical serialized copy. Target changes and concurrent user edits suppress automatic undo.

Clipboard operations run inside one transaction. The transaction tracks the helper-owned pasteboard change count and performs centralized cleanup after success, handled failure, timeout, or cooperative termination. If another application changes the clipboard, the newer change wins and restoration is skipped rather than overwritten.

The helper records `SIGTERM` and `SIGINT` through dispatch signal sources and checks for termination around clipboard capture, mutation, copy, paste, verification, and waits. The extension gives the helper five seconds to restore temporary clipboard state before escalating to `SIGKILL`. Codex subprocesses retain a two-second termination grace period. Repeated timeout or cancellation requests share one `SIGTERM`, one escalation timer, and one cleanup path.

## Attachment behavior

Attachment chips are separate webview elements rather than part of the serialized text.

The production flow intentionally:

- does not remove them;
- does not inspect their contents;
- does not send screenshots or files to the enhancement model;
- does not include their base64 representation;
- leaves them attached during text replacement.

## Data boundaries

### Sent to the enhancement model

- the typed prompt text;
- protected reference labels inside opaque placeholders;
- fixed enhancement instructions.

### Not sent to the enhancement model

- absolute inline reference paths;
- repository file contents;
- attachment contents;
- screenshot pixels or base64 data;
- clipboard contents unrelated to the current composer;
- extension logs.

## Logging

The output channel records operational metadata such as:

- timestamps;
- durations;
- prompt length;
- reference count;
- process result;
- structured failure metadata.

Codex stdout and stderr are drained and counted but never retained or written to the output channel. Native-helper failures expose only an allowlist of scalar operational fields. Clipboard diagnostics include only byte, item, representation, and configured-limit counts, never contents or pasteboard type names.

It should never log:

- original prompt text;
- enhanced prompt text;
- reference paths;
- attachment content;
- authentication tokens.

## Failure-safety principles

The extension prefers refusing to act over modifying the wrong text.

It aborts when:

- Accessibility permission is missing;
- renderer accessibility was not enabled;
- the focused element is structurally invalid or exposes a forbidden context;
- the prompt is empty;
- Codex cannot start;
- Codex times out;
- the prompt changes during enhancement;
- the clipboard snapshot exceeds a fixed safety limit;
- the clipboard changes while the helper owns temporary pasteboard state;
- a reference placeholder is missing or duplicated;
- replacement verification fails.

Clipboard restoration is not guaranteed after `SIGKILL`, a helper crash, power loss, or an unresponsive pasteboard. These are operating-system limits rather than recoverable helper failures.

## Security assumptions

The project assumes:

- the local Codex CLI installation is trusted;
- the `$prompt-enhancer` skill file is trusted;
- the installed VSIX and native helper were built from trusted source;
- the user understands that typed prompt text is processed by their configured Codex account.

The extension does not provide a security boundary against a malicious local user, modified skill file, compromised Codex CLI, or modified extension package.

## Non-goals

The enhancer is not intended to:

- inspect or understand the repository;
- solve the user’s original task;
- analyze attachments;
- automatically submit prompts;
- act as a general Cursor automation framework;
- support Windows or Linux in the current implementation.
