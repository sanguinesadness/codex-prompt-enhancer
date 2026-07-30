import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as path from "node:path";
import { describe, it } from "node:test";

import {
  protectInlineReferences,
  ReferenceProtectionError,
  restoreInlineReferences,
} from "../src/referenceProtection";

interface PromptFixture {
  readonly id: string;
  readonly language: string;
  readonly text: string;
}

describe("inline reference protection", () => {
  it("leaves text without local references unchanged", () => {
    const original = "Explain the current behavior.";
    const protectedPrompt = protectInlineReferences(original);

    assert.equal(protectedPrompt.text, original);
    assert.deepEqual(protectedPrompt.references, []);
  });

  it("protects and restores one reference byte-for-byte", () => {
    const original = "Explain [Login](/Users/example/project/Login.tsx).";
    const protectedPrompt = protectInlineReferences(original);

    assert.equal(protectedPrompt.references.length, 1);
    assert.doesNotMatch(protectedPrompt.text, /\/Users\/example/u);
    assert.equal(
      restoreInlineReferences(protectedPrompt.text, protectedPrompt),
      original,
    );
  });

  it("handles multiple references and paths with spaces", () => {
    const original = [
      "Compare [First](/Users/example/project/First File.tsx)",
      "with [Second](file:///Users/example/project/Second%20File.tsx).",
    ].join(" ");
    const protectedPrompt = protectInlineReferences(original);

    assert.equal(protectedPrompt.references.length, 2);
    assert.equal(
      restoreInlineReferences(protectedPrompt.text, protectedPrompt),
      original,
    );
  });

  it("handles balanced delimiters in labels and destinations", () => {
    const original = "Explain [Login [primary]](/Users/example/project/(auth)/Login.tsx).";
    const protectedPrompt = protectInlineReferences(original);

    assert.equal(protectedPrompt.references.length, 1);
    assert.equal(
      restoreInlineReferences(protectedPrompt.text, protectedPrompt),
      original,
    );
  });

  it("protects every synthetic language and intent fixture", () => {
    const fixtures = JSON.parse(
      readFileSync(
        path.join(process.cwd(), "tests", "fixtures", "prompt-cases.json"),
        "utf8",
      ),
    ) as PromptFixture[];

    assert.deepEqual(
      fixtures.map(({ id }) => id),
      [
        "english-explanation",
        "russian-explanation",
        "implementation-request",
      ],
    );
    assert.deepEqual(
      new Set(fixtures.map(({ language }) => language)),
      new Set(["en", "ru"]),
    );

    for (const fixture of fixtures) {
      const protectedPrompt = protectInlineReferences(fixture.text);
      assert.equal(protectedPrompt.references.length, 1);
      assert.equal(
        restoreInlineReferences(protectedPrompt.text, protectedPrompt),
        fixture.text,
      );
    }
  });

  it("rejects a missing placeholder", () => {
    const protectedPrompt = protectInlineReferences(
      "Explain [Login](/Users/example/project/Login.tsx).",
    );

    assert.throws(
      () => restoreInlineReferences("Explain Login.", protectedPrompt),
      (error: unknown) => error instanceof ReferenceProtectionError
        && error.code === "reference_placeholder_missing",
    );
  });

  it("rejects a duplicated placeholder", () => {
    const protectedPrompt = protectInlineReferences(
      "Explain [Login](/Users/example/project/Login.tsx).",
    );
    const placeholder = protectedPrompt.references[0]?.placeholder;

    assert.ok(placeholder);
    assert.throws(
      () => restoreInlineReferences(`${placeholder} ${placeholder}`, protectedPrompt),
      (error: unknown) => error instanceof ReferenceProtectionError
        && error.code === "reference_placeholder_duplicated",
    );
  });

  it("rejects an unknown placeholder", () => {
    const protectedPrompt = protectInlineReferences(
      "Explain [Login](/Users/example/project/Login.tsx).",
    );
    const enhanced = `${protectedPrompt.text} ${protectedPrompt.placeholderPrefix}999:unknown⟧`;

    assert.throws(
      () => restoreInlineReferences(enhanced, protectedPrompt),
      (error: unknown) => error instanceof ReferenceProtectionError
        && error.code === "unknown_reference_placeholder",
    );
  });
});
