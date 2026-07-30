import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as path from "node:path";
import { describe, it } from "node:test";

import {
  removePromptFields,
  tryParsePayload,
} from "../src/accessibilityProtocol";

function readFixture(name: string): string {
  return readFileSync(
    path.join(process.cwd(), "tests", "fixtures", name),
    "utf8",
  );
}

describe("accessibility helper protocol", () => {
  it("parses synthetic read and replacement responses", () => {
    const readPayload = tryParsePayload(
      readFixture("accessibility-read-success.json"),
    );
    const replacePayload = tryParsePayload(
      readFixture("accessibility-replace-success.json"),
    );

    assert.equal(readPayload?.ok, true);
    assert.equal(typeof readPayload?.text, "string");
    assert.equal(replacePayload?.replacementVerified, true);
  });

  it("rejects empty, malformed, and array output", () => {
    assert.equal(tryParsePayload(""), undefined);
    assert.equal(tryParsePayload("not-json"), undefined);
    assert.equal(tryParsePayload("[]"), undefined);
  });

  it("removes prompt-bearing fields from error diagnostics", () => {
    const payload = tryParsePayload(
      readFixture("accessibility-stale-error.json"),
    );

    assert.ok(payload);
    const safeFields = removePromptFields(payload);

    assert.equal(safeFields.error, "stale_prompt");
    assert.equal("expectedOriginalText" in safeFields, false);
    assert.equal("replacementText" in safeFields, false);
  });
});
