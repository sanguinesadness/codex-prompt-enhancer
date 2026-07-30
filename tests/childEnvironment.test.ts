import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  buildCodexEnvironment,
  buildHelperEnvironment,
} from "../src/childEnvironment";

describe("child process environments", () => {
  const source: NodeJS.ProcessEnv = {
    HOME: "/example-root",
    TMPDIR: "/tmp/example",
    LANG: "en_US.UTF-8",
    LC_ALL: "en_US.UTF-8",
    LC_CTYPE: "UTF-8",
    PATH: "/usr/bin:/bin",
    CODEX_HOME: "/example-root/.codex",
    OPENAI_API_KEY: "synthetic-openai-key",
    OPENAI_ORG_ID: "org_synthetic",
    OPENAI_ORGANIZATION: "org_synthetic_alias",
    OPENAI_PROJECT_ID: "proj_synthetic",
    OPENAI_PROJECT: "proj_synthetic_alias",
    OPENAI_BASE_URL: "https://example.invalid/v1",
    HTTPS_PROXY: "https://proxy.example.invalid",
    no_proxy: "localhost",
    SSL_CERT_FILE: "/synthetic/cert.pem",
    AWS_SECRET_ACCESS_KEY: "synthetic-aws-secret",
    GITHUB_TOKEN: "synthetic-github-token",
    VSCODE_IPC_HOOK: "/synthetic/editor.sock",
    PRIVATE_PROJECT_SECRET: "synthetic-project-secret",
  };

  it("gives the helper only runtime and locale variables", () => {
    const environment = buildHelperEnvironment(source);

    assert.deepEqual(environment, {
      HOME: source.HOME,
      TMPDIR: source.TMPDIR,
      LANG: source.LANG,
      LC_ALL: source.LC_ALL,
      LC_CTYPE: source.LC_CTYPE,
    });
  });

  it("preserves only approved Codex authentication and network variables", () => {
    const environment = buildCodexEnvironment(source);

    assert.equal(environment.OPENAI_API_KEY, source.OPENAI_API_KEY);
    assert.equal(environment.CODEX_HOME, source.CODEX_HOME);
    assert.equal(environment.HTTPS_PROXY, source.HTTPS_PROXY);
    assert.equal(environment.no_proxy, source.no_proxy);
    assert.equal(environment.SSL_CERT_FILE, source.SSL_CERT_FILE);
    assert.equal("AWS_SECRET_ACCESS_KEY" in environment, false);
    assert.equal("GITHUB_TOKEN" in environment, false);
    assert.equal("VSCODE_IPC_HOOK" in environment, false);
    assert.equal("PRIVATE_PROJECT_SECRET" in environment, false);
  });

  it("does not mutate the source environment", () => {
    const before = { ...source };

    buildHelperEnvironment(source);
    buildCodexEnvironment(source);

    assert.deepEqual(source, before);
  });
});
