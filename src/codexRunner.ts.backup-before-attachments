import {
  constants as fileSystemConstants,
} from "node:fs";
import {
  access,
  mkdtemp,
  readFile,
  rm,
} from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import {
  ChildProcessWithoutNullStreams,
  spawn,
} from "node:child_process";

import * as vscode from "vscode";

import {
  CodexRunnerConfiguration,
  getCodexRunnerConfiguration,
} from "./configuration";

const TEMP_DIRECTORY_PREFIX =
  "codex-prompt-enhancer-";

const OUTPUT_FILENAME =
  "enhanced-prompt.txt";

const MAX_DIAGNOSTIC_LENGTH = 8_000;

export interface CodexEnhancementResult {
  readonly text: string;
  readonly durationMilliseconds: number;
  readonly model: string | undefined;
  readonly reasoningEffort: string;
}

export class CodexRunnerError extends Error {
  public constructor(
    public readonly code: string,
    message: string,
    public readonly diagnostics?: string,
  ) {
    super(message);
    this.name = "CodexRunnerError";
  }
}

export class CodexRunner {
  public constructor(
    private readonly output: vscode.OutputChannel,
  ) {}

  public async enhance(
    originalPrompt: string,
    cancellationToken:
      vscode.CancellationToken,
  ): Promise<CodexEnhancementResult> {
    const prompt = originalPrompt;

    if (prompt.trim().length === 0) {
      throw new CodexRunnerError(
        "empty_prompt",
        "The prompt is empty.",
      );
    }

    const configuration =
      getCodexRunnerConfiguration();

    await verifyCodexExecutable(
      configuration.codexPath,
    );

    if (cancellationToken.isCancellationRequested) {
      throw new vscode.CancellationError();
    }

    const startedAt = Date.now();

    const temporaryDirectory =
      await mkdtemp(
        path.join(
          os.tmpdir(),
          TEMP_DIRECTORY_PREFIX,
        ),
      );

    const outputFile = path.join(
      temporaryDirectory,
      OUTPUT_FILENAME,
    );

    this.output.appendLine(
      [
        `[${new Date().toISOString()}]`,
        "Starting Codex enhancement.",
        `model=${configuration.model ?? "<default>"}`,
        `reasoning=${configuration.reasoningEffort}`,
      ].join(" "),
    );

    try {
      const request = buildEnhancementRequest(
        prompt,
      );

      const args = buildCodexArguments(
        configuration,
        temporaryDirectory,
        outputFile,
      );

      const processResult = await runCodexProcess({
        executable: configuration.codexPath,
        args,
        stdin: request,
        timeoutMilliseconds:
          configuration.timeoutMilliseconds,
        cancellationToken,
      });

      if (processResult.exitCode !== 0) {
        throw new CodexRunnerError(
          "codex_process_failed",
          `Codex exited with code ${processResult.exitCode}.`,
          truncateDiagnostic(
            processResult.stderr,
          ),
        );
      }

      let finalMessage: string;

      try {
        finalMessage = await readFile(
          outputFile,
          "utf8",
        );
      } catch (error: unknown) {
        throw new CodexRunnerError(
          "codex_output_missing",
          "Codex completed without producing a final output file.",
          getErrorMessage(error),
        );
      }

      const enhancedPrompt =
        finalMessage.trim();

      if (enhancedPrompt.length === 0) {
        throw new CodexRunnerError(
          "empty_codex_output",
          "Codex returned an empty enhanced prompt.",
        );
      }

      const durationMilliseconds =
        Date.now() - startedAt;

      this.output.appendLine(
        [
          `[${new Date().toISOString()}]`,
          "Codex enhancement completed.",
          `durationMs=${durationMilliseconds}`,
          `resultLength=${enhancedPrompt.length}`,
        ].join(" "),
      );

      return {
        text: enhancedPrompt,
        durationMilliseconds,
        model: configuration.model,
        reasoningEffort:
          configuration.reasoningEffort,
      };
    } finally {
      await rm(
        temporaryDirectory,
        {
          recursive: true,
          force: true,
        },
      );
    }
  }
}

interface ProcessOptions {
  readonly executable: string;
  readonly args: readonly string[];
  readonly stdin: string;
  readonly timeoutMilliseconds: number;
  readonly cancellationToken:
    vscode.CancellationToken;
}

interface ProcessResult {
  readonly exitCode: number;
  readonly stdout: string;
  readonly stderr: string;
}

interface MutableProcessState {
  cancelled: boolean;
  timedOut: boolean;
}

function buildEnhancementRequest(
  originalPrompt: string,
): string {
  return [
    "$prompt-enhancer",
    "",
    "Use light prompt-enhancement mode.",
    "",
    "Important constraints for this enhancement pass:",
    "- Rewrite only the supplied prompt.",
    "- Do not answer or implement the prompt.",
    "- Do not inspect repository files, referenced paths, attachments, screenshots, or external resources.",
    "- Do not run shell commands or other tools.",
    "- Preserve the language and original intent.",
    "- Preserve every placeholder matching ⟦CODEX_REF_*⟧ exactly.",
    "- Do not remove, duplicate, translate, reformat, rename, split, or wrap placeholders in backticks.",
    "- Keep each placeholder attached to the same surrounding meaning as in the original prompt.",
    "- Return only the enhanced prompt.",
    "",
    "----- BEGIN ORIGINAL PROMPT -----",
    originalPrompt,
    "----- END ORIGINAL PROMPT -----",
  ].join("\n");
}

