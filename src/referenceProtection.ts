import { randomUUID } from "node:crypto";

export interface ProtectedReference {
  readonly placeholder: string;
  readonly raw: string;
  readonly label: string;
}

export interface ProtectedPrompt {
  readonly text: string;
  readonly references:
    readonly ProtectedReference[];
  readonly placeholderPrefix: string;
}

interface ParsedReference {
  readonly endExclusive: number;
  readonly raw: string;
  readonly label: string;
}

export class ReferenceProtectionError
  extends Error {
  public constructor(
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "ReferenceProtectionError";
  }
}

export function protectInlineReferences(
  originalText: string,
): ProtectedPrompt {
  const nonce = randomUUID()
    .replaceAll("-", "")
    .slice(0, 10)
    .toUpperCase();

  const placeholderPrefix =
    `⟦CODEX_REF_${nonce}_`;

  const references: ProtectedReference[] = [];

  let result = "";
  let unchangedStart = 0;
  let cursor = 0;

  while (cursor < originalText.length) {
    if (originalText[cursor] !== "[") {
      cursor += 1;
      continue;
    }

    const parsed = parseReferenceAt(
      originalText,
      cursor,
    );

    if (parsed === undefined) {
      cursor += 1;
      continue;
    }

    result += originalText.slice(
      unchangedStart,
      cursor,
    );

    const index = references.length + 1;

    const placeholder = [
      placeholderPrefix,
      String(index),
      ":",
      normalizeLabel(parsed.label),
      "⟧",
    ].join("");

    references.push({
      placeholder,
      raw: parsed.raw,
      label: parsed.label,
    });

    result += placeholder;

    cursor = parsed.endExclusive;
    unchangedStart = parsed.endExclusive;
  }

  result += originalText.slice(
    unchangedStart,
  );

  return {
    text: result,
    references,
    placeholderPrefix,
  };
}

export function restoreInlineReferences(
  enhancedText: string,
  protectedPrompt: ProtectedPrompt,
): string {
  let result = enhancedText;

  for (
    const reference
    of protectedPrompt.references
  ) {
    const occurrenceCount =
      countOccurrences(
        result,
        reference.placeholder,
      );

    if (occurrenceCount === 0) {
      throw new ReferenceProtectionError(
        "reference_placeholder_missing",
        [
          "The enhanced prompt lost an inline",
          `reference placeholder for "${reference.label}".`,
          "The original prompt was not replaced.",
        ].join(" "),
      );
    }

    if (occurrenceCount > 1) {
      throw new ReferenceProtectionError(
        "reference_placeholder_duplicated",
        [
          "The enhanced prompt duplicated an inline",
          `reference placeholder for "${reference.label}".`,
          "The original prompt was not replaced.",
        ].join(" "),
      );
    }

    result = result.replace(
      reference.placeholder,
      reference.raw,
    );
  }

  if (
    result.includes(
      protectedPrompt.placeholderPrefix,
    )
  ) {
    throw new ReferenceProtectionError(
      "unknown_reference_placeholder",
      [
        "The enhanced prompt contains an unknown",
        "inline-reference placeholder.",
        "The original prompt was not replaced.",
      ].join(" "),
    );
  }

  return result;
}

function parseReferenceAt(
  text: string,
  start: number,
): ParsedReference | undefined {
  const labelEnd =
    findBalancedClosingCharacter({
      text,
      start,
      openingCharacter: "[",
      closingCharacter: "]",
    });

  if (labelEnd === undefined) {
    return undefined;
  }

  if (
    text[labelEnd + 1] !== "("
  ) {
    return undefined;
  }

  const destinationStart = labelEnd + 2;

  const destinationEnd =
    findBalancedClosingCharacter({
      text,
      start: labelEnd + 1,
      openingCharacter: "(",
      closingCharacter: ")",
    });

  if (destinationEnd === undefined) {
    return undefined;
  }

  const destination = text
    .slice(
      destinationStart,
      destinationEnd,
    )
    .trim();

  if (
    !isLikelyLocalReferenceTarget(
      destination,
    )
  ) {
    return undefined;
  }

  return {
    endExclusive: destinationEnd + 1,
    raw: text.slice(
      start,
      destinationEnd + 1,
    ),
    label: text.slice(
      start + 1,
      labelEnd,
    ),
  };
}

interface BalancedCharacterOptions {
  readonly text: string;
  readonly start: number;
  readonly openingCharacter: string;
  readonly closingCharacter: string;
}

function findBalancedClosingCharacter(
  options: BalancedCharacterOptions,
): number | undefined {
  let depth = 0;

  for (
    let index = options.start;
    index < options.text.length;
    index += 1
  ) {
    const character = options.text[index];

    if (character === "\\") {
      index += 1;
      continue;
    }

    if (
      character ===
      options.openingCharacter
    ) {
      depth += 1;
      continue;
    }

    if (
      character ===
      options.closingCharacter
    ) {
      depth -= 1;

      if (depth === 0) {
        return index;
      }
    }
  }

  return undefined;
}

function isLikelyLocalReferenceTarget(
  destination: string,
): boolean {
  const unwrappedDestination =
    destination.startsWith("<")
    && destination.endsWith(">")
      ? destination.slice(1, -1)
      : destination;

  return (
    unwrappedDestination.startsWith("/")
    || unwrappedDestination.startsWith(
      "file:///",
    )
  );
}

function normalizeLabel(
  label: string,
): string {
  const normalized = label
    .replaceAll("⟦", "")
    .replaceAll("⟧", "")
    .replace(/[\r\n\t]+/gu, " ")
    .replace(/\s+/gu, " ")
    .trim();

  if (normalized.length === 0) {
    return "reference";
  }

  return normalized.slice(0, 80);
}

function countOccurrences(
  text: string,
  search: string,
): number {
  let count = 0;
  let position = 0;

  while (position < text.length) {
    const foundAt = text.indexOf(
      search,
      position,
    );

    if (foundAt === -1) {
      break;
    }

    count += 1;
    position = foundAt + search.length;
  }

  return count;
}
