import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  appendBounded,
  truncateDiagnostic,
} from "../src/processDiagnostics";

describe("process diagnostics", () => {
  it("retains the newest content within the configured bound", () => {
    assert.equal(appendBounded("12345", "67890", 6), "567890");
  });

  it("trims diagnostics and returns undefined for empty output", () => {
    assert.equal(truncateDiagnostic("  abcdef  ", 4), "cdef");
    assert.equal(truncateDiagnostic(" \n "), undefined);
  });
});
