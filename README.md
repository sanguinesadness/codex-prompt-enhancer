# Codex Prompt Enhancer

A local macOS extension for Cursor that rewrites the current **unsent Codex prompt in place**.

Focus the Codex composer, press **Cmd+Shift+R**, review the improved prompt, and send it only when you are ready.

> [!IMPORTANT]
> This is an unofficial community project. It is not affiliated with or endorsed by OpenAI or Cursor.

## Why this project exists

Prompt refinement tools usually add an extra chat turn: you submit a rough request, receive a rewritten version, copy it, and then submit it again.

Codex Prompt Enhancer removes that intermediate step. It reads the text already present in the Codex composer, improves its wording and structure, and pastes the result back into the same composer without sending anything.

## Features

- Enhances the focused, unsent Codex prompt with **Cmd+Shift+R**
- Preserves the original language and intent
- Preserves clickable inline file and folder references
- Leaves screenshot, file, and folder attachment chips attached
- Never sends the enhanced prompt automatically
- Restores the clipboard after replacement
- Refuses to overwrite the composer if the prompt changed during enhancement
- Runs Codex in a temporary directory with a read-only sandbox
- Uses ephemeral Codex sessions
- Keeps prompt contents and reference paths out of extension logs
- Shows unobtrusive progress in the status bar

## Usage

1. Launch Cursor through the accessibility-enabled launcher described in [Installation](docs/installation.md).
2. Open the Codex panel.
3. Type a rough prompt and add any references or attachments.
4. Keep the caret inside the Codex composer.
5. Press **Cmd+Shift+R**.
6. Review or edit the enhanced prompt.
7. Press Enter only when you want to send it.

The status-bar item is informational only and is intentionally not clickable.

## Examples in Cursor

These examples show the complete workflow: type a rough prompt, keep the caret in the composer, press **Cmd+Shift+R**, and review the rewritten prompt before sending it.

### English example

Start with this intentionally rough prompt:

```text
look at [LoginPage](/Users/example/project/src/LoginPage.tsx) and explain what happening there dont change anything also tell me how it connected to auth
```

After pressing **Cmd+Shift+R**, the extension rewrites the text in the same composer while preserving the inline reference and leaving the prompt unsent.

> **Screenshot placeholder — English workflow**
>
> Paste the screenshot of the enhanced English prompt in Cursor here.
>
> Suggested Markdown: `![English prompt enhanced in Cursor](docs/images/example-english.png)`

### Russian example

Start with this intentionally rough prompt:

```text
посмотри [LoginPage](/Users/example/project/src/LoginPage.tsx) и обьясни что тут происходит ничего не меняй еще скажи как это связано с авторизацией
```

After pressing **Cmd+Shift+R**, the extension keeps the prompt in Russian, improves its wording and structure, preserves the reference, and does not send it automatically.

> **Screenshot placeholder — Russian workflow**
>
> Paste the screenshot of the enhanced Russian prompt in Cursor here.
>
> Suggested Markdown: `![Russian prompt enhanced in Cursor](docs/images/example-russian.png)`

## What is preserved

### Inline references

Serialized references such as:

```text
[LoginPageContent](/absolute/path/to/LoginPageContent)
```

are replaced with temporary placeholders before the model call and restored byte-for-byte afterward. Cursor reconstructs them as clickable references when the result is pasted back.

### Attachment chips

Attachment chips are outside the serialized composer text. The enhancer does not remove, upload, inspect, or rewrite them.

### User control

The extension changes only the current unsent composer text. It never presses Enter and never starts a Codex task automatically.

## Privacy and safety

During enhancement:

- the current prompt text is sent through the locally authenticated Codex CLI;
- inline reference paths are hidden from the enhancement model;
- repository files are not inspected by the enhancement pass;
- attachment contents are not read or sent;
- the Codex process runs in a temporary directory;
- the sandbox is read-only;
- the Codex session is ephemeral;
- logs contain operational metadata, not prompt contents;
- replacement is aborted when the composer changed while the model was running.

See [Architecture and security model](docs/architecture.md) for the full flow.

## Requirements

### Runtime

- macOS
- Cursor
- OpenAI Codex CLI installed and authenticated
- Prompt Enhancer skill installed at:

  ```text
  ~/.agents/skills/prompt-enhancer/SKILL.md
  ```

- macOS Accessibility permission for the bundled native helper
- Cursor started with:

  ```text
  --force-renderer-accessibility=complete
  ```

A dedicated launcher is strongly recommended because tested Cursor versions do not reliably apply this Chromium flag from `argv.json`.

### Building from source

- Node.js and npm
- Swift compiler
- Xcode Command Line Tools

## Installation

The complete installation procedure covers:

- Codex CLI and skill prerequisites
- prebuilt VSIX installation
- source builds
- the required Cursor launcher
- Accessibility permission
- upgrades and verification

See **[Installation](docs/installation.md)**.

## Configuration

Open Cursor Settings and search for **Codex Prompt Enhancer**.

Available settings:

| Setting | Purpose |
| --- | --- |
| `codexPromptEnhancer.codexPath` | Path to the Codex CLI executable |
| `codexPromptEnhancer.model` | Model used for prompt enhancement |
| `codexPromptEnhancer.reasoningEffort` | Reasoning effort for the lightweight rewrite |
| `codexPromptEnhancer.timeoutSeconds` | Maximum duration of one enhancement run |

The default configuration is designed for short, low-latency prompt transformations rather than repository analysis.

## How it works

```text
Focused Codex composer
        │
        ▼
macOS Accessibility helper reads canonical serialized text
        │
        ▼
Inline references become protected placeholders
        │
        ▼
Codex CLI invokes the $prompt-enhancer skill
in an empty temporary directory
        │
        ▼
References are restored and validated
        │
        ▼
Native helper checks that the original prompt is still current
        │
        ▼
Enhanced text is pasted back with Cmd+V
        │
        ▼
Clipboard is restored; prompt remains unsent
```

## Known limitations

- macOS only
- Cursor only
- The Codex composer must be focused when the shortcut is pressed
- Cursor must be launched with renderer accessibility enabled
- The status-bar item is informational rather than interactive
- Attachment contents are intentionally not analyzed
- Accessibility behavior may change when Cursor updates its Electron or Codex UI implementation

## Documentation

| Document | Contents |
| --- | --- |
| [Installation](docs/installation.md) | Prerequisites, VSIX installation, launcher setup, permissions, upgrades |
| [Architecture](docs/architecture.md) | Components, data flow, privacy boundaries, failure safety |
| [Development](docs/development.md) | Repository structure, build commands, testing, packaging, release checklist |
| [Troubleshooting](docs/troubleshooting.md) | Common errors and recovery steps |
| [Contributing](CONTRIBUTING.md) | Contribution workflow and project scope |
| [Security](SECURITY.md) | Security assumptions and vulnerability reporting |

## Development quick start

```bash
npm install
npm run build
```

Launch the Extension Development Host with `F5`.

Create a local VSIX:

```bash
npm run package:vsix
```

Install the newest package into Cursor:

```bash
npm run install:local
```

See [Development](docs/development.md) before changing the native accessibility helper or replacement flow.

## License

MIT. See [LICENSE](LICENSE).
