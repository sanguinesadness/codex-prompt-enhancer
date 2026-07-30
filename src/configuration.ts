import * as os from "node:os";
import * as path from "node:path";

import * as vscode from "vscode";

import { CONFIGURATION_SECTION } from "./constants";

export type ReasoningEffort =
  | "minimal"
  | "low"
  | "medium"
  | "high"
  | "xhigh";

export interface CodexRunnerConfiguration {
  readonly codexPath: string;
  readonly model: string | undefined;
  readonly reasoningEffort: ReasoningEffort;
  readonly timeoutMilliseconds: number;
}

const DEFAULT_CODEX_PATH = "~/.local/bin/codex";
const DEFAULT_MODEL = "gpt-5.6-luna";
const DEFAULT_REASONING_EFFORT: ReasoningEffort = "low";
const DEFAULT_TIMEOUT_SECONDS = 90;

export function getCodexRunnerConfiguration():
  CodexRunnerConfiguration {
  const configuration =
    vscode.workspace.getConfiguration(
      CONFIGURATION_SECTION,
    );

  const configuredPath = configuration.get<string>(
    "codexPath",
    DEFAULT_CODEX_PATH,
  );

  const configuredModel = configuration
    .get<string>("model", DEFAULT_MODEL)
    .trim();

  const reasoningEffort =
    configuration.get<ReasoningEffort>(
      "reasoningEffort",
      DEFAULT_REASONING_EFFORT,
    );

  const timeoutSeconds = clamp(
    configuration.get<number>(
      "timeoutSeconds",
      DEFAULT_TIMEOUT_SECONDS,
    ),
    10,
    300,
  );

  return {
    codexPath: resolveHomePath(configuredPath),
    model:
      configuredModel.length > 0
        ? configuredModel
        : undefined,
    reasoningEffort,
    timeoutMilliseconds: timeoutSeconds * 1_000,
  };
}

function resolveHomePath(value: string): string {
  const trimmed = value.trim();

  if (trimmed === "~") {
    return os.homedir();
  }

  if (trimmed.startsWith("~/")) {
    return path.join(
      os.homedir(),
      trimmed.slice(2),
    );
  }

  return path.resolve(trimmed);
}

function clamp(
  value: number,
  minimum: number,
  maximum: number,
): number {
  return Math.min(
    Math.max(value, minimum),
    maximum,
  );
}
