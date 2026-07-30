#!/usr/bin/env node

const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const IGNORED_DIRECTORIES = new Set([
  ".git",
  ".test-dist",
  "coverage",
  "dist",
  "node_modules",
  "release",
]);

const CONTENT_SCAN_EXCLUSIONS = new Set([
  "scripts/privacy-check.cjs",
  "tests/privacyScanner.test.cjs",
]);

const FORBIDDEN_PATH_PATTERNS = [
  {
    id: "backup-file",
    pattern: /(?:\.backup[^/]*|\.bak|\.orig|~)$/u,
  },
  {
    id: "captured-prompt-log",
    pattern: /^tests\/(?:logs|results)\//u,
  },
  {
    id: "repository-log",
    pattern: /\.log$/u,
  },
];

const FORBIDDEN_TRACKED_PATH_PATTERNS = [
  {
    id: "tracked-generated-artifact",
    pattern: /^(?:\.test-dist|coverage|dist|node_modules|release)\//u,
  },
];

const FORBIDDEN_CONTENT_PATTERNS = [
  {
    id: "personal-macos-home",
    pattern: /\/Users\/(?!example\/)[^/\s"')]+/gu,
  },
  {
    id: "personal-linux-home",
    pattern: /\/home\/(?!example\/)[^/\s"')]+/gu,
  },
  {
    id: "personal-windows-home",
    pattern: /[A-Za-z]:\\Users\\(?!example\\)[^\\\s"')]+/gu,
  },
  {
    id: "openai-api-key",
    pattern: /sk-[A-Za-z0-9_-]{16,}/gu,
  },
  {
    id: "github-token",
    pattern: /gh[pousr]_[A-Za-z0-9]{20,}/gu,
  },
  {
    id: "aws-access-key",
    pattern: /AKIA[0-9A-Z]{16}/gu,
  },
  {
    id: "private-key",
    pattern: /-----BEGIN (?:RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----/gu,
  },
  {
    id: "bearer-token",
    pattern: /Bearer [A-Za-z0-9._-]{20,}/gu,
  },
];

function normalizePath(filePath) {
  return filePath.split(path.sep).join("/");
}

function classifyPath(relativePath) {
  return FORBIDDEN_PATH_PATTERNS
    .filter(({ pattern }) => pattern.test(relativePath))
    .map(({ id }) => ({ line: 1, rule: id }));
}

function classifyTrackedPath(relativePath) {
  return FORBIDDEN_TRACKED_PATH_PATTERNS
    .filter(({ pattern }) => pattern.test(relativePath))
    .map(({ id }) => ({ line: 1, rule: id }));
}

function lineNumberAt(text, index) {
  return text.slice(0, index).split("\n").length;
}

function scanText(text) {
  const findings = [];

  for (const { id, pattern } of FORBIDDEN_CONTENT_PATTERNS) {
    pattern.lastIndex = 0;

    for (const match of text.matchAll(pattern)) {
      findings.push({
        line: lineNumberAt(text, match.index ?? 0),
        rule: id,
      });
    }
  }

  return findings;
}

function collectFiles(directory, rootDirectory = directory) {
  const files = [];

  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (entry.isDirectory() && IGNORED_DIRECTORIES.has(entry.name)) {
      continue;
    }

    const absolutePath = path.join(directory, entry.name);

    if (entry.isDirectory()) {
      files.push(...collectFiles(absolutePath, rootDirectory));
      continue;
    }

    if (entry.isFile()) {
      files.push({
        absolutePath,
        relativePath: normalizePath(path.relative(rootDirectory, absolutePath)),
      });
    }
  }

  return files;
}

function collectTrackedPaths(rootDirectory) {
  const output = execFileSync(
    "git",
    ["ls-files", "-z"],
    {
      cwd: rootDirectory,
      encoding: "utf8",
    },
  );

  return output
    .split("\0")
    .filter(Boolean)
    .map(normalizePath)
    .filter((relativePath) => fs.existsSync(path.join(rootDirectory, relativePath)));
}

function scanRepository(rootDirectory) {
  const findings = [];

  for (const relativePath of collectTrackedPaths(rootDirectory)) {
    for (const finding of classifyTrackedPath(relativePath)) {
      findings.push({ file: relativePath, ...finding });
    }
  }

  for (const file of collectFiles(rootDirectory)) {
    for (const finding of classifyPath(file.relativePath)) {
      findings.push({ file: file.relativePath, ...finding });
    }

    if (CONTENT_SCAN_EXCLUSIONS.has(file.relativePath)) {
      continue;
    }

    const content = fs.readFileSync(file.absolutePath);

    if (content.includes(0)) {
      continue;
    }

    for (const finding of scanText(content.toString("utf8"))) {
      findings.push({ file: file.relativePath, ...finding });
    }
  }

  return findings;
}

if (require.main === module) {
  const rootDirectory = path.resolve(__dirname, "..");
  const findings = scanRepository(rootDirectory);

  if (findings.length > 0) {
    for (const finding of findings) {
      process.stderr.write(
        `${finding.file}:${finding.line} ${finding.rule}\n`,
      );
    }

    process.exitCode = 1;
  } else {
    process.stdout.write("Repository privacy check passed.\n");
  }
}

module.exports = {
  classifyPath,
  classifyTrackedPath,
  scanRepository,
  scanText,
};
