import * as vscode from "vscode";

import {
  CodexRunner,
  CodexRunnerError,
} from "./codexRunner";

const DEFAULT_TEST_PROMPT = [
  "look at",
  "⟦CODEX_REF_1:LoginPageContent⟧",
  "and tell me what happening there",
  "dont change anything",
].join(" ");

export function registerTestCodexRunnerCommand(
  runner: CodexRunner,
  output: vscode.OutputChannel,
): vscode.Disposable {
  return vscode.commands.registerCommand(
    "codexPromptEnhancer.testCodexRunner",
    async () => {
      const input =
        await vscode.window.showInputBox({
          title:
            "Test Codex Prompt Enhancer CLI Runner",
          prompt:
            "Enter a rough prompt to enhance.",
          value: DEFAULT_TEST_PROMPT,
          ignoreFocusOut: true,
        });

      if (input === undefined) {
        return;
      }

      try {
        const result =
          await vscode.window.withProgress(
            {
              location:
                vscode.ProgressLocation.Notification,
              title:
                "Testing Codex CLI runner",
              cancellable: true,
            },
            async (
              progress,
              cancellationToken,
            ) => {
              progress.report({
                message:
                  "Enhancing test prompt…",
              });

              return runner.enhance(
                input,
                cancellationToken,
              );
            },
          );

        const document =
          await vscode.workspace.openTextDocument({
            language: "markdown",
            content: result.text,
          });

        await vscode.window.showTextDocument(
          document,
          {
            preview: false,
          },
        );

        output.appendLine(
          [
            `[${new Date().toISOString()}]`,
            "Test command succeeded.",
            `durationMs=${result.durationMilliseconds}`,
          ].join(" "),
        );
      } catch (error: unknown) {
        if (
          error instanceof
          vscode.CancellationError
        ) {
          output.appendLine(
            `[${new Date().toISOString()}] Test command cancelled.`,
          );

          return;
        }

        const message =
          getUserFacingError(error);

        output.appendLine(
          `[${new Date().toISOString()}] Test command failed: ${message}`,
        );

        if (
          error instanceof CodexRunnerError
          && error.diagnostics !== undefined
        ) {
          output.appendLine(
            `Diagnostics: ${error.diagnostics}`,
          );
        }

        output.show(true);

        void vscode.window.showErrorMessage(
          `Codex Prompt Enhancer: ${message}`,
        );
      }
    },
  );
}

function getUserFacingError(
  error: unknown,
): string {
  if (error instanceof CodexRunnerError) {
    return error.message;
  }

  if (error instanceof Error) {
    return error.message;
  }

  return String(error);
}
