# Contributing

Contributions are welcome when they preserve the project’s core safety guarantees.

## Before opening a pull request

For substantial changes, open an issue first and describe:

- the user problem;
- the proposed behavior;
- which component changes;
- privacy or Accessibility implications;
- the failure mode when the feature cannot operate safely.

## Project scope

Good candidates:

- more reliable composer detection;
- clearer installation and diagnostics;
- safer packaging and release automation;
- test coverage;
- configuration improvements;
- compatibility fixes for new Cursor releases;
- accessibility and localization improvements.

Out of scope without prior discussion:

- automatic prompt submission;
- repository or attachment inspection during enhancement;
- arbitrary UI automation;
- weakening stale-prompt or placeholder validation;
- logging prompt or attachment contents;
- targeting ambiguous text fields.

## Development workflow

```bash
npm install
npm run build
```

Run the Extension Development Host with `F5`.

Before submitting:

```bash
npm run check
npm run build:native
npm run package:vsix
```

Use the checklist in [Development](docs/development.md).

## Code expectations

- TypeScript must compile in strict mode.
- Spawn child processes with `shell: false`.
- Never interpolate prompt text into shell commands.
- Do not log prompt text, enhanced text, reference paths, or attachment content.
- Keep native helper responses structured and machine-readable.
- Prefer refusing an ambiguous operation over modifying the wrong UI element.
- Preserve clipboard restoration and stale-prompt checks.
- Add comments only where the reasoning is not obvious from the code.

## Pull requests

Include:

- concise summary;
- rationale;
- manual test cases;
- screenshots only when UI changed;
- Cursor and macOS versions used;
- security/privacy impact;
- migration notes when settings or packaging changed.

Do not commit:

- `node_modules/`;
- `.DS_Store`;
- local VSIX files;
- local paths or credentials;
- temporary prompt logs;
- backup source files.

## Reporting bugs

Use the troubleshooting guide first:

[docs/troubleshooting.md](docs/troubleshooting.md)

When filing an issue, redact personal data and include only safe diagnostics.
