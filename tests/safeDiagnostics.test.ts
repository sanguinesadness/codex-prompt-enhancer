import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { extractSafeCodexDiagnostics } from "../src/safeDiagnostics";

describe("safe Codex diagnostics", () => {
  it("keeps approved process metadata", () => {
    assert.deepEqual(
      extractSafeCodexDiagnostics({
        stage: "enhancement",
        exitCode: 1,
        signal: "SIGTERM",
        timeoutMilliseconds: 90_000,
        stdoutBytes: 128,
        stderrBytes: 256,
        cliVersion: "0.145.0",
        errorCode: "ENOENT",
      }),
      {
        stage: "enhancement",
        exitCode: 1,
        signal: "SIGTERM",
        timeoutMilliseconds: 90_000,
        stdoutBytes: 128,
        stderrBytes: 256,
        cliVersion: "0.145.0",
        errorCode: "ENOENT",
      },
    );
  });

  it("drops prompts, paths, credentials, raw output, and nested values", () => {
    const safe = extractSafeCodexDiagnostics({
      prompt: "Synthetic private prompt",
      path: "/synthetic/private-project",
      token: "Bearer synthetic-token",
      apiKey: "sk-synthetic",
      stderr: "Synthetic private prompt",
      nested: {
        OPENAI_API_KEY: "synthetic-key",
      },
      errorCode: "/synthetic/private-project",
      signal: "Bearer synthetic-token",
      cliVersion: "0.145.0 private",
      stderrBytes: -1,
    });

    assert.deepEqual(safe, {});
  });
});
