# Codex Prompt Enhancer — macOS MVP

## Goal

Enhance text currently typed in the Codex composer inside Cursor without sending
an intermediate chat message.

## Supported environment

- macOS only
- Cursor IDE
- Official OpenAI Codex extension
- Official Codex CLI
- Existing global skill:
  ~/.agents/skills/prompt-enhancer/SKILL.md

## User interaction

- Default shortcut: Cmd+Shift+R
- Status-bar action: Enhance Prompt
- Enhancement replaces the text currently typed in the Codex composer
- The enhanced prompt remains unsent so the user can review it
- The user sends the final prompt manually

## Required behavior

- Read the currently focused Codex composer text
- Invoke the existing prompt-enhancer skill through Codex CLI
- Replace only the typed prompt text
- Preserve attached file and directory chips
- Preserve the original text if enhancement fails
- Prevent concurrent enhancement requests
- Show progress while enhancement is running
- Display concise errors without logging prompt contents

## Explicitly outside the MVP

- No button injected directly inside the Codex composer
- No modification or patching of the Codex extension
- No automatic prompt submission
- No automatic enhancement on Enter
- No Windows or Linux support
- No marketplace publication
- No multiple enhancer profiles
- No prompt-history management
- No cloud backend or custom API server

## Success criteria

1. Type text in the Codex composer.
2. Press Cmd+Shift+R or click Enhance Prompt in the status bar.
3. The typed text is replaced by an enhanced version.
4. Attached files and directories remain attached.
5. Nothing is sent automatically.
6. Pressing Enter manually sends the enhanced prompt.
