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

import { buildCodexEnvironment } from "./childEnvironment";
import { getCodexRunnerConfiguration } from "./configuration";
import {
  buildCodexArguments,
  buildEnhancementRequest,
} from "./codexRequest";
import {
  isSupportedCodexVersion,
  MINIMUM_CODEX_VERSION,
  parseCodexVersionOutput,
} from "./codexVersion";

const TEMP_DIRECTORY_PREFIX =
  "codex-prompt-enhancer-";

const OUTPUT_FILENAME =
  "enhanced-prompt.txt";

const VERSION_CHECK_TIMEOUT_MS = 5_000;
const MAX_VERSION_STDOUT_BYTES = 256;

type SafeDiagnosticValue =
  string | number | boolean;

export type SafeCodexDiagnosticMetadata =
  Readonly<Record<string, SafeDiagnosticValue>>;

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
    public readonly metadata?:
      SafeCodexDiagnosticMetadata,
  ) {
    super(message);
    this.name = "CodexRunnerError";
  }
}

export class CodexRunner {
  private readonly versionChecks =
    new Map<string, Promise<string>>();

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

    const environment = buildCodexEnvironment(
      process.env,
    );

    const cliVersion =
      await this.getSupportedVersion(
        configuration.codexPath,
        environment,
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
        `cliVersion=${cliVersion}`,
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
        environment,
        cliVersion,
        timeoutMilliseconds:
          configuration.timeoutMilliseconds,
        cancellationToken,
      });

      if (processResult.exitCode !== 0) {
        throw new CodexRunnerError(
          "codex_process_failed",
          `Codex exited with code ${processResult.exitCode}.`,
          {
            stage: "enhancement",
            exitCode: processResult.exitCode,
            stdoutBytes: processResult.stdoutBytes,
            stderrBytes: processResult.stderrBytes,
            cliVersion,
          },
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
          {
            stage: "read_output",
            errorCode: getSystemErrorCode(error),
            cliVersion,
          },
        );
      }

      const enhancedPrompt =
        finalMessage.trim();

      if (enhancedPrompt.length === 0) {
        throw new CodexRunnerError(
          "empty_codex_output",
          "Codex returned an empty enhanced prompt.",
          {
            stage: "read_output",
            cliVersion,
          },
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

  private getSupportedVersion(
    executable: string,
    environment: NodeJS.ProcessEnv,
  ): Promise<string> {
    const existing = this.versionChecks.get(
      executable,
    );

    if (existing !== undefined) {
      return existing;
    }

    const check = verifySupportedCodexVersion(
      executable,
      environment,
    ).catch((error: unknown) => {
      this.versionChecks.delete(executable);
      throw error;
    });

    this.versionChecks.set(executable, check);
    return check;
  }
}

interface ProcessOptions {
  readonly executable: string;
  readonly args: readonly string[];
  readonly stdin: string;
  readonly environment: NodeJS.ProcessEnv;
  readonly cliVersion: string;
  readonly timeoutMilliseconds: number;
  readonly cancellationToken:
    vscode.CancellationToken;
}

interface ProcessResult {
  readonly exitCode: number;
  readonly stdoutBytes: number;
  readonly stderrBytes: number;
}

interface ChildExit {
  readonly exitCode: number | null;
  readonly signal: NodeJS.Signals | null;
}

interface MutableProcessState {
  cancelled: boolean;
  timedOut: boolean;
}

interface VersionProcessState {
  timedOut: boolean;
  stdoutLimitExceeded: boolean;
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
      "The configured Codex CLI executable was not found or is not executable.",
      {
        stage: "executable_check",
      },
    );
  }
}

