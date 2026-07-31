import * as vscode from "vscode";

import {
  AccessibilityClient,
  AccessibilityClientError,
} from "./accessibilityClient";
import {
  CodexRunner,
  CodexRunnerError,
} from "./codexRunner";
import {
  protectInlineReferences,
  ReferenceProtectionError,
  restoreInlineReferences,
} from "./referenceProtection";
import { extractSafeCodexDiagnostics } from "./safeDiagnostics";

interface EnhancementOutcome {
  readonly changed: boolean;
  readonly referenceCount: number;
  readonly originalLength: number;
  readonly enhancedLength: number;
  readonly totalDurationMilliseconds: number;
}

export class EnhancerController
  implements vscode.Disposable {
  private isRunning = false;

  public constructor(
    private readonly statusBarItem:
      vscode.StatusBarItem,
    private readonly output:
      vscode.OutputChannel,
    private readonly accessibilityClient:
      AccessibilityClient,
    private readonly codexRunner:
      CodexRunner,
  ) {}

  public async run(): Promise<void> {
    if (process.platform !== "darwin") {
      void vscode.window.showErrorMessage(
        "Codex Prompt Enhancer currently supports macOS only.",
      );
      return;
    }

    if (this.isRunning) {
      void vscode.window.showInformationMessage(
        "Prompt enhancement is already running.",
      );
      return;
    }

    this.isRunning = true;
    this.setRunningState();

    const startedAt = Date.now();

    this.output.appendLine(
      `[${new Date().toISOString()}] Complete enhancement flow started.`,
    );

    try {
      const outcome =
        await vscode.window.withProgress(
          {
            location:
              vscode.ProgressLocation.Window,
            title:
              "$(sync~spin) Enhancing Codex prompt",
            cancellable: false,
          },
          async (
            progress,
            cancellationToken,
          ): Promise<EnhancementOutcome> => {
            progress.report({
              message:
                "Reading current prompt…",
            });

            const readResult =
              await this.accessibilityClient.read(
                cancellationToken,
              );

            const originalPrompt =
              readResult.text;

            if (
              originalPrompt.trim().length === 0
            ) {
              throw new EnhancementFlowError(
                "empty_prompt",
                "The Codex prompt is empty.",
              );
            }

            const protectedPrompt =
              protectInlineReferences(
                originalPrompt,
              );

            this.output.appendLine(
              [
                `[${new Date().toISOString()}]`,
                "Prompt read successfully.",
                `length=${originalPrompt.length}`,
                `references=${protectedPrompt.references.length}`,
              ].join(" "),
            );

            progress.report({
              message:
                "Improving wording and structure…",
            });

            const enhancementResult =
              await this.codexRunner.enhance(
                protectedPrompt.text,
                cancellationToken,
              );

            progress.report({
              message:
                "Restoring inline references…",
            });

            const restoredPrompt =
              restoreInlineReferences(
                enhancementResult.text,
                protectedPrompt,
              );

            if (
              restoredPrompt.trim().length === 0
            ) {
              throw new EnhancementFlowError(
                "empty_enhanced_prompt",
                "The enhanced prompt is empty.",
              );
            }

            if (
              restoredPrompt ===
              originalPrompt
            ) {
              return {
                changed: false,
                referenceCount:
                  protectedPrompt.references.length,
                originalLength:
                  originalPrompt.length,
                enhancedLength:
                  restoredPrompt.length,
                totalDurationMilliseconds:
                  Date.now() - startedAt,
              };
            }

            progress.report({
              message:
                "Updating Codex composer…",
            });

            await this.accessibilityClient.replace(
              originalPrompt,
              readResult.targetFingerprint,
              restoredPrompt,
              cancellationToken,
            );

            return {
              changed: true,
              referenceCount:
                protectedPrompt.references.length,
              originalLength:
                originalPrompt.length,
              enhancedLength:
                restoredPrompt.length,
              totalDurationMilliseconds:
                Date.now() - startedAt,
            };
          },
        );

      this.output.appendLine(
        [
          `[${new Date().toISOString()}]`,
          "Complete enhancement flow finished.",
          `changed=${outcome.changed}`,
          `references=${outcome.referenceCount}`,
          `originalLength=${outcome.originalLength}`,
          `enhancedLength=${outcome.enhancedLength}`,
          `durationMs=${outcome.totalDurationMilliseconds}`,
        ].join(" "),
      );

      // Successful completion is visible through
      // the updated composer and status-bar state.
      // Avoid showing a notification over the Codex input.
    } catch (error: unknown) {
      if (
        error instanceof
        vscode.CancellationError
      ) {
        this.output.appendLine(
          `[${new Date().toISOString()}] Enhancement cancelled.`,
        );
        return;
      }

      const message =
        getUserFacingError(error);

      this.output.appendLine(
        `[${new Date().toISOString()}] Enhancement failed: ${message}`,
      );

      appendSafeDiagnostics(
        this.output,
        error,
      );

      this.output.show(true);

      void vscode.window.showErrorMessage(
        `Codex Prompt Enhancer: ${message}`,
      );
    } finally {
      this.isRunning = false;
      this.setReadyState();
    }
  }

  public dispose(): void {
    // No controller-owned resources.
  }

  private setRunningState(): void {
    this.statusBarItem.text =
      "$(sync~spin) Enhancing…";

    this.statusBarItem.tooltip =
      "Codex prompt enhancement is running";

    this.statusBarItem.command =
      undefined;
  }

  private setReadyState(): void {
    this.statusBarItem.text =
      "$(sparkle) Enhance: ⇧⌘R";

    this.statusBarItem.tooltip =
      "Focus the Codex prompt and press Cmd+Shift+R to enhance it.";

    this.statusBarItem.command = undefined;
  }
}

