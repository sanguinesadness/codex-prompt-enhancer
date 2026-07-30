const SAFE_CODEX_DIAGNOSTIC_KEYS = new Set([
  "stage",
  "exitCode",
  "signal",
  "timeoutMilliseconds",
  "stdoutBytes",
  "stderrBytes",
  "cliVersion",
  "errorCode",
]);

const SAFE_STRING_PATTERNS: Readonly<
  Record<string, RegExp>
> = {
  stage: /^[a-z_]+$/u,
  signal: /^(?:SIG[A-Z0-9]+|unknown)$/u,
  cliVersion: /^\d+\.\d+\.\d+$/u,
  errorCode: /^(?:[A-Z0-9_]+|unknown)$/u,
};

export function extractSafeCodexDiagnostics(
  metadata: Readonly<Record<string, unknown>>,
): Readonly<Record<string, string | number | boolean>> {
  const safeFields: Record<
    string,
    string | number | boolean
  > = {};

  for (const [key, value] of Object.entries(metadata)) {
    if (!SAFE_CODEX_DIAGNOSTIC_KEYS.has(key)) {
      continue;
    }

    if (
      typeof value === "number"
      && Number.isSafeInteger(value)
      && value >= 0
    ) {
      safeFields[key] = value;
      continue;
    }

    if (typeof value === "boolean") {
      safeFields[key] = value;
      continue;
    }

    if (
      typeof value === "string"
      && SAFE_STRING_PATTERNS[key]?.test(value)
    ) {
      safeFields[key] = value;
    }
  }

  return safeFields;
}
