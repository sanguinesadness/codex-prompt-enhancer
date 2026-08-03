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
- requiring Codex CLI 0.145.0 or newer;
- sending prompts through stdin;
- running in a temporary directory;
- using a read-only sandbox;
- disabling Codex execution, browser, app, computer-use, multi-agent, hook, and workspace-dependency capabilities;
- passing only allowlisted environment variables to child processes;
- using ephemeral sessions;
- hiding inline reference paths from the model;
- not inspecting attachment contents;
- not sending prompts automatically;
- refusing focused editor, terminal, search, quick-input, output, debug, rename, and SCM text fields when Cursor exposes identifying Accessibility context;
- requiring strong Codex-specific semantic and geometry evidence before using accessibility fallback discovery;
- binding replacement to a prompt-free fingerprint of the composer originally read;
- refusing stale or unverifiable replacements;
- limiting clipboard snapshots to 128 MiB, 32 items, and 128 representations before any pasteboard mutation;
- restoring helper-owned temporary clipboard state on success, handled failures, and cooperative `SIGTERM` or `SIGINT`;
- preserving newer clipboard changes made concurrently by the user or another application;
- giving helper termination five seconds for cooperative cleanup while retaining a two-second Codex process grace period;
- recording only structured, allowlisted failure metadata rather than raw child-process output.

Clipboard restoration cannot be guaranteed after `SIGKILL`, a process crash, power loss, or an unresponsive macOS pasteboard. Snapshot diagnostics contain only byte, item, representation, and configured-limit counts; clipboard contents and type names are not logged.

## Important trust boundaries

Users must trust:

- the installed extension package;
- the native helper binary;
- the local Codex CLI;
- the `$prompt-enhancer` skill;
- the configured Codex account and model.

The extension is not a sandbox against malicious local software or a maliciously modified skill file.
