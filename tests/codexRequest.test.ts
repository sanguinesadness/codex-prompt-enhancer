import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  buildCodexArguments,
  buildEnhancementRequest,
  DISABLED_CODEX_FEATURES,
} from "../src/codexRequest";

describe("Codex request construction", () => {
  it("wraps the original prompt with fixed enhancement constraints", () => {
    const original = "Explain ⟦CODEX_REF_TEST_1:Login⟧ clearly.";
    const request = buildEnhancementRequest(original);

    assert.match(request, /^\$prompt-enhancer\n/u);
    assert.match(request, /Do not run shell commands or other tools\./u);
    assert.match(request, /----- BEGIN ORIGINAL PROMPT -----\n/u);
    assert.match(request, /\n----- END ORIGINAL PROMPT -----$/u);
    assert.ok(request.includes(original));
  });

  it("uses the fixed sandbox and session flags", () => {
    const args = buildCodexArguments(
      { model: "test-model", reasoningEffort: "low" },
      "/tmp/enhancer",
      "/tmp/enhancer/output.txt",
    );

    assert.deepEqual(args.slice(0, 2), ["--ask-for-approval", "never"]);

    const execIndex = args.indexOf("exec");

    assert.ok(execIndex > 1);

    for (const feature of DISABLED_CODEX_FEATURES) {
      const disableIndex = args.findIndex(
        (argument, index) =>
          argument === "--disable"
          && args[index + 1] === feature,
      );

      assert.ok(disableIndex >= 0);
      assert.ok(disableIndex < execIndex);
    }

    assert.ok(args.includes("--ephemeral"));
    assert.ok(args.includes("read-only"));
    assert.ok(args.includes("--ignore-user-config"));
    assert.ok(args.includes("--skip-git-repo-check"));
    assert.deepEqual(args.slice(-3), ["--model", "test-model", "-"]);
  });

  it("omits the model flag when the CLI default is requested", () => {
    const args = buildCodexArguments(
      { model: undefined, reasoningEffort: "medium" },
      "/tmp/enhancer",
      "/tmp/enhancer/output.txt",
    );

    assert.equal(args.includes("--model"), false);
    assert.equal(args.at(-1), "-");
  });
});
