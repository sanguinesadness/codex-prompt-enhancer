export interface HelperPayload {
  readonly ok: boolean;
  readonly error?: string;
  readonly message?: string;
  readonly [key: string]: unknown;
}

export interface AccessibilityReplaceRequest {
  readonly expectedOriginalText: string;
  readonly expectedTargetFingerprint: string;
  readonly replacementText: string;
  readonly restoreClipboard: true;
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

export function isValidTargetFingerprint(
  value: unknown,
): value is string {
  return typeof value === "string"
    && /^[a-f0-9]{64}$/u.test(value);
}

export function buildAccessibilityReplaceRequest(
  expectedOriginalText: string,
  expectedTargetFingerprint: string,
  replacementText: string,
): AccessibilityReplaceRequest {
  if (
    !isValidTargetFingerprint(
      expectedTargetFingerprint,
    )
  ) {
    throw new Error(
      "Invalid composer target fingerprint.",
    );
  }

  return {
    expectedOriginalText,
    expectedTargetFingerprint,
    replacementText,
    restoreClipboard: true,
  };
}

const SAFE_HELPER_DIAGNOSTIC_KEYS = new Set([
  "applicationName",
  "bundleIdentifier",
  "pid",
  "role",
  "focused",
  "valueReadable",
  "selectedTextRangeSettable",
  "selectionMode",
  "validationCode",
  "textLength",
  "utf16Length",
  "accessibilityCharacterCount",
  "clipboardRestored",
  "clipboardRestoreSkippedBecauseChanged",
  "expectedLength",
  "copiedLength",
  "expectedUtf16Length",
  "copiedUtf16Length",
  "expectedReplacementLength",
  "copiedReplacementLength",
  "expectedReplacementUtf16Length",
  "copiedReplacementUtf16Length",
  "stdoutBytes",
  "stderrBytes",
  "exitCode",
  "errorCode",
  "signal",
  "timeoutMilliseconds",
]);

export function extractSafeHelperDiagnostics(
  payload: HelperPayload,
): Readonly<Record<string, unknown>> {
  const safeFields: Record<string, unknown> = {};

  for (const [key, value] of Object.entries(payload)) {
    if (
      SAFE_HELPER_DIAGNOSTIC_KEYS.has(key)
      && isSafeDiagnosticValue(value)
    ) {
      safeFields[key] = value;
    }
  }

  return safeFields;
}

function isSafeDiagnosticValue(
  value: unknown,
): value is string | number | boolean {
  return typeof value === "string"
    || typeof value === "number"
    || typeof value === "boolean";
}