function buildCodexArguments(
  configuration: CodexRunnerConfiguration,
  temporaryDirectory: string,
  outputFile: string,
): string[] {
  const args: string[] = [
    "--ask-for-approval",
    "never",

    "exec",

    "--ephemeral",
    "--sandbox",
    "read-only",
    "--ignore-user-config",
    "--skip-git-repo-check",
    "--color",
    "never",
    "--cd",
    temporaryDirectory,
    "--output-last-message",
    outputFile,

    "--config",
    `model_reasoning_effort="${configuration.reasoningEffort}"`,

    "--config",
    'model_reasoning_summary="none"',

    "--config",
    'model_verbosity="low"',
  ];

  if (configuration.model !== undefined) {
    args.push(
      "--model",
      configuration.model,
    );
  }

  // A single dash tells `codex exec` to read
  // the initial prompt from stdin.
  args.push("-");

  return args;
}

async function verifyCodexExecutable(
  executablePath: string,
): Promise<void> {
  try {
    await access(
      executablePath,
      fileSystemConstants.X_OK,
    );
  } catch {
    throw new CodexRunnerError(
      "codex_not_executable",
      [
        "Codex CLI was not found or is not executable:",
        executablePath,
      ].join("\n"),
    );
  }
}

async function runCodexProcess(
  options: ProcessOptions,
): Promise<ProcessResult> {
  const child = spawn(
    options.executable,
    [...options.args],
    {
      cwd: os.homedir(),
      env: process.env,
      shell: false,
      stdio: [
        "pipe",
        "pipe",
        "pipe",
      ],
    },
  );

  const state: MutableProcessState = {
    cancelled: false,
    timedOut: false,
  };

  let stdout = "";
  let stderr = "";

  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");

  child.stdout.on(
    "data",
    (chunk: string) => {
      stdout = appendBounded(
        stdout,
        chunk,
      );
    },
  );

  child.stderr.on(
    "data",
    (chunk: string) => {
      stderr = appendBounded(
        stderr,
        chunk,
      );
    },
  );

  const cancellationSubscription =
    options.cancellationToken
      .onCancellationRequested(() => {
        state.cancelled = true;
        terminateProcess(child);
      });

  const timeout = setTimeout(() => {
    state.timedOut = true;
    terminateProcess(child);
  }, options.timeoutMilliseconds);

  try {
    child.stdin.end(options.stdin);

    const exitCode = await waitForExit(child);

    if (state.cancelled) {
      throw new vscode.CancellationError();
    }

    if (state.timedOut) {
      throw new CodexRunnerError(
        "codex_timeout",
        [
          "Codex prompt enhancement timed out after",
          `${Math.round(
            options.timeoutMilliseconds / 1_000,
          )} seconds.`,
        ].join(" "),
        truncateDiagnostic(stderr),
      );
    }

    return {
      exitCode,
      stdout,
      stderr,
    };
  } finally {
    clearTimeout(timeout);
    cancellationSubscription.dispose();
  }
}

function waitForExit(
  child: ChildProcessWithoutNullStreams,
): Promise<number> {
  return new Promise<number>(
    (resolve, reject) => {
      child.once(
        "error",
        (error: Error) => {
          reject(
            new CodexRunnerError(
              "codex_spawn_failed",
              "Failed to start the Codex CLI process.",
              error.message,
            ),
          );
        },
      );

      child.once(
        "close",
        (
          code: number | null,
          signal: NodeJS.Signals | null,
        ) => {
          if (code !== null) {
            resolve(code);
            return;
          }

          reject(
            new CodexRunnerError(
              "codex_terminated",
              `Codex terminated with signal ${signal ?? "unknown"}.`,
            ),
          );
        },
      );
    },
  );
}

function terminateProcess(
  child: ChildProcessWithoutNullStreams,
): void {
  if (child.exitCode !== null) {
    return;
  }

  child.kill("SIGTERM");

  const forceKillTimeout =
    setTimeout(() => {
      if (child.exitCode === null) {
        child.kill("SIGKILL");
      }
    }, 2_000);

  forceKillTimeout.unref();
}

function appendBounded(
  current: string,
  chunk: string,
): string {
  const combined = current + chunk;

  if (
    combined.length
    <= MAX_DIAGNOSTIC_LENGTH
  ) {
    return combined;
  }

  return combined.slice(
    -MAX_DIAGNOSTIC_LENGTH,
  );
}

function truncateDiagnostic(
  value: string,
): string | undefined {
  const trimmed = value.trim();

  if (trimmed.length === 0) {
    return undefined;
  }

  return trimmed.slice(
    -MAX_DIAGNOSTIC_LENGTH,
  );
}

function getErrorMessage(
  error: unknown,
): string {
  if (error instanceof Error) {
    return error.message;
  }

  return String(error);
}
