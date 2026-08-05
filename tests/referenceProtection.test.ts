import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as path from "node:path";
import { describe, it } from "node:test";

import {
  MAX_SERIALIZED_PASTE_CHUNKS,
  planSerializedPromptPaste,
  protectInlineReferences,
  ReferenceProtectionError,
  restoreInlineReferences,
  splitSerializedPromptForPaste,
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

  it("restores a long prompt with many references", () => {
    const sections = Array.from(
      { length: 24 },
      (_, index) => [
        `Section ${index + 1}:`,
        "Review the current behavior and all relevant edge cases.",
        "Preserve the requested scope and provide concrete reasoning.",
        `[Synthetic${index + 1}](/synthetic/project/module-${index + 1}.ts)`,
        "Additional context ".repeat(70),
      ].join(" "),
    );
    const original = sections.join("\n\n");
    const protectedPrompt =
      protectInlineReferences(original);

    assert.ok(original.length > 25_000);
    assert.equal(
      protectedPrompt.references.length,
      24,
    );
    assert.equal(
      restoreInlineReferences(
        protectedPrompt.text,
        protectedPrompt,
      ),
      original,
    );

    const chunks =
      splitSerializedPromptForPaste(original);

    assert.ok(chunks.length > 10);
    assert.ok(
      chunks.length <= MAX_SERIALIZED_PASTE_CHUNKS,
    );
    assert.equal(chunks.join(""), original);
    assert.equal(
      chunks.every(
        (chunk) => chunk.length <= 1_800,
      ),
      true,
    );

    for (const reference of protectedPrompt.references) {
      assert.equal(
        chunks.filter(
          (chunk) => chunk.includes(reference.raw),
        ).length,
        1,
      );
    }
  });

  it("does not split Unicode surrogate pairs", () => {
    const text = "abc 😀 zzz zzz";
    const chunks = splitSerializedPromptForPaste(
      text,
      6,
    );

    assert.equal(chunks.join(""), text);
    assert.equal(
      chunks.some(
        (chunk) => chunk.includes("\uD83D")
          !== chunk.includes("\uDE00"),
      ),
      false,
    );
  });

  it("prefers paragraph, line, then whitespace boundaries", () => {
    const paragraphText = `${"a".repeat(26)}\n\n${"b".repeat(30)}`;
    const lineText = `${"a".repeat(26)}\n${"b".repeat(30)}`;
    const whitespaceText = `${"a".repeat(26)} ${"b".repeat(30)}`;

    assert.equal(
      planSerializedPromptPaste(
        paragraphText,
        40,
      )[0]?.boundaryKind,
      "paragraph",
    );
    assert.equal(
      planSerializedPromptPaste(
        lineText,
        40,
      )[0]?.boundaryKind,
      "line",
    );
    assert.equal(
      planSerializedPromptPaste(
        whitespaceText,
        40,
      )[0]?.boundaryKind,
      "whitespace",
    );
  });

  it("keeps supported Markdown structures indivisible", () => {
    const structures = [
      "[reference](/synthetic/project/file.ts)",
      "[link](https://example.invalid/path)",
      "![image](https://example.invalid/image.png)",
      "<https://example.invalid/autolink>",
      "`inline code with spaces`",
      "**bold text with spaces**",
      "__strong text with spaces__",
      "_emphasized text with spaces_",
      "~~removed text with spaces~~",
    ];
    const text = structures
      .map((structure) => `before ${structure} after`)
      .join("\n");
    const chunks = planSerializedPromptPaste(
      text,
      80,
    );

    assert.equal(
      chunks.map((chunk) => chunk.text).join(""),
      text,
    );

    for (const structure of structures) {
      assert.equal(
        chunks.filter(
          (chunk) => chunk.text.includes(structure),
        ).length,
        1,
      );
    }
  });

  it("keeps fenced code blocks indivisible", () => {
    const codeBlock = [
      "```ts",
      "const value = 'synthetic';",
      "console.log(value);",
      "```",
    ].join("\n");
    const text = `before text\n\n${codeBlock}\n\nafter text`;
    const chunks = planSerializedPromptPaste(
      text,
      90,
    );

    assert.equal(
      chunks.map((chunk) => chunk.text).join(""),
      text,
    );
    assert.equal(
      chunks.filter(
        (chunk) => chunk.text.includes(codeBlock),
      ).length,
      1,
    );
  });

  it("fails closed for oversized protected structures", () => {
    const oversizedStructures = [
      `\`${"inline ".repeat(20)}\``,
      `[label](/${"path/".repeat(30)}file.ts)`,
      `<https://example.invalid/${"path/".repeat(30)}>`,
      `**${"strong ".repeat(19)}strong**`,
      [
        "```text",
        "code line\n".repeat(20),
        "```",
      ].join("\n"),
    ];

    for (const structure of oversizedStructures) {
      assert.throws(
        () => planSerializedPromptPaste(
          structure,
          60,
        ),
        (error: unknown) => error instanceof ReferenceProtectionError
          && error.code
            === "protected_markdown_structure_too_large",
      );
    }
  });

  it("handles unmatched Markdown delimiters conservatively", () => {
    assert.throws(
      () => planSerializedPromptPaste(
        `\`${"open code ".repeat(20)}`,
        60,
      ),
      (error: unknown) => error instanceof ReferenceProtectionError
        && error.code
          === "protected_markdown_structure_too_large",
    );

    const unmatchedEmphasis = `*${"plain words ".repeat(20)}`;
    assert.equal(
      planSerializedPromptPaste(
        unmatchedEmphasis,
        60,
      ).map((chunk) => chunk.text).join(""),
      unmatchedEmphasis,
    );
  });

  it("fails when no safe boundary or chunk capacity remains", () => {
    assert.throws(
      () => planSerializedPromptPaste(
        "x".repeat(100),
        20,
      ),
      (error: unknown) => error instanceof ReferenceProtectionError
        && error.code
          === "paste_chunk_boundary_unavailable",
    );
    assert.throws(
      () => planSerializedPromptPaste(
        "word ".repeat(20),
        10,
        2,
      ),
      (error: unknown) => error instanceof ReferenceProtectionError
        && error.code === "paste_chunk_count_exceeded",
    );
  });

  it("produces deterministic plans and accepts exact limits", () => {
    const exactStructure = `\`${"x".repeat(18)}\``;
    const text = `${exactStructure} trailing words`;
    const first = planSerializedPromptPaste(
      text,
      20,
    );
    const second = planSerializedPromptPaste(
      text,
      20,
    );

    assert.deepEqual(first, second);
    assert.equal(first[0]?.text, exactStructure);
    assert.equal(
      first.map((chunk) => chunk.text).join(""),
      text,
    );
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
