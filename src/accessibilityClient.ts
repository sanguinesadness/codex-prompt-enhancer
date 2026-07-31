import {
  constants as fileSystemConstants,
} from "node:fs";
import { access } from "node:fs/promises";
import * as path from "node:path";
import {
  ChildProcessWithoutNullStreams,
  spawn,
} from "node:child_process";

import * as vscode from "vscode";

import {
  buildAccessibilityReplaceRequest,
  extractSafeHelperDiagnostics,
  isValidTargetFingerprint,
  tryParsePayload,
} from "./accessibilityProtocol";
import { buildHelperEnvironment } from "./childEnvironment";

const DEFAULT_HELPER_TIMEOUT_MS = 15_000;

// The helper returns structured JSON containing the composer text.
// This must not use the small rolling diagnostics buffer.
const MAX_HELPER_STDOUT_BYTES =
  4 * 1024 * 1024;

export interface AccessibilityReadResult {
  readonly text: string;
  readonly serializedText: string;
  readonly renderedText: string;
  readonly targetFingerprint: string;
  readonly selectionMode?: "focused" | "fallback";
  readonly applicationName?: string;
  readonly bundleIdentifier?: string;
  readonly clipboardRestored?: boolean;
}

export interface AccessibilityReplaceResult {
  readonly replacementVerified: boolean;
  readonly selectionVerified: boolean;
  readonly clipboardRestored: boolean;
  readonly applicationName?: string;
  readonly bundleIdentifier?: string;
  readonly selectionMode?: "focused" | "fallback";
}

interface ProcessState {
  cancelled: boolean;
  timedOut: boolean;
  stdoutLimitExceeded: boolean;
}

interface ProcessResult {
  readonly exitCode: number;
  readonly stdout: string;
  readonly stdoutBytes: number;
  readonly stderrBytes: number;
}

export class AccessibilityClientError extends Error {
  public constructor(
    public readonly code: string,
    message: string,
    public readonly details?: Readonly<
      Record<string, unknown>
    >,
  ) {
    super(message);
    this.name = "AccessibilityClientError";
  }
}

export class AccessibilityClient {
  public constructor(
    private readonly helperPath: string,
    private readonly output: vscode.OutputChannel,
    private readonly timeoutMilliseconds =
      DEFAULT_HELPER_TIMEOUT_MS,
  ) {}

  public async read(
    cancellationToken: vscode.CancellationToken,
  ): Promise<AccessibilityReadResult> {
    const payload =
      await this.runHelper<AccessibilityReadResult>(
        "read",
        undefined,
        cancellationToken,
      );

    if (typeof payload.text !== "string") {
      throw new AccessibilityClientError(
        "invalid_read_response",
        "The native helper returned no serialized prompt text.",
      );
    }

    if (
      !isValidTargetFingerprint(
        payload.targetFingerprint,
      )
    ) {
      throw new AccessibilityClientError(
        "invalid_read_response",
        "The native helper returned no valid composer target fingerprint.",
      );
    }

    return payload;
  }

  public async replace(
    expectedOriginalText: string,
    expectedTargetFingerprint: string,
    replacementText: string,
    cancellationToken: vscode.CancellationToken,
  ): Promise<AccessibilityReplaceResult> {
    const request = JSON.stringify(
      buildAccessibilityReplaceRequest(
        expectedOriginalText,
        expectedTargetFingerprint,
        replacementText,
      ),
    );

    const payload =
      await this.runHelper<AccessibilityReplaceResult>(
        "replace",
        request,
        cancellationToken,
      );

    if (payload.replacementVerified !== true) {
      throw new AccessibilityClientError(
        "replacement_not_verified",
        "The native helper did not verify the replaced prompt.",
      );
    }

    return payload;
  }