class EnhancementFlowError extends Error {
  public constructor(
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "EnhancementFlowError";
  }
}

function getUserFacingError(
  error: unknown,
): string {
  if (
    error instanceof
    AccessibilityClientError
  ) {
    switch (error.code) {
    case "codex_composer_not_focused":
      return [
        "The focused control is not the Codex prompt field.",
        "Place the caret inside the Codex composer and try again.",
      ].join(" ");

    case "codex_composer_not_found":
      return [
        "Could not safely identify the Codex prompt field.",
        "Keep a Codex chat with a visible composer open.",
        "Cursor must be launched with",
        "--force-renderer-accessibility=complete.",
      ].join(" ");

    case "accessibility_permission_required":
      return [
        "macOS Accessibility permission is required.",
        "Enable Cursor and the native helper under",
        "System Settings → Privacy & Security → Accessibility.",
      ].join(" ");

    case "stale_prompt":
      return [
        "The prompt changed while enhancement was running.",
        "Nothing was replaced.",
      ].join(" ");

    case "composer_target_changed":
      return [
        "The Codex composer changed while enhancement was running.",
        "Nothing was replaced. Focus the intended composer and try again.",
      ].join(" ");

    case "native_helper_not_executable":
      return [
        "The bundled macOS helper is missing",
        "or is not executable.",
      ].join(" ");

    case "native_helper_output_too_large":
      return [
        "The current prompt is too large",
        "for the native helper response limit.",
      ].join(" ");

    default:
      return error.message;
    }
  }

  if (
    error instanceof
    ReferenceProtectionError
  ) {
    return error.message;
  }

  if (error instanceof CodexRunnerError) {
    return error.message;
  }

  if (
    error instanceof
    EnhancementFlowError
  ) {
    return error.message;
  }

  if (error instanceof Error) {
    return error.message;
  }

  return String(error);
}

function appendSafeDiagnostics(
  output: vscode.OutputChannel,
  error: unknown,
): void {
  if (
    error instanceof CodexRunnerError
    && error.metadata !== undefined
  ) {
    const safeMetadata =
      extractSafeCodexDiagnostics(
        error.metadata,
      );

    if (Object.keys(safeMetadata).length === 0) {
      return;
    }

    output.appendLine(
      `Codex failure metadata: ${JSON.stringify(
        safeMetadata,
      )}`,
    );
    return;
  }

  if (
    error instanceof
    AccessibilityClientError
    && error.details !== undefined
    && Object.keys(error.details).length > 0
  ) {
    output.appendLine(
      `Native helper diagnostics: ${JSON.stringify(
        error.details,
      )}`,
    );
  }
}
