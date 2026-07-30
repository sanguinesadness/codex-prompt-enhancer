export const MINIMUM_CODEX_VERSION = "0.145.0";

interface SemanticVersion {
  readonly major: number;
  readonly minor: number;
  readonly patch: number;
}

const minimumVersion: SemanticVersion = {
  major: 0,
  minor: 145,
  patch: 0,
};

export function parseCodexVersionOutput(
  output: string,
): string | undefined {
  const match = /^codex-cli\s+(\d+\.\d+\.\d+)\s*$/u.exec(
    output.trim(),
  );

  return match?.[1];
}

export function isSupportedCodexVersion(
  version: string,
): boolean {
  const parsed = parseSemanticVersion(version);

  if (parsed === undefined) {
    return false;
  }

  if (parsed.major !== minimumVersion.major) {
    return parsed.major > minimumVersion.major;
  }

  if (parsed.minor !== minimumVersion.minor) {
    return parsed.minor > minimumVersion.minor;
  }

  return parsed.patch >= minimumVersion.patch;
}

function parseSemanticVersion(
  version: string,
): SemanticVersion | undefined {
  const match = /^(\d+)\.(\d+)\.(\d+)$/u.exec(
    version,
  );

  if (match === null) {
    return undefined;
  }

  return {
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
  };
}
