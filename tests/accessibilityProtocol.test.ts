import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as path from "node:path";
import { describe, it } from "node:test";

import {
  buildAccessibilityReplaceRequest,
  extractSafeHelperDiagnostics,
  isValidTargetFingerprint,
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
    assert.equal(
      isValidTargetFingerprint(
        readPayload?.targetFingerprint,
      ),
      true,
    );
    assert.equal(replacePayload?.replacementVerified, true);
  });

  it("validates target fingerprints", () => {
    assert.equal(
      isValidTargetFingerprint("a".repeat(64)),
      true,
    );
    assert.equal(
      isValidTargetFingerprint("A".repeat(64)),
      false,
    );
    assert.equal(
      isValidTargetFingerprint("a".repeat(63)),
      false,
    );
    assert.equal(
      isValidTargetFingerprint(undefined),
      false,
    );
  });

  it("builds replacement requests with target binding", () => {
    const fingerprint = "c".repeat(64);
    const request = buildAccessibilityReplaceRequest(
      "Original synthetic prompt",
      fingerprint,
      "Enhanced synthetic prompt",
    );

    assert.deepEqual(request, {
      expectedOriginalText: "Original synthetic prompt",
      expectedTargetFingerprint: fingerprint,
      replacementText: "Enhanced synthetic prompt",
      replacementChunks: [
        {
          text: "Enhanced synthetic prompt",
          boundaryKind: "end",
        },
      ],
      restoreClipboard: true,
    });
    assert.throws(
      () => buildAccessibilityReplaceRequest(
        "Original",
        "invalid",
        "Enhanced",
      ),
      /Invalid composer target fingerprint/u,
    );
  });

  it("rejects empty, malformed, and array output", () => {
    assert.equal(tryParsePayload(""), undefined);
    assert.equal(tryParsePayload("not-json"), undefined);
    assert.equal(tryParsePayload("[]"), undefined);
  });

  it("allows only known scalar helper diagnostics", () => {
    const payload = tryParsePayload(
      readFixture("accessibility-stale-error.json"),
    );

    assert.ok(payload);
    const safeFields = extractSafeHelperDiagnostics({
      ...payload,
      diagnostics: [
        "Bearer synthetic-secret",
      ],
      nested: {
        replacementText: "Synthetic replacement",
      },
      token: "synthetic-token",
      clipboardSnapshotBytes: 1024,
      clipboardSnapshotItems: 2,
      clipboardSnapshotRepresentations: 3,
      clipboardSnapshotMaximumBytes: 134217728,
      clipboardSnapshotMaximumItems: 32,
      clipboardSnapshotMaximumRepresentations: 128,
      pasteApplicationChangeObserved: true,
      pasteApplicationStabilized: true,
      pasteApplicationTimeoutMilliseconds: 5000,
      pasteChunkIndex: 2,
      pasteChunkCount: 5,
      pasteChunkUtf16Length: 1800,
      pasteChunkMaximumUtf16Length: 1800,
      pasteChunkBoundaryKind: "paragraph",
      verificationMode: "reference_whitespace_normalized",
      referenceWhitespaceNormalizationCount: 4,
      pasteEventsIssued: 5,
      promptRollbackAttempted: true,
      promptRollbackVerified: true,
      promptRollbackUndoCount: 3,
      promptRollbackSkippedBecauseChanged: false,
      clipboardTypes: [
        "public.synthetic-secret",
      ],
      clipboardContents: "Synthetic private text",
    });

    assert.equal(safeFields.expectedLength, 25);
    assert.equal(safeFields.copiedLength, 26);
    assert.equal(safeFields.clipboardRestored, true);
    assert.equal(safeFields.clipboardSnapshotBytes, 1024);
    assert.equal(safeFields.clipboardSnapshotItems, 2);
    assert.equal(
      safeFields.clipboardSnapshotRepresentations,
      3,
    );
    assert.equal(
      safeFields.clipboardSnapshotMaximumBytes,
      134217728,
    );
    assert.equal(
      safeFields.clipboardSnapshotMaximumItems,
      32,
    );
    assert.equal(
      safeFields.clipboardSnapshotMaximumRepresentations,
      128,
    );
    assert.equal(
      safeFields.pasteApplicationChangeObserved,
      true,
    );
    assert.equal(
      safeFields.pasteApplicationStabilized,
      true,
    );
    assert.equal(
      safeFields.pasteApplicationTimeoutMilliseconds,
      5000,
    );
    assert.equal(safeFields.pasteChunkIndex, 2);
    assert.equal(safeFields.pasteChunkCount, 5);
    assert.equal(safeFields.pasteChunkUtf16Length, 1800);
    assert.equal(
      safeFields.pasteChunkMaximumUtf16Length,
      1800,
    );
    assert.equal(safeFields.pasteChunkBoundaryKind, "paragraph");
    assert.equal(
      safeFields.verificationMode,
      "reference_whitespace_normalized",
    );
    assert.equal(
      safeFields.referenceWhitespaceNormalizationCount,
      4,
    );
    assert.equal(safeFields.pasteEventsIssued, 5);
    assert.equal(safeFields.promptRollbackAttempted, true);
    assert.equal(safeFields.promptRollbackVerified, true);
    assert.equal(safeFields.promptRollbackUndoCount, 3);
    assert.equal(
      safeFields.promptRollbackSkippedBecauseChanged,
      false,
    );
    assert.equal("expectedOriginalText" in safeFields, false);
    assert.equal("replacementText" in safeFields, false);
    assert.equal("diagnostics" in safeFields, false);
    assert.equal("nested" in safeFields, false);
    assert.equal("token" in safeFields, false);
    assert.equal("clipboardTypes" in safeFields, false);
    assert.equal("clipboardContents" in safeFields, false);
  });

  it("keeps target mismatch diagnostics safe", () => {
    const payload = tryParsePayload(
      readFixture("accessibility-target-changed-error.json"),
    );

    assert.ok(payload);
    const safeFields = extractSafeHelperDiagnostics(payload);

    assert.deepEqual(safeFields, {
      selectionMode: "fallback",
      validationCode: "target_fingerprint_mismatch",
    });
    assert.equal("targetFingerprint" in safeFields, false);
    assert.equal("replacementText" in safeFields, false);
  });
});
