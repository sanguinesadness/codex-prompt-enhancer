export const MAX_DIAGNOSTIC_LENGTH = 8_000;

export function appendBounded(
  current: string,
  chunk: string,
  maximumLength = MAX_DIAGNOSTIC_LENGTH,
): string {
  const combined = current + chunk;

  if (combined.length <= maximumLength) {
    return combined;
  }

  return combined.slice(-maximumLength);
}

export function truncateDiagnostic(
  value: string,
  maximumLength = MAX_DIAGNOSTIC_LENGTH,
): string | undefined {
  const trimmed = value.trim();

  if (trimmed.length === 0) {
    return undefined;
  }

  return trimmed.slice(-maximumLength);
}
