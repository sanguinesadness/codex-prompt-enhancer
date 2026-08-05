# Troubleshooting

## `AXFocusedUIElement error=-25212`

Example:

```text
AXFocusedUIElement error=-25212
candidateCount=0
```

Cause: Cursor was started without complete renderer accessibility.

Fix:

1. Fully quit Cursor.
2. Start it through **Cursor Enhanced**, or run:

   ```bash
   open -na "Cursor" \
     --args \
     --force-renderer-accessibility=complete
   ```

3. Focus the Codex composer.
4. Press **Cmd+Shift+R** again.

An `argv.json` entry is not reliable in tested Cursor versions.

## `Could not safely identify the Codex prompt field`

Check all of the following:

- a Codex chat is visible;
- the caret is inside the Codex composer;
- Cursor was launched with renderer accessibility enabled;
- the installed helper has Accessibility permission;
- no modal dialog or quick input currently owns focus.

The status-bar item is informational and cannot start enhancement.

## `The focused control is not the Codex prompt field`

The helper resolved Cursor focus successfully but identified the focused control through Accessibility as an editor, terminal, search field, quick input, output view, debug field, rename field, SCM field, or a non-selectable text area.

Place the caret inside the intended Codex composer and press **Cmd+Shift+R** again. The extension does not start Codex or access the clipboard after this refusal.

## `The Codex composer changed while enhancement was running`

The validated composer fingerprint no longer matches the target read at the beginning of enhancement. This can happen after switching chats or windows, moving or resizing the Cursor window, or changing the active composer.

Nothing was replaced and the clipboard was not accessed. Focus the intended composer and retry.

## Accessibility permission is missing

Open:

```text
System Settings
→ Privacy & Security
→ Accessibility
```

Enable the installed helper located under:

```text
~/.cursor/extensions/<extension-id>/bin/prompt-accessibility-helper
```

After an extension upgrade, the helper path may change because the versioned installation directory changed. Re-enable the new binary and restart Cursor.

## Shortcut does nothing

Check Cursor keybindings for conflicts with:

```text
Cmd+Shift+R
```

The command ID is:

```text
codexPromptEnhancer.enhanceCurrentPrompt
```

A user keybinding can be added manually:

```json
{
  "key": "cmd+shift+r",
  "command": "codexPromptEnhancer.enhanceCurrentPrompt"
}
```

## `Codex exited with code 1`

Open:

```text
View → Output → Codex Prompt Enhancer
```

Inspect the `Codex failure metadata:` line. It intentionally contains only process state and byte counts, never raw Codex output.

Common causes:

- configured model is unavailable for the authenticated account;
- Codex CLI is not authenticated;
- an unsupported configuration value was supplied;
- the `$prompt-enhancer` skill cannot be loaded;
- the CLI path is wrong.

Test the CLI independently:

```bash
"$HOME/.local/bin/codex" --version
```

The reported version must be `0.145.0` or newer.

When developing from source, run `npm run check` to verify request construction and protocol handling with synthetic tests before retrying in the Extension Development Host.

## `Codex CLI 0.145.0 or newer is required`

Update the configured Codex CLI, verify the new version, then retry:

```bash
"$HOME/.local/bin/codex" --version
```

If Cursor uses a different executable, update `codexPromptEnhancer.codexPath` and fully restart Cursor.

## Model is not supported with a ChatGPT account

Choose a model supported by your Codex CLI account in:

```text
Settings → Codex Prompt Enhancer: Model
```

Do not assume that a generic model family alias is accepted. Test the exact model ID through `codex exec`.

## `Codex CLI was not found or is not executable`

The default path is:

```text
~/.local/bin/codex
```

Verify:

```bash
test -x "$HOME/.local/bin/codex" \
  && echo "Codex CLI is executable"
```

Set a custom location with:

```text
codexPromptEnhancer.codexPath
```

## `The prompt changed while enhancement was running`

This is expected stale-prompt protection.

The user edited the composer after enhancement started, so the extension refused to overwrite the newer text.