async function verifySupportedCodexVersion(
  executable: string,
  environment: NodeJS.ProcessEnv,
): Promise<string> {
  const child = spawn(
    executable,
    ["--version"],
    {
      cwd: os.homedir(),
      env: environment,
      shell: false,
      stdio: [
        "pipe",
        "pipe",
        "pipe",
      ],
    },
  );

  const state: VersionProcessState = {
    timedOut: false,
    stdoutLimitExceeded: false,
  };

  let stdout = "";
  let stdoutBytes = 0;
  let stderrBytes = 0;

  child.stdout.setEncoding("utf8");

  child.stdout.on(
    "data",
    (chunk: string) => {
      stdoutBytes += Buffer.byteLength(
        chunk,
        "utf8",
      );

      if (
        state.stdoutLimitExceeded
        || stdoutBytes > MAX_VERSION_STDOUT_BYTES
      ) {
        state.stdoutLimitExceeded = true;
        return;
      }

      stdout += chunk;
    },
  );

  child.stderr.on(
    "data",
    (chunk: Buffer) => {
      stderrBytes += chunk.length;
    },
  );

  const timeout = setTimeout(() => {
    state.timedOut = true;
    terminateProcess(child);
  }, VERSION_CHECK_TIMEOUT_MS);

  try {
    child.stdin.end();

    const exit = await waitForVersionExit(child);

    if (state.timedOut) {
      throw new CodexRunnerError(
        "codex_version_check_timeout",
        "Checking the Codex CLI version timed out.",
        {
          stage: "version_check",
          timeoutMilliseconds:
            VERSION_CHECK_TIMEOUT_MS,
          stdoutBytes,
          stderrBytes,
        },
      );
    }

    if (state.stdoutLimitExceeded) {
      throw new CodexRunnerError(
        "codex_version_invalid",
        "The Codex CLI returned an invalid version response.",
        {
          stage: "version_check",
          exitCode: exit.exitCode ?? 0,
          stdoutBytes,
          stderrBytes,
        },
      );
    }

    if (exit.signal !== null) {
      throw new CodexRunnerError(
        "codex_version_check_terminated",
        `The Codex CLI version check terminated with signal ${exit.signal}.`,
        {
          stage: "version_check",
          signal: exit.signal,
          stdoutBytes,
          stderrBytes,
        },
      );
    }

    const exitCode = exit.exitCode ?? 1;

    if (exitCode !== 0) {
      throw new CodexRunnerError(
        "codex_version_check_failed",
        "Could not determine the Codex CLI version.",
        {
          stage: "version_check",
          exitCode,
          stdoutBytes,
          stderrBytes,
        },
      );
    }

    const version = parseCodexVersionOutput(stdout);

    if (version === undefined) {
      throw new CodexRunnerError(
        "codex_version_invalid",
        "The Codex CLI returned an unrecognized version response.",
        {
          stage: "version_check",
          exitCode,
          stdoutBytes,
          stderrBytes,
        },
      );
    }

    if (!isSupportedCodexVersion(version)) {
      throw new CodexRunnerError(
        "codex_version_unsupported",
        [
          `Codex CLI ${MINIMUM_CODEX_VERSION} or newer is required.`,
          "Update the configured Codex CLI and try again.",
        ].join(" "),
        {
          stage: "version_check",
          cliVersion: version,
        },
      );
    }

    return version;
  } finally {
    clearTimeout(timeout);
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
      env: options.environment,
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

  let stdoutBytes = 0;
  let stderrBytes = 0;

  child.stdout.on(
    "data",
    (chunk: Buffer) => {
      stdoutBytes += chunk.length;
    },
  );

  child.stderr.on(
    "data",
    (chunk: Buffer) => {
      stderrBytes += chunk.length;
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

    const exit = await waitForCodexExit(
      child,
      options.cliVersion,
    );

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
        {
          stage: "enhancement",
          timeoutMilliseconds:
            options.timeoutMilliseconds,
          stdoutBytes,
          stderrBytes,
          cliVersion: options.cliVersion,
        },
      );
    }

    if (exit.signal !== null) {
      throw new CodexRunnerError(
        "codex_terminated",
        `Codex terminated with signal ${exit.signal}.`,
        {
          stage: "enhancement",
          signal: exit.signal,
          cliVersion: options.cliVersion,
        },
      );
    }

    const exitCode = exit.exitCode ?? 1;

    return {
      exitCode,
      stdoutBytes,
      stderrBytes,
    };
  } finally {
    clearTimeout(timeout);
    cancellationSubscription.dispose();
  }
}

function waitForVersionExit(
  child: ChildProcessWithoutNullStreams,
): Promise<ChildExit> {
  return new Promise<ChildExit>(
    (resolve, reject) => {
      child.once(
        "error",
        (error: Error) => {
          reject(
            new CodexRunnerError(
              "codex_version_check_failed",
              "Failed to start the Codex CLI version check.",
              {
                stage: "version_check",
                errorCode: getSystemErrorCode(error),
              },
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
          resolve({
            exitCode: code,
            signal,
          });
        },
      );
    },
  );
}

function waitForCodexExit(
  child: ChildProcessWithoutNullStreams,
  cliVersion: string,
): Promise<ChildExit> {
  return new Promise<ChildExit>(
    (resolve, reject) => {
      child.once(
        "error",
        (error: Error) => {
          reject(
            new CodexRunnerError(
              "codex_spawn_failed",
              "Failed to start the Codex CLI process.",
              {
                stage: "enhancement",
                errorCode: getSystemErrorCode(error),
                cliVersion,
              },
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
          resolve({
            exitCode: code,
            signal,
          });
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
        if (child.signalCode !== null) {
          return;
        }

        child.kill("SIGKILL");
      }
    }, 2_000);

  forceKillTimeout.unref();
}

function getSystemErrorCode(
  error: unknown,
): string {
  if (
    typeof error === "object"
    && error !== null
    && "code" in error
    && typeof error.code === "string"
  ) {
    return error.code;
  }

  return "unknown";
}