  private async runHelper<T>(
    command: "read" | "replace",
    stdin: string | undefined,
    cancellationToken: vscode.CancellationToken,
  ): Promise<T> {
    await verifyExecutable(this.helperPath);

    if (cancellationToken.isCancellationRequested) {
      throw new vscode.CancellationError();
    }

    this.output.appendLine(
      [
        `[${new Date().toISOString()}]`,
        `Native helper command started.`,
        `command=${command}`,
      ].join(" "),
    );

    const processResult = await runProcess({
      executable: this.helperPath,
      args: [command],
      stdin,
      timeoutMilliseconds:
        this.timeoutMilliseconds,
      cancellationToken,
    });

    const payload = tryParsePayload(
      processResult.stdout,
    );

    if (processResult.exitCode !== 0) {
      if (
        payload !== undefined
        && payload.ok === false
      ) {
        throw new AccessibilityClientError(
          typeof payload.error === "string"
            ? payload.error
            : "native_helper_failed",
          typeof payload.message === "string"
            ? payload.message
            : "The native helper failed.",
          extractSafeHelperDiagnostics(payload),
        );
      }

      throw new AccessibilityClientError(
        "native_helper_failed",
        `The native helper exited with code ${processResult.exitCode}.`,
        {
          exitCode: processResult.exitCode,
          stdoutBytes: processResult.stdoutBytes,
          stderrBytes: processResult.stderrBytes,
        },
      );
    }

    if (payload === undefined) {
      throw new AccessibilityClientError(
        "invalid_helper_output",
        "The native helper returned invalid JSON.",
        {
          stdoutBytes: processResult.stdoutBytes,
          stderrBytes: processResult.stderrBytes,
        },
      );
    }

    if (payload.ok !== true) {
      throw new AccessibilityClientError(
        typeof payload.error === "string"
          ? payload.error
          : "native_helper_failed",
        typeof payload.message === "string"
          ? payload.message
          : "The native helper reported failure.",
        extractSafeHelperDiagnostics(payload),
      );
    }

    this.output.appendLine(
      [
        `[${new Date().toISOString()}]`,
        `Native helper command completed.`,
        `command=${command}`,
      ].join(" "),
    );

    return payload as T;
  }
}

interface RunProcessOptions {
  readonly executable: string;
  readonly args: readonly string[];
  readonly stdin: string | undefined;
  readonly timeoutMilliseconds: number;
  readonly cancellationToken:
    vscode.CancellationToken;
}

async function runProcess(
  options: RunProcessOptions,
): Promise<ProcessResult> {
  const child = spawn(
    options.executable,
    [...options.args],
    {
      cwd: path.dirname(options.executable),
      env: buildHelperEnvironment(process.env),
      shell: false,
      stdio: [
        "pipe",
        "pipe",
        "pipe",
      ],
    },
  );

  const state: ProcessState = {
    cancelled: false,
    timedOut: false,
    stdoutLimitExceeded: false,
  };

  let stdout = "";
  let stdoutBytes = 0;
  let stderrBytes = 0;

  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");

  child.stdout.on(
    "data",
    (chunk: string) => {
      stdoutBytes += Buffer.byteLength(
        chunk,
        "utf8",
      );

      if (state.stdoutLimitExceeded) {
        return;
      }

      if (
        stdoutBytes > MAX_HELPER_STDOUT_BYTES
      ) {
        state.stdoutLimitExceeded = true;
        return;
      }

      stdout += chunk;
    },
  );

  child.stderr.on(
    "data",
    (chunk: string) => {
      stderrBytes += Buffer.byteLength(
        chunk,
        "utf8",
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
    child.stdin.end(options.stdin ?? "");

    const exitCode = await waitForExit(child);

    if (state.cancelled) {
      throw new vscode.CancellationError();
    }

    if (state.timedOut) {
      throw new AccessibilityClientError(
        "native_helper_timeout",
        [
          "The native helper timed out after",
          `${Math.round(
            options.timeoutMilliseconds / 1_000,
          )} seconds.`,
        ].join(" "),
        {
          timeoutMilliseconds:
            options.timeoutMilliseconds,
          stdoutBytes,
          stderrBytes,
        },
      );
    }

    if (state.stdoutLimitExceeded) {
      throw new AccessibilityClientError(
        "native_helper_output_too_large",
        [
          "The native helper response exceeded",
          `${Math.round(
            MAX_HELPER_STDOUT_BYTES
              / 1024
              / 1024,
          )} MB.`,
        ].join(" "),
        {
          stdoutBytes,
          stderrBytes,
        },
      );
    }

    return {
      exitCode,
      stdout,
      stdoutBytes,
      stderrBytes,
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
            new AccessibilityClientError(
              "native_helper_spawn_failed",
              "Failed to start the native helper.",
              {
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
          if (code !== null) {
            resolve(code);
            return;
          }

          reject(
            new AccessibilityClientError(
              "native_helper_terminated",
              `The native helper terminated with signal ${signal ?? "unknown"}.`,
              signal === null
                ? undefined
                : { signal },
            ),
          );
        },
      );
    },
  );
}

function getSystemErrorCode(
  error: Error,
): string {
  const code = (error as NodeJS.ErrnoException).code;

  return typeof code === "string"
    ? code
    : "unknown";
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

async function verifyExecutable(
  executablePath: string,
): Promise<void> {
  try {
    await access(
      executablePath,
      fileSystemConstants.X_OK,
    );
  } catch {
    throw new AccessibilityClientError(
      "native_helper_not_executable",
      [
        "The native accessibility helper was not found",
        "or is not executable:",
        executablePath,
      ].join("\n"),
    );
  }
}
