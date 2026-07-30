#!/usr/bin/env python3

import json
from pathlib import Path, PurePosixPath
import stat
import struct
import sys
import zipfile


ROOT_DIR = Path(__file__).resolve().parent.parent
PACKAGE_JSON = ROOT_DIR / "package.json"
HELPER_PATH = ROOT_DIR / "bin" / "prompt-accessibility-helper"
RELEASE_DIR = ROOT_DIR / "release"

PACKAGED_IMAGES = {
    "extension/docs/images/example-english.png": (
        ROOT_DIR / "docs/images/example-english.png"
    ),
    "extension/docs/images/example-english-complex.png": (
        ROOT_DIR / "docs/images/example-english-complex.png"
    ),
    "extension/docs/images/example-russian.png": (
        ROOT_DIR / "docs/images/example-russian.png"
    ),
    "extension/docs/images/example-russian-complex.png": (
        ROOT_DIR / "docs/images/example-russian-complex.png"
    ),
}

README_IMAGE_LINKS = (
    "docs/images/example-english.png",
    "docs/images/example-english-complex.png",
    "docs/images/example-russian.png",
    "docs/images/example-russian-complex.png",
)

REQUIRED_FILES = {
    "extension/package.json",
    "extension/dist/extension.js",
    "extension/bin/prompt-accessibility-helper",
    "extension/readme.md",
    *PACKAGED_IMAGES,
}

FORBIDDEN_PREFIXES = (
    "extension/.github/",
    "extension/.test-dist/",
    "extension/native/",
    "extension/release/",
    "extension/scripts/",
    "extension/src/",
    "extension/tests/",
)


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def package_version() -> str:
    package = json.loads(PACKAGE_JSON.read_text(encoding="utf8"))
    return str(package["version"])


def resolve_vsix_path(arguments: list[str]) -> Path:
    if len(arguments) > 1:
        fail("Usage: verify-package.py [path-to-vsix]")

    if arguments:
        path = Path(arguments[0]).resolve()
        if not path.is_file():
            fail(f"VSIX does not exist: {path}")
        return path

    pattern = f"codex-prompt-enhancer-{package_version()}-darwin-*.vsix"
    candidates = sorted(
        RELEASE_DIR.glob(pattern),
        key=lambda candidate: candidate.stat().st_mtime,
    )

    if not candidates:
        fail("No current-version VSIX package was found in release/.")

    return candidates[-1]


def is_forbidden(name: str) -> bool:
    lowered = name.lower()
    basename = PurePosixPath(name).name.lower()

    return (
        name.startswith(FORBIDDEN_PREFIXES)
        or "testcodexrunnercommand" in lowered
        or "probe" in basename
        or ".backup" in basename
        or basename.endswith((".bak", ".orig", "~"))
    )


def verify_manifest(data: bytes) -> None:
    manifest = json.loads(data.decode("utf8"))
    command_ids = {
        entry.get("command")
        for entry in manifest.get("contributes", {}).get("commands", [])
    }
    activation_events = set(manifest.get("activationEvents", []))

    if manifest.get("version") != package_version():
        fail("Packaged manifest version does not match package.json.")

    if "codexPromptEnhancer.testCodexRunner" in command_ids:
        fail("Development test command remains in the packaged manifest.")

    if "onCommand:codexPromptEnhancer.testCodexRunner" in activation_events:
        fail("Development test activation remains in the packaged manifest.")


def verify_readme(data: bytes) -> None:
    readme = data.decode("utf8")

    for image_link in README_IMAGE_LINKS:
        if f"]({image_link})" not in readme:
            fail(f"Packaged README does not use its bundled image: {image_link}")


def png_dimensions(data: bytes) -> tuple[int, int]:
    if data[:16] != b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR":
        fail("Packaged README image is not a valid PNG.")

    return struct.unpack(">II", data[16:24])


def verify_package(vsix_path: Path) -> None:
    if not HELPER_PATH.is_file():
        fail(f"Built helper does not exist: {HELPER_PATH}")

    with zipfile.ZipFile(vsix_path) as archive:
        entries = {info.filename: info for info in archive.infolist()}

        for name in entries:
            if ".." in PurePosixPath(name).parts:
                fail(f"Unsafe parent traversal entry in VSIX: {name}")

        missing = sorted(REQUIRED_FILES.difference(entries))
        if missing:
            fail("VSIX is missing required files: " + ", ".join(missing))

        forbidden = sorted(name for name in entries if is_forbidden(name))
        if forbidden:
            fail("VSIX contains forbidden files: " + ", ".join(forbidden))

        packaged_binaries = sorted(
            name
            for name in entries
            if name.startswith("extension/bin/") and not name.endswith("/")
        )
        expected_binaries = ["extension/bin/prompt-accessibility-helper"]
        if packaged_binaries != expected_binaries:
            fail("Unexpected packaged binaries: " + ", ".join(packaged_binaries))

        helper_info = entries["extension/bin/prompt-accessibility-helper"]
        unix_mode = (helper_info.external_attr >> 16) & 0o777
        executable_bits = stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
        if unix_mode != 0 and not unix_mode & executable_bits:
            fail(f"Native helper is not executable in VSIX: {oct(unix_mode)}")

        packaged_helper = archive.read(
            "extension/bin/prompt-accessibility-helper"
        )
        if packaged_helper != HELPER_PATH.read_bytes():
            fail("Packaged helper does not match the current built helper.")

        for archive_name, source_path in PACKAGED_IMAGES.items():
            if not source_path.is_file():
                fail(f"README image does not exist: {source_path}")

            packaged_image = archive.read(archive_name)
            if packaged_image != source_path.read_bytes():
                fail(f"Packaged README image is stale: {archive_name}")

            if png_dimensions(packaged_image) != (1376, 1040):
                fail(f"Packaged README image has wrong dimensions: {archive_name}")

        verify_manifest(archive.read("extension/package.json"))
        verify_readme(archive.read("extension/readme.md"))

    print(f"PASS: verified production VSIX: {vsix_path}")


if __name__ == "__main__":
    verify_package(resolve_vsix_path(sys.argv[1:]))
