import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  isSupportedCodexVersion,
  parseCodexVersionOutput,
} from "../src/codexVersion";

describe("Codex CLI version policy", () => {
  it("parses the supported CLI version format", () => {
    assert.equal(
      parseCodexVersionOutput("codex-cli 0.145.0\n"),
      "0.145.0",
    );
  });

  it("rejects malformed and missing version output", () => {
    assert.equal(parseCodexVersionOutput(""), undefined);
    assert.equal(parseCodexVersionOutput("0.145.0"), undefined);
    assert.equal(parseCodexVersionOutput("codex-cli latest"), undefined);
    assert.equal(parseCodexVersionOutput("codex-cli 0.145"), undefined);
  });

  it("accepts the minimum and newer versions", () => {
    assert.equal(isSupportedCodexVersion("0.145.0"), true);
    assert.equal(isSupportedCodexVersion("0.145.1"), true);
    assert.equal(isSupportedCodexVersion("0.146.0"), true);
    assert.equal(isSupportedCodexVersion("1.0.0"), true);
  });

  it("rejects older and malformed versions", () => {
    assert.equal(isSupportedCodexVersion("0.144.9"), false);
    assert.equal(isSupportedCodexVersion("0.99.0"), false);
    assert.equal(isSupportedCodexVersion("invalid"), false);
  });
});
