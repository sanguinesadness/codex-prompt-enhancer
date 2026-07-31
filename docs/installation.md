# Installation

Codex Prompt Enhancer is a macOS-only Cursor extension. It combines a normal VS Code-compatible extension with a native Swift accessibility helper.

## 1. Install and authenticate Codex CLI

The extension expects the Codex executable at:

```text
~/.local/bin/codex
```

Verify it:

```bash
"$HOME/.local/bin/codex" --version
```

Version `0.145.0` or newer is required. The extension checks the configured CLI on the first enhancement attempt and refuses older or unrecognized versions because they cannot guarantee the required tool restrictions.

The CLI must already be authenticated through your ChatGPT/OpenAI account.

To use a different path, change:

```text
codexPromptEnhancer.codexPath
```

in Cursor Settings.

## 2. Install the Prompt Enhancer skill

The project invokes:

```text
$prompt-enhancer
```

The skill must exist at:

```text
~/.agents/skills/prompt-enhancer/SKILL.md
```

Verify it:

```bash
test -f "$HOME/.agents/skills/prompt-enhancer/SKILL.md" \
  && echo "Prompt Enhancer skill found"
```

The skill should:

- rewrite rather than answer the prompt;
- preserve the input language;
- preserve the original intent;
- avoid inspecting repositories, references, attachments, or external resources;
- return only the enhanced prompt.

## 3. Install the extension

### Option A: install from the Cursor Marketplace

In Cursor:

1. Open **Extensions**.
2. Search for **Codex Prompt Enhancer**.
3. Confirm the publisher is `sanguinesadness`.
4. Select **Install**.

Marketplace installations can use Cursor’s **Auto Update** option. A GitHub push does not update the Marketplace package automatically; the maintainer must publish a new extension version first.

### Option B: install a release VSIX

Download the macOS VSIX matching your architecture from the repository’s GitHub Releases page.

In Cursor:

```text
Cmd+Shift+P
→ Extensions: Install from VSIX...
```

Select the downloaded file and restart Cursor.

### Option C: install from source

Clone the repository and run:

```bash
npm install
npm run package:vsix
npm run install:local
```

The generated package is stored in:

```text
release/
```

You can also install it manually through **Extensions: Install from VSIX...**.

## 4. Create an accessibility-enabled Cursor launcher

The Codex composer is rendered inside an Electron webview. The native helper can read it only when Cursor starts with:

```text
--force-renderer-accessibility=complete
```

A normal Cursor launch does not reliably enable this mode, even when an `argv.json` entry exists. Use one of the following approaches.

### Quick terminal launch

```bash
open -na "Cursor" \
  --args \
  --force-renderer-accessibility=complete
```

### Recommended permanent launcher

Create a small launcher application in `~/Applications`:

```bash
mkdir -p "$HOME/Applications"

cat > /tmp/CursorEnhanced.applescript <<'APPLESCRIPT'
on run
    launchCursor({})
end run

on open droppedItems
    set itemPaths to {}

    repeat with droppedItem in droppedItems
        set end of itemPaths to POSIX path of droppedItem
    end repeat

    launchCursor(itemPaths)
end open

on launchCursor(itemPaths)
    tell application "System Events"
        set cursorIsRunning to exists process "Cursor"
    end tell

    if cursorIsRunning then
        if (count of itemPaths) is 0 then
            tell application "Cursor" to activate
        else
            set openCommand to "/usr/bin/open -a " & quoted form of "Cursor"

            repeat with itemPath in itemPaths
                set openCommand to openCommand & " " & quoted form of itemPath
            end repeat

            do shell script openCommand
        end if

        return
    end if

    set launchCommand to "/usr/bin/open -na " & quoted form of "Cursor"

    repeat with itemPath in itemPaths
        set launchCommand to launchCommand & " " & quoted form of itemPath
    end repeat

    set launchCommand to launchCommand & " --args --force-renderer-accessibility=complete"

    do shell script launchCommand
end launchCursor
APPLESCRIPT

rm -rf "$HOME/Applications/Cursor Enhanced.app"

osacompile \
  -o "$HOME/Applications/Cursor Enhanced.app" \
  /tmp/CursorEnhanced.applescript

ICON_PATH="$(
  find "/Applications/Cursor.app/Contents/Resources" \
    -maxdepth 1 \
    -type f \
    -name '*.icns' \
    | head -n 1
)"

if [[ -n "$ICON_PATH" ]]; then
  cp \
    "$ICON_PATH" \
    "$HOME/Applications/Cursor Enhanced.app/Contents/Resources/applet.icns"

  touch "$HOME/Applications/Cursor Enhanced.app"
fi

rm -f /tmp/CursorEnhanced.applescript

open "$HOME/Applications"
```

Drag **Cursor Enhanced** into the Dock and launch Cursor through this icon.

The launcher adds the flag only when starting a new Cursor process. When Cursor is already running, it activates the existing instance.

## 5. Grant Accessibility permission

The native helper must be allowed under:

```text
System Settings
→ Privacy & Security
→ Accessibility
```

The installed helper is normally located at:

```text
~/.cursor/extensions/<publisher>.codex-prompt-enhancer-<version>/bin/prompt-accessibility-helper
```

When permission is missing:

1. Open the installed extension directory.
2. Locate `bin/prompt-accessibility-helper`.
3. Add or enable it in Accessibility settings.
4. Enable Cursor too if macOS lists it separately.
5. Fully quit and reopen Cursor through **Cursor Enhanced**.

## 6. Verify the installation

Launch Cursor through **Cursor Enhanced**.

Open the Codex panel, type:

```text
explain what happening here dont change anything
```

Keep the caret in the composer and press:

```text
Cmd+Shift+R
```

A successful installation:

- rewrites the prompt in place;
- keeps the prompt unsent;
- restores the status-bar indicator;
- does not show a success popup over the composer.

## 7. Upgrade

For Marketplace installations, enable **Auto Update** or use **Extensions: Check for Updates** after a newer version has been published.

For GitHub release or source installations:

1. Download or build the new VSIX.
2. Install it with `--force` or **Extensions: Install from VSIX...**.
3. Check Accessibility permission for the new installed helper path or rebuilt helper binary.
4. Fully restart Cursor through the enhanced launcher.

From a source checkout:

```bash
git pull
npm install
npm run package:vsix
npm run install:local
```

## 8. Uninstall

In Cursor:

```text
Extensions
→ Codex Prompt Enhancer
→ Uninstall
```

Optionally delete:

```text
~/Applications/Cursor Enhanced.app
```

The Codex CLI, Prompt Enhancer skill, and macOS permissions are separate and are not removed automatically.
