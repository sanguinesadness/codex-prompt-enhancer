# Security policy

## Supported versions

Security fixes are applied to the latest released version.

## Reporting a vulnerability

Do not open a public issue for a vulnerability that could expose:

- prompt contents;
- local file paths;
- clipboard contents;
- authentication data;
- attachment content;
- arbitrary local command execution.

Use GitHub’s private security advisory feature for the repository, or contact the maintainer through a private channel listed on the maintainer’s GitHub profile.

Include:

- affected version;
- macOS and Cursor versions;
- reproduction steps;
- expected and actual behavior;
- impact;
- suggested mitigation, when known.

Do not include real secrets or sensitive prompt content. Use synthetic examples.

## Security design

The project reduces risk by:

- spawning Codex without a shell;
- sending prompts through stdin;
- running in a temporary directory;
- using a read-only sandbox;
- using ephemeral sessions;
- hiding inline reference paths from the model;
- not inspecting attachment contents;
- not sending prompts automatically;
- refusing stale or unverifiable replacements;
- restoring the clipboard;
- avoiding prompt content in logs.

## Important trust boundaries

Users must trust:

- the installed extension package;
- the native helper binary;
- the local Codex CLI;
- the `$prompt-enhancer` skill;
- the configured Codex account and model.

The extension is not a sandbox against malicious local software or a maliciously modified skill file.
