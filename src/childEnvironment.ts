const HELPER_ENVIRONMENT_KEYS = [
  "HOME",
  "TMPDIR",
  "LANG",
  "LC_ALL",
  "LC_CTYPE",
] as const;

const CODEX_ENVIRONMENT_KEYS = [
  ...HELPER_ENVIRONMENT_KEYS,
  "PATH",
  "CODEX_HOME",
  "OPENAI_API_KEY",
  "OPENAI_ORG_ID",
  "OPENAI_ORGANIZATION",
  "OPENAI_PROJECT_ID",
  "OPENAI_PROJECT",
  "OPENAI_BASE_URL",
  "HTTP_PROXY",
  "HTTPS_PROXY",
  "ALL_PROXY",
  "NO_PROXY",
  "http_proxy",
  "https_proxy",
  "all_proxy",
  "no_proxy",
  "SSL_CERT_FILE",
  "SSL_CERT_DIR",
] as const;

export function buildHelperEnvironment(
  source: NodeJS.ProcessEnv,
): NodeJS.ProcessEnv {
  return selectEnvironment(
    source,
    HELPER_ENVIRONMENT_KEYS,
  );
}

export function buildCodexEnvironment(
  source: NodeJS.ProcessEnv,
): NodeJS.ProcessEnv {
  return selectEnvironment(
    source,
    CODEX_ENVIRONMENT_KEYS,
  );
}

function selectEnvironment(
  source: NodeJS.ProcessEnv,
  keys: readonly string[],
): NodeJS.ProcessEnv {
  const environment: NodeJS.ProcessEnv = {};

  for (const key of keys) {
    const value = source[key];

    if (value !== undefined) {
      environment[key] = value;
    }
  }

  return environment;
}
