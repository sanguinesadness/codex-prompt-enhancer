import type {
  CodexRunnerConfiguration,
} from "./configuration";

type CodexRequestConfiguration = Pick<
  CodexRunnerConfiguration,
  "model" | "reasoningEffort"
>;

export const DISABLED_CODEX_FEATURES = [
  "shell_tool",
  "unified_exec",
  "code_mode_host",
  "browser_use",
  "browser_use_external",
  "browser_use_full_cdp_access",
  "computer_use",
  "apps",
  "image_generation",
  "multi_agent",
  "multi_agent_v2",
  "hooks",
  "workspace_dependencies",
] as const;

export function buildEnhancementRequest(
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

export function buildCodexArguments(
  configuration: CodexRequestConfiguration,
  temporaryDirectory: string,
  outputFile: string,
): string[] {
  const args: string[] = [
    "--ask-for-approval",
    "never",
  ];

  for (const feature of DISABLED_CODEX_FEATURES) {
    args.push("--disable", feature);
  }

  args.push(
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
  );

  if (configuration.model !== undefined) {
    args.push("--model", configuration.model);
  }

  args.push("-");

  return args;
}
