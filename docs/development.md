# Development

## Prerequisites

- macOS
- Cursor
- Node.js 22 and npm for development tooling
- Swift compiler
- Xcode Command Line Tools
- Codex CLI
- authenticated Codex session
- `$prompt-enhancer` skill

Verify the toolchain:

```bash
node --version
npm --version
swiftc --version
"$HOME/.local/bin/codex" --version
```

The extension remains compatible with the Node 18 extension host used by the declared VS Code 1.85 API baseline. Node.js 22 is used only for repository tooling and CI.

## Repository layout

```text
codex-prompt-enhancer/
├── .github/       macOS continuous-integration workflow
├── .vscode/       Extension Development Host launch/tasks
├── bin/           Compiled native helper
├── dist/          Compiled JavaScript
├── native/        Swift helper source
├── release/       Locally generated VSIX packages
├── scripts/       Build, package, and install scripts
├── src/           TypeScript extension source
├── tests/         Synthetic fixtures and unit tests
├── package.json
├── tsconfig.json
└── tsconfig.test.json
```

Generated or machine-specific files such as `node_modules/`, `.DS_Store`, local backups, and release artifacts should not be committed.

## Install dependencies

```bash
npm install
```

## Build

Build the native helper and extension:

```bash
npm run build
```

Compile TypeScript only:

```bash
npm run compile
```

Build the Swift helper only:

```bash
npm run build:native
```

## Quality checks

Run the complete source quality gate:

```bash
npm run check
```

This runs:

- TypeScript type checking against the declared VS Code API baseline;
- ESLint correctness rules;
- synthetic unit tests;
- repository privacy and artifact scanning.

Run the same checks plus a production VSIX build and verification:

```bash
npm run ci
```

The GitHub Actions workflow runs `npm run ci` on macOS for pushes and pull requests. It verifies the package inside the job and does not upload the VSIX as a workflow artifact.

## Run in the Extension Development Host

1. Open the repository in Cursor.
2. Start the parent Cursor instance with:

   ```bash
   open -na "Cursor" \
     --args \
     --force-renderer-accessibility=complete
   ```

3. Press `F5`.
4. Test inside the **Extension Development Host** window.

The test window also needs renderer accessibility because the helper reads that window’s Codex composer.

## Package a VSIX

```bash
npm run package:vsix
```

The package script:

- rebuilds the native helper;
- compiles TypeScript;
- chooses `darwin-arm64` or `darwin-x64`;
- creates the VSIX in `release/`;
- verifies that `dist/extension.js` is included;
- verifies that `bin/prompt-accessibility-helper` is included and executable;
- rejects probe binaries, backup files, sources, tests, and development commands;
- verifies that the packaged helper matches the current build.

## Install the local package

```bash
npm run install:local
```

The script installs the newest VSIX with Cursor’s CLI. When the CLI is unavailable, install manually through:

```text
Extensions: Install from VSIX...
```

## Configuration during development

The extension contributes these settings:

```text
codexPromptEnhancer.codexPath
codexPromptEnhancer.model
codexPromptEnhancer.reasoningEffort
codexPromptEnhancer.timeoutSeconds
```

Avoid hardcoding user-specific paths outside default configuration handling.

## Testing checklist

### Core behavior

- Empty prompt is rejected
- English input remains English
- Russian input remains Russian
- Explanation requests remain explanation requests
- Implementation requests remain implementation requests
- No prompt is sent automatically

### Inline references

- One reference remains clickable
- Multiple references remain clickable
- Paths with spaces are preserved
- Missing placeholder aborts replacement
- Duplicated placeholder aborts replacement
- Unknown placeholder aborts replacement

### Attachments

- Screenshot chip remains
- File chip remains
- Folder chip remains
- Attachment content is not included in logs or model input

### Concurrency and failure safety

- Second shortcut press does not start a second run
- Timeout stops Codex
- Editing during enhancement returns `stale_prompt`
- Clipboard is restored after success
- Clipboard is restored after failure
- Failed verification leaves the original prompt intact

### Installation

- VSIX contains the compiled extension
- VSIX contains an executable native helper
- Installed helper has Accessibility permission
- Cursor Enhanced launcher includes the required process flag
- Shortcut works after a full Cursor restart

## Native helper changes

The Swift helper is the highest-risk part of the project.

Before changing it:

1. preserve the canonical clipboard-based read path;
2. preserve stale-prompt verification;
3. preserve clipboard restoration;
4. preserve replacement verification;
5. refuse ambiguous accessibility targets;
6. test with inline references and attachment chips.

Do not replace the paste flow with direct `AXValue` assignment. Direct assignment does not reconstruct clickable Cursor references.

## Release checklist

1. Update `package.json` version.
2. Update `CHANGELOG.md`.
3. Run:

   ```bash
   npm ci
   npm run ci
   ```

4. Install the generated VSIX into a clean Cursor profile.
5. Test the release checklist above.
6. Create a GitHub release.
7. Attach the architecture-specific VSIX.
8. Include the required launcher and permission notes in release notes.
9. Confirm that `npm run privacy:check` reports no credentials, prompt logs, personal paths, backup files, or forbidden generated artifacts.

## Suggested GitHub repository files

Keep the root concise:

```text
README.md
CHANGELOG.md
CONTRIBUTING.md
SECURITY.md
LICENSE
```

Put detailed guides under `docs/`:

```text
docs/
├── installation.md
├── architecture.md
├── development.md
└── troubleshooting.md
```

This keeps the landing page readable while preserving complete technical documentation.
