#!/usr/bin/env python3
"""Metadata helpers for Kira's pinned LLVM toolchain release workflow."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

try:
    import tomllib  # type: ignore[attr-defined]
except ModuleNotFoundError:
    tomllib = None

ARCHIVE_EXTENSIONS = {
    "zip": ".zip",
    "tar.xz": ".tar.xz",
}

VALID_PLATFORMS = {"windows", "linux", "macos"}


def fail(message: str) -> "NoReturn":
    raise SystemExit(message)


def load_metadata(path: Path) -> dict:
    data = load_toml(path)

    if data.get("schema_version") != 1:
        fail("llvm-metadata.toml must set schema_version = 1")

    llvm = data.get("llvm")
    if not isinstance(llvm, dict):
        fail("llvm-metadata.toml is missing the [llvm] table")

    build = data.get("build")
    if not isinstance(build, dict):
        fail("llvm-metadata.toml is missing the [build] table")

    version = require_string(llvm, "version", "[llvm]")
    source_tag = require_string(llvm, "source_tag", "[llvm]")
    release_tag = require_string(llvm, "release_tag", "[llvm]")
    build_type = require_string(build, "build_type", "[build]")
    generator = require_string(build, "cmake_generator", "[build]")
    targets_to_build = require_string(build, "targets_to_build", "[build]")

    if build_type != "Release":
        fail("Only Release LLVM toolchain bundles are supported in the first workflow version")

    if generator != "Ninja":
        fail("The workflow expects [build].cmake_generator = \"Ninja\"")

    if targets_to_build not in {"host", "Host", "HOST"}:
        fail("The workflow currently supports [build].targets_to_build = \"host\"")

    expected_tag_prefix = f"llvm-v{version}-kira."
    if not release_tag.startswith(expected_tag_prefix):
        fail(
            f"[llvm].release_tag must start with {expected_tag_prefix!r}; got {release_tag!r}"
        )

    targets = data.get("target")
    if not isinstance(targets, dict) or not targets:
        fail("llvm-metadata.toml must declare at least one [target.*] table")

    seen_assets: set[str] = set()
    normalized_targets: dict[str, dict] = {}
    for target_key, target_data in sorted(targets.items()):
        if not isinstance(target_data, dict):
            fail(f"[target.{target_key}] must be a TOML table")

        runner = require_string(target_data, "runner", f"[target.{target_key}]")
        platform = require_string(target_data, "platform", f"[target.{target_key}]")
        archive = require_string(target_data, "archive", f"[target.{target_key}]")
        asset = require_string(target_data, "asset", f"[target.{target_key}]")
        if platform not in VALID_PLATFORMS:
            fail(
                f"[target.{target_key}].platform must be one of {sorted(VALID_PLATFORMS)}"
            )

        extension = ARCHIVE_EXTENSIONS.get(archive)
        if extension is None:
            fail(
                f"[target.{target_key}].archive must be one of {sorted(ARCHIVE_EXTENSIONS)}"
            )

        expected_asset = f"llvm-{version}-{target_key}{extension}"
        if asset != expected_asset:
            fail(
                f"[target.{target_key}].asset must be {expected_asset!r}; got {asset!r}"
            )

        if asset in seen_assets:
            fail(f"Duplicate asset name found in llvm-metadata.toml: {asset}")
        seen_assets.add(asset)

        normalized_targets[target_key] = {
            "target_key": target_key,
            "runner": runner,
            "platform": platform,
            "archive": archive,
            "asset": asset,
        }

    return {
        "schema_version": data["schema_version"],
        "llvm": {
            "version": version,
            "source_tag": source_tag,
            "release_tag": release_tag,
        },
        "build": {
            "build_type": build_type,
            "cmake_generator": generator,
            "targets_to_build": targets_to_build.lower(),
        },
        "targets": normalized_targets,
    }


def load_toml(path: Path) -> dict:
    if tomllib is not None:
        with path.open("rb") as handle:
            return tomllib.load(handle)

    # Python 3.10 does not ship tomllib. This fallback intentionally supports
    # only the subset of TOML used by llvm-metadata.toml: tables plus string
    # and integer values.
    root: dict = {}
    current = root
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue

        line = strip_inline_comment(line)
        if not line:
            continue

        if line.startswith("[") and line.endswith("]"):
            table_path = line[1:-1].strip()
            if not table_path:
                fail(f"Empty TOML table header on line {line_number}")

            current = root
            for part in table_path.split("."):
                current = current.setdefault(part, {})
                if not isinstance(current, dict):
                    fail(f"Invalid TOML table nesting on line {line_number}")
            continue

        if "=" not in line:
            fail(f"Expected key/value pair on line {line_number}")

        key, raw_value = line.split("=", 1)
        key = key.strip()
        value = parse_toml_value(raw_value.strip(), line_number)
        current[key] = value

    return root


def strip_inline_comment(line: str) -> str:
    in_string = False
    escaped = False
    for index, char in enumerate(line):
        if escaped:
            escaped = False
            continue
        if char == "\\" and in_string:
            escaped = True
            continue
        if char == '"':
            in_string = not in_string
            continue
        if char == "#" and not in_string:
            return line[:index].rstrip()
    return line


def parse_toml_value(raw_value: str, line_number: int) -> object:
    if raw_value.startswith('"') and raw_value.endswith('"'):
        return raw_value[1:-1]

    try:
        return int(raw_value)
    except ValueError as exc:
        fail(f"Unsupported TOML value {raw_value!r} on line {line_number}: {exc}")


def require_string(table: dict, key: str, table_name: str) -> str:
    value = table.get(key)
    if not isinstance(value, str):
        fail(f"{table_name}.{key} must be a string")
    return value


def build_matrix(metadata: dict) -> dict:
    include = []
    for target_key, target in metadata["targets"].items():
        include.append(
            {
                "target_key": target_key,
                "runner": target["runner"],
                "platform": target["platform"],
                "archive": target["archive"],
                "asset": target["asset"],
            }
        )
    return {"include": include}


def compute_publish_mode(event_name: str, ref_name: str, publish_input: str) -> bool:
    is_release_tag = event_name == "push" and ref_name.startswith("llvm-v")
    publish = is_release_tag or publish_input.lower() == "true"
    return publish


def write_github_output(path: Path, key: str, value: str) -> None:
    with path.open("a", encoding="utf-8", newline="\n") as handle:
        handle.write(f"{key}<<__KIRA_LLVM__\n{value}\n__KIRA_LLVM__\n")


def cmd_validate(args: argparse.Namespace) -> int:
    metadata = load_metadata(Path(args.metadata))
    if args.ref_name:
        expected = metadata["llvm"]["release_tag"]
        if args.ref_name != expected:
            fail(
                f"Git tag {args.ref_name!r} does not match llvm-metadata.toml release tag {expected!r}"
            )

    print(
        f"Validated llvm-metadata.toml for LLVM {metadata['llvm']['version']} "
        f"with {len(metadata['targets'])} target(s)."
    )
    return 0


def cmd_matrix(args: argparse.Namespace) -> int:
    metadata = load_metadata(Path(args.metadata))
    print(json.dumps(build_matrix(metadata), separators=(",", ":")))
    return 0


def cmd_github_outputs(args: argparse.Namespace) -> int:
    metadata = load_metadata(Path(args.metadata))
    if args.ref_name and args.event_name == "push":
        expected = metadata["llvm"]["release_tag"]
        if args.ref_name != expected:
            fail(
                f"Git tag {args.ref_name!r} does not match llvm-metadata.toml release tag {expected!r}"
            )

    publish = compute_publish_mode(
        args.event_name,
        args.ref_name,
        args.publish_input,
    )

    output_path = Path(args.output)
    write_github_output(output_path, "matrix", json.dumps(build_matrix(metadata), separators=(",", ":")))
    write_github_output(output_path, "llvm_version", metadata["llvm"]["version"])
    write_github_output(output_path, "llvm_source_tag", metadata["llvm"]["source_tag"])
    write_github_output(output_path, "release_tag", metadata["llvm"]["release_tag"])
    write_github_output(output_path, "build_type", metadata["build"]["build_type"])
    write_github_output(output_path, "cmake_generator", metadata["build"]["cmake_generator"])
    write_github_output(output_path, "targets_to_build", metadata["build"]["targets_to_build"])
    write_github_output(output_path, "publish", "true" if publish else "false")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate = subparsers.add_parser("validate", help="Validate llvm-metadata.toml")
    validate.add_argument("--metadata", required=True)
    validate.add_argument("--ref-name", default="")
    validate.set_defaults(func=cmd_validate)

    matrix = subparsers.add_parser("matrix", help="Emit the GitHub Actions build matrix")
    matrix.add_argument("--metadata", required=True)
    matrix.set_defaults(func=cmd_matrix)

    outputs = subparsers.add_parser(
        "github-outputs",
        help="Validate metadata and emit reusable GitHub Actions outputs",
    )
    outputs.add_argument("--metadata", required=True)
    outputs.add_argument("--output", required=True)
    outputs.add_argument("--event-name", default="")
    outputs.add_argument("--ref-name", default="")
    outputs.add_argument("--publish-input", default="false")
    outputs.set_defaults(func=cmd_github_outputs)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
