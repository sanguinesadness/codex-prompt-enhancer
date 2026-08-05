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

export const MAX_SERIALIZED_PASTE_CHUNK_UTF16 = 1_800;
export const MAX_SERIALIZED_PASTE_CHUNKS = 32;

export type PasteChunkBoundaryKind =
  | "paragraph"
  | "line"
  | "whitespace"
  | "end";

export interface SerializedPasteChunk {
  readonly text: string;
  readonly boundaryKind: PasteChunkBoundaryKind;
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

export function splitSerializedPromptForPaste(
  text: string,
  maximumChunkUtf16 =
    MAX_SERIALIZED_PASTE_CHUNK_UTF16,
): readonly string[] {
  return planSerializedPromptPaste(
    text,
    maximumChunkUtf16,
  ).map((chunk) => chunk.text);
}

export function planSerializedPromptPaste(
  text: string,
  maximumChunkUtf16 =
    MAX_SERIALIZED_PASTE_CHUNK_UTF16,
  maximumChunkCount =
    MAX_SERIALIZED_PASTE_CHUNKS,
): readonly SerializedPasteChunk[] {
  if (
    !Number.isInteger(maximumChunkUtf16)
    || maximumChunkUtf16 < 1
  ) {
    throw new Error(
      "Paste chunk size must be a positive integer.",
    );
  }

  if (
    !Number.isInteger(maximumChunkCount)
    || maximumChunkCount < 1
  ) {
    throw new Error(
      "Paste chunk count must be a positive integer.",
    );
  }

  if (text.length === 0) {
    return [];
  }

  const protectedRanges =
    findProtectedMarkdownRanges(text);

  for (const range of protectedRanges) {
    if (
      range.endExclusive - range.start
        > maximumChunkUtf16
    ) {
      throw new ReferenceProtectionError(
        "protected_markdown_structure_too_large",
        [
          "A Markdown structure is too large",
          "to paste safely without splitting it.",
        ].join(" "),
      );
    }
  }

  const boundaries = findSafeBoundaries(
    text,
    protectedRanges,
  );
  const chunks: SerializedPasteChunk[] = [];
  let start = 0;

  while (start < text.length) {
    const maximumEnd = Math.min(
      start + maximumChunkUtf16,
      text.length,
    );

    if (maximumEnd === text.length) {
      chunks.push({
        text: text.slice(start),
        boundaryKind: "end",
      });
      break;
    }

    const boundary = selectSafeBoundary(
      boundaries,
      start,
      maximumEnd,
    );

    if (boundary === undefined) {
      throw new ReferenceProtectionError(
        "paste_chunk_boundary_unavailable",
        [
          "A prompt section has no safe paragraph,",
          "line, or whitespace boundary for pasting.",
        ].join(" "),
      );
    }

    chunks.push({
      text: text.slice(start, boundary.position),
      boundaryKind: boundary.kind,
    });
    start = boundary.position;

    if (chunks.length >= maximumChunkCount) {
      throw new ReferenceProtectionError(
        "paste_chunk_count_exceeded",
        [
          "The enhanced prompt is too large",
          `for the ${maximumChunkCount}-chunk safety limit.`,
        ].join(" "),
      );
    }
  }

  return chunks;
}

interface ReferenceRange {
  readonly start: number;
  readonly endExclusive: number;
}

interface SafeBoundary {
  readonly position: number;
  readonly kind: Exclude<
    PasteChunkBoundaryKind,
    "end"
  >;
}

function findProtectedMarkdownRanges(
  text: string,
): readonly ReferenceRange[] {
  const structuralRanges = mergeRanges([
    ...findFencedCodeRanges(text),
    ...findInlineCodeRanges(text),
    ...findMarkdownLinkRanges(text),
    ...findAutolinkRanges(text),
  ]);

  return mergeRanges([
    ...structuralRanges,
    ...findPairedDelimiterRanges(
      text,
      structuralRanges,
    ),
  ]);
}

function findSafeBoundaries(
  text: string,
  protectedRanges: readonly ReferenceRange[],
): readonly SafeBoundary[] {
  const boundaries: SafeBoundary[] = [];
  let cursor = 0;

  while (cursor < text.length) {
    if (
      text[cursor] === "\r"
      && text[cursor + 1] === "\n"
    ) {
      const start = cursor;

      while (
        text[cursor] === "\r"
        && text[cursor + 1] === "\n"
      ) {
        cursor += 2;
      }

      addBoundary(
        boundaries,
        protectedRanges,
        cursor,
        cursor - start >= 4
          ? "paragraph"
          : "line",
      );
      continue;
    }

    if (text[cursor] === "\n") {
      const start = cursor;

      while (text[cursor] === "\n") {
        cursor += 1;
      }

      addBoundary(
        boundaries,
        protectedRanges,
        cursor,
        cursor - start >= 2
          ? "paragraph"
          : "line",
      );
      continue;
    }

    if (
      text[cursor] === " "
      || text[cursor] === "\t"
    ) {
      addBoundary(
        boundaries,
        protectedRanges,
        cursor,
        "whitespace",
      );

      while (
        text[cursor] === " "
        || text[cursor] === "\t"
      ) {
        cursor += 1;
      }

      addBoundary(
        boundaries,
        protectedRanges,
        cursor,
        "whitespace",
      );
      continue;
    }

    cursor += 1;
  }

  return boundaries;
}

function addBoundary(
  boundaries: SafeBoundary[],
  protectedRanges: readonly ReferenceRange[],
  position: number,
  kind: SafeBoundary["kind"],
): void {
  if (
    protectedRanges.some(
      (range) => range.start < position
        && position < range.endExclusive,
    )
  ) {
    return;
  }

  boundaries.push({ position, kind });
}

function selectSafeBoundary(
  boundaries: readonly SafeBoundary[],
  start: number,
  maximumEnd: number,
): SafeBoundary | undefined {
  const preferredStart = start + Math.floor(
    (maximumEnd - start) * 0.6,
  );

  for (
    const kind of [
      "paragraph",
      "line",
      "whitespace",
    ] as const
  ) {
    for (
      let index = boundaries.length - 1;
      index >= 0;
      index -= 1
    ) {
      const candidate = boundaries[index];

      if (
        candidate?.kind === kind
        && candidate.position >= preferredStart
        && candidate.position <= maximumEnd
      ) {
        return candidate;
      }
    }
  }

  for (
    let index = boundaries.length - 1;
    index >= 0;
    index -= 1
  ) {
    const candidate = boundaries[index];

    if (
      candidate !== undefined
      && candidate.position > start
      && candidate.position <= maximumEnd
    ) {
      return candidate;
    }
  }

  return undefined;
}

function findFencedCodeRanges(
  text: string,
): readonly ReferenceRange[] {
  const ranges: ReferenceRange[] = [];
  let lineStart = 0;

  while (lineStart < text.length) {
    const lineEnd = findLineEnd(text, lineStart);
    const fence = parseFenceLine(
      text.slice(lineStart, lineEnd),
    );

    if (fence === undefined) {
      lineStart = nextLineStart(text, lineEnd);
      continue;
    }

    let closingEnd = text.length;
    let candidateStart = nextLineStart(
      text,
      lineEnd,
    );

    while (candidateStart < text.length) {
      const candidateEnd = findLineEnd(
        text,
        candidateStart,
      );
      const closingFence = parseFenceLine(
        text.slice(candidateStart, candidateEnd),
      );

      if (
        closingFence?.character === fence.character
        && closingFence.length >= fence.length
        && closingFence.onlyFence
      ) {
        closingEnd = nextLineStart(
          text,
          candidateEnd,
        );
        break;
      }

      candidateStart = nextLineStart(
        text,
        candidateEnd,
      );
    }

    ranges.push({
      start: lineStart,
      endExclusive: closingEnd,
    });
    lineStart = closingEnd;
  }

  return ranges;
}

interface FenceLine {
  readonly character: "`" | "~";
  readonly length: number;
  readonly onlyFence: boolean;
}

function parseFenceLine(
  line: string,
): FenceLine | undefined {
  const match = /^( {0,3})(`{3,}|~{3,})(.*)$/u.exec(
    line.replace(/\r$/u, ""),
  );

  if (match === null) {
    return undefined;
  }

  const marker = match[2];
  const suffix = match[3] ?? "";

  if (marker === undefined) {
    return undefined;
  }

  return {
    character: marker[0] as "`" | "~",
    length: marker.length,
    onlyFence: suffix.trim().length === 0,
  };
}

function findInlineCodeRanges(
  text: string,
): readonly ReferenceRange[] {
  const fencedRanges = findFencedCodeRanges(text);
  const ranges: ReferenceRange[] = [];
  let cursor = 0;

  while (cursor < text.length) {
    const fencedRange = rangeContaining(
      fencedRanges,
      cursor,
    );

    if (fencedRange !== undefined) {
      cursor = fencedRange.endExclusive;
      continue;
    }

    if (text[cursor] !== "`") {
      cursor += 1;
      continue;
    }

    const delimiterLength = countRun(
      text,
      cursor,
      "`",
    );
    const delimiter = "`".repeat(delimiterLength);
    const closing = text.indexOf(
      delimiter,
      cursor + delimiterLength,
    );
    const endExclusive = closing === -1
      ? text.length
      : closing + delimiterLength;

    ranges.push({
      start: cursor,
      endExclusive,
    });
    cursor = endExclusive;
  }

  return ranges;
}

function findMarkdownLinkRanges(
  text: string,
): readonly ReferenceRange[] {
  const ranges: ReferenceRange[] = [];
  let cursor = 0;

  while (cursor < text.length) {
    const image = text[cursor] === "!"
      && text[cursor + 1] === "[";
    const labelStart = image
      ? cursor + 1
      : cursor;

    if (text[labelStart] !== "[") {
      cursor += 1;
      continue;
    }

    const labelEnd = findBalancedClosingCharacter({
      text,
      start: labelStart,
      openingCharacter: "[",
      closingCharacter: "]",
    });

    if (
      labelEnd === undefined
      || text[labelEnd + 1] !== "("
    ) {
      cursor += 1;
      continue;
    }

    const destinationEnd =
      findBalancedClosingCharacter({
        text,
        start: labelEnd + 1,
        openingCharacter: "(",
        closingCharacter: ")",
      });

    if (destinationEnd === undefined) {
      cursor += 1;
      continue;
    }

    ranges.push({
      start: cursor,
      endExclusive: destinationEnd + 1,
    });
    cursor = destinationEnd + 1;
  }

  return ranges;
}

function findAutolinkRanges(
  text: string,
): readonly ReferenceRange[] {
  const ranges: ReferenceRange[] = [];
  let cursor = 0;

  while (cursor < text.length) {
    if (text[cursor] !== "<") {
      cursor += 1;
      continue;
    }

    const closing = text.indexOf(">", cursor + 1);

    if (
      closing === -1
      || text.slice(cursor + 1, closing).includes("\n")
    ) {
      cursor += 1;
      continue;
    }

    ranges.push({
      start: cursor,
      endExclusive: closing + 1,
    });
    cursor = closing + 1;
  }

  return ranges;
}

function findPairedDelimiterRanges(
  text: string,
  excludedRanges: readonly ReferenceRange[],
): readonly ReferenceRange[] {
  const ranges: ReferenceRange[] = [];
  const delimiters = ["**", "__", "~~", "*", "_"];
  let cursor = 0;

  while (cursor < text.length) {
    const excludedRange = rangeContaining(
      excludedRanges,
      cursor,
    );

    if (excludedRange !== undefined) {
      cursor = excludedRange.endExclusive;
      continue;
    }

    const delimiter = delimiters.find(
      (candidate) => text.startsWith(candidate, cursor),
    );

    if (
      delimiter === undefined
      || isEscaped(text, cursor)
      || isWhitespace(text[cursor + delimiter.length])
    ) {
      cursor += 1;
      continue;
    }

    let closing = text.indexOf(
      delimiter,
      cursor + delimiter.length,
    );

    while (
      closing !== -1
      && (
        isEscaped(text, closing)
        || isWhitespace(text[closing - 1])
        || rangeContaining(
          excludedRanges,
          closing,
        ) !== undefined
      )
    ) {
      closing = text.indexOf(
        delimiter,
        closing + delimiter.length,
      );
    }

    if (closing === -1) {
      cursor += delimiter.length;
      continue;
    }

    const endExclusive = closing + delimiter.length;
    ranges.push({ start: cursor, endExclusive });
    cursor = endExclusive;
  }

  return ranges;
}

function mergeRanges(
  ranges: readonly ReferenceRange[],
): readonly ReferenceRange[] {
  const sorted = [...ranges].sort(
    (left, right) => left.start - right.start,
  );
  const merged: ReferenceRange[] = [];

  for (const range of sorted) {
    const previous = merged.at(-1);

    if (
      previous !== undefined
      && range.start <= previous.endExclusive
    ) {
      merged[merged.length - 1] = {
        start: previous.start,
        endExclusive: Math.max(
          previous.endExclusive,
          range.endExclusive,
        ),
      };
      continue;
    }

    merged.push(range);
  }

  return merged;
}

function rangeContaining(
  ranges: readonly ReferenceRange[],
  index: number,
): ReferenceRange | undefined {
  return ranges.find(
    (range) => range.start <= index
      && index < range.endExclusive,
  );
}

function countRun(
  text: string,
  start: number,
  character: string,
): number {
  let cursor = start;

  while (text[cursor] === character) {
    cursor += 1;
  }

  return cursor - start;
}

function findLineEnd(
  text: string,
  start: number,
): number {
  const newline = text.indexOf("\n", start);
  return newline === -1
    ? text.length
    : newline;
}

function nextLineStart(
  text: string,
  lineEnd: number,
): number {
  return lineEnd < text.length
    ? lineEnd + 1
    : text.length;
}

function isEscaped(
  text: string,
  index: number,
): boolean {
  let backslashes = 0;

  for (
    let cursor = index - 1;
    cursor >= 0 && text[cursor] === "\\";
    cursor -= 1
  ) {
    backslashes += 1;
  }

  return backslashes % 2 === 1;
}

function isWhitespace(
  character: string | undefined,
): boolean {
  return character === undefined
    || /\s/u.test(character);
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
