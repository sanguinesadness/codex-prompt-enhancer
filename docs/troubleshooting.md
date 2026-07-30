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

The helper is designed to restore the clipboard after read and replacement.

When reproducing:

- test with plain text clipboard data first;
- check whether another clipboard manager modified the clipboard concurrently;
- inspect helper diagnostics;
- avoid changing clipboard contents during the enhancement run.

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

A stuck Codex process should be terminated when `codexPromptEnhancer.timeoutSeconds` is reached.

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
