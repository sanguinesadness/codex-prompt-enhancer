export interface HelperPayload {
  readonly ok: boolean;
  readonly error?: string;
  readonly message?: string;
  readonly [key: string]: unknown;
}

export function tryParsePayload(
  stdout: string,
): HelperPayload | undefined {
  const trimmed = stdout.trim();

  if (trimmed.length === 0) {
    return undefined;
  }

  try {
    const parsed: unknown = JSON.parse(trimmed);

    if (
      typeof parsed !== "object"
      || parsed === null
      || Array.isArray(parsed)
    ) {
      return undefined;
    }

    return parsed as HelperPayload;
  } catch {
    return undefined;
  }
}

export function removePromptFields(
  payload: HelperPayload,
): Readonly<Record<string, unknown>> {
  const {
    text: _text,
    serializedText: _serializedText,
    renderedText: _renderedText,
    expectedOriginalText: _expectedOriginalText,
    replacementText: _replacementText,
    ...safeFields
  } = payload;

  return safeFields;
}
