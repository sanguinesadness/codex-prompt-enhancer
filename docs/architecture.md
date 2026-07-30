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

The Swift helper locates the frontmost Cursor process and validates that the focused accessibility element is a readable, enabled, selectable Codex `AXTextArea`.

Known editor, terminal, search, quick-input, output, debug, rename, and SCM contexts are rejected. If Cursor explicitly reports another focused control, the helper fails instead of searching for and focusing a different text area.

Window traversal remains available only when `AXFocusedUIElement` cannot be resolved. A fallback candidate must have strong Codex-specific semantic evidence, composer-like geometry, the minimum score, and an unambiguous score margin.

To obtain Cursor’s canonical serialized representation, it uses:

```text
Cmd+A
Cmd+C
```

This is important because the rendered accessibility value contains only visible reference labels, while the clipboard serialization contains the full Markdown-style reference targets.

The helper restores the original clipboard after reading.

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

1. snapshots the clipboard;
2. selects the composer text with `Cmd+A`;
3. verifies the original serialized prompt;
4. writes the replacement to the clipboard;
5. pastes with `Cmd+V`;
6. re-copies the composer to verify the serialized result;
7. restores the clipboard;
8. collapses the selection.

Using an actual paste is necessary for Cursor to reconstruct clickable inline references.

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

Codex stdout and stderr are drained and counted but never retained or written to the output channel. Native-helper failures expose only an allowlist of scalar operational fields.

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
- the focused element is not the Codex composer;
- the prompt is empty;
- Codex cannot start;
- Codex times out;
- the prompt changes during enhancement;
- a reference placeholder is missing or duplicated;
- replacement verification fails.

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
