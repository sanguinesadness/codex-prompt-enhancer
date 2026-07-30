import * as vscode from "vscode";

import {
  AccessibilityClient,
} from "./accessibilityClient";
import {
  COMMANDS,
  OUTPUT_CHANNEL_NAME,
  STATUS_BAR_ITEM_ID,
} from "./constants";
import { CodexRunner } from "./codexRunner";
import { EnhancerController } from "./enhancerController";
import {
  registerTestCodexRunnerCommand,
} from "./testCodexRunnerCommand";

export function activate(
  context: vscode.ExtensionContext,
): void {
  const output =
    vscode.window.createOutputChannel(
      OUTPUT_CHANNEL_NAME,
    );

  const statusBarItem =
    vscode.window.createStatusBarItem(
      STATUS_BAR_ITEM_ID,
      vscode.StatusBarAlignment.Right,
      100,
    );

  statusBarItem.name =
    "Codex Prompt Enhancer";

  statusBarItem.text =
    "$(sparkle) Enhance: ⇧⌘R";

  statusBarItem.tooltip =
    "Focus the Codex prompt and press Cmd+Shift+R to enhance it.";

  // Informational only. Clicking it does nothing.
  statusBarItem.command = undefined;

  statusBarItem.show();

  const helperPath =
    context.asAbsolutePath(
      "bin/prompt-accessibility-helper",
    );

  const accessibilityClient =
    new AccessibilityClient(
      helperPath,
      output,
    );

  const codexRunner =
    new CodexRunner(output);

  const controller =
    new EnhancerController(
      statusBarItem,
      output,
      accessibilityClient,
      codexRunner,
    );

  const enhanceCommand =
    vscode.commands.registerCommand(
      COMMANDS.enhanceCurrentPrompt,
      async () => {
        await controller.run();
      },
    );

  const testCodexRunnerCommand =
    registerTestCodexRunnerCommand(
      codexRunner,
      output,
    );

  context.subscriptions.push(
    output,
    statusBarItem,
    controller,
    enhanceCommand,
    testCodexRunnerCommand,
  );

  output.appendLine(
    [
      `[${new Date().toISOString()}]`,
      "Extension activated.",
      `helperPath=${helperPath}`,
    ].join(" "),
  );
}

export function deactivate(): void {
  // Resources are disposed through
  // context.subscriptions.
}
