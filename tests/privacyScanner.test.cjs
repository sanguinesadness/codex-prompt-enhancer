const assert = require("node:assert/strict");
const { describe, it } = require("node:test");

const {
  classifyPath,
  classifyTrackedPath,
  scanText,
} = require("../scripts/privacy-check.cjs");

describe("repository privacy scanner", () => {
  it("allows documented synthetic paths", () => {
    assert.deepEqual(
      scanText("Open /Users/example/project/File.tsx"),
      [],
    );
  });

  it("detects personal paths without returning matched content", () => {
    const findings = scanText("Open /Users/private-user/project/File.tsx");

    assert.deepEqual(findings, [
      { line: 1, rule: "personal-macos-home" },
    ]);
  });

  it("detects representative credential patterns", () => {
    const findings = scanText("token=sk-FAKE0123456789ABCDEF");

    assert.deepEqual(findings, [
      { line: 1, rule: "openai-api-key" },
    ]);
  });

  it("detects backup and captured-log paths", () => {
    assert.equal(classifyPath("src/example.ts.backup-before-change")[0]?.rule, "backup-file");
    assert.equal(classifyPath("tests/logs/run.log")[0]?.rule, "captured-prompt-log");
  });

  it("detects tracked generated artifacts", () => {
    assert.equal(
      classifyTrackedPath("release/example.vsix")[0]?.rule,
      "tracked-generated-artifact",
    );
  });
});