Run the shortcut again when the prompt is ready.

## A reference placeholder was lost or duplicated

The extension refuses replacement when the enhancement model removes or duplicates an inline-reference placeholder.

The original composer should remain unchanged.

Retry once. If it happens consistently:

- inspect the Prompt Enhancer skill;
- reduce conflicting instructions;
- confirm that the configured model follows exact placeholder-preservation rules.

## Attachment chips disappeared

The normal replacement path selects and replaces only the composer’s text area. Chips should remain.

If they disappear:

1. confirm that the production helper still uses keyboard paste;
2. confirm that direct `AXValue` replacement was not introduced;
3. reproduce with a single attachment;
4. record the Cursor version and Codex extension version.

## Clipboard was not restored

The helper restores accepted clipboard snapshots after success, handled failure, timeout, and cooperative termination when it still owns the temporary pasteboard state.

When reproducing:

- test with plain text clipboard data first;
- check whether another clipboard manager modified the clipboard concurrently;
- inspect helper diagnostics;
- avoid changing clipboard contents during the enhancement run.

If another application changes the clipboard during enhancement, that newer content intentionally wins and the helper reports that restoration was skipped. Restoration cannot be guaranteed after `SIGKILL`, a helper crash, power loss, or an unresponsive pasteboard.

## `Clipboard contents are too large to preserve safely`

The clipboard exceeds one of the fixed snapshot limits: 128 MiB total data, 32 items, or 128 representations. The helper fails before clearing or modifying the pasteboard.

Copy a smaller item or clear the clipboard, then press **Cmd+Shift+R** again. Diagnostics report only counts and configured limits, not clipboard contents or type names.

## `Cursor did not finish applying the enhanced prompt`

Cursor converts sufficiently large single pastes into text-file attachments rather than inserting them into the prompt field. The extension avoids this with at most 32 structure-aware chunks of 1,800 UTF-16 units, preserved paragraph/line/whitespace boundaries, stabilization waits, and explicit caret placement.

If a chunk is not applied or final canonical verification fails, the helper uses bounded `Cmd+Z` operations and requires an exact canonical copy of the original prompt before reporting successful rollback. Keep the composer focused and retry once. If it fails consistently, record the safe boundary kind, chunk count, verification mode, paste-event count, and undo diagnostics from the output channel; they contain no prompt contents.

## `A Markdown structure is too large to paste safely`

One indivisible reference, link, autolink, inline-code span, fenced code block, or paired emphasis span exceeds 1,800 UTF-16 units. The extension fails before invoking the helper or changing the composer. Shorten that structure or divide the request into separate prompts. The extension intentionally does not automate Cursor's version- and localization-sensitive **Show in text field** control.

The same fail-closed behavior applies when a prose section has no safe paragraph, line, or whitespace boundary, or when a replacement would require more than 32 chunks.

## Progress remains forever

The extension has two timeout layers:

- native helper timeout;
- Codex process timeout.

Check the output channel for the last completed stage:

```text
Native helper command started
Starting Codex enhancement
Native helper command started. command=replace
```

A stuck Codex process receives `SIGTERM` and has two seconds to exit before `SIGKILL`. A timed-out native helper receives `SIGTERM` and has five seconds to restore helper-owned temporary clipboard state before escalation.

## Installed extension is not updated

Reinstall with force:

```bash
npm run package:vsix
npm run install:local
```

Then fully quit Cursor and reopen it through **Cursor Enhanced**.

Confirm the installed version:

```bash
"/Applications/Cursor.app/Contents/Resources/app/bin/cursor" \
  --list-extensions \
  --show-versions \
  | grep codex-prompt-enhancer
```

## Where to collect diagnostics

Use:

```text
View → Output → Codex Prompt Enhancer
```

Before opening a public issue, remove:

- local usernames;
- absolute paths;
- prompt contents;
- account information;
- attachment names when sensitive.

Include:

- macOS version;
- Cursor version;
- extension version;
- Codex CLI version;
- exact error code;
- safe operational log lines.
