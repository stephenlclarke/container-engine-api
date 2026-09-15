#!/usr/bin/env python3
##===----------------------------------------------------------------------===##
## Copyright 2026 container-engine-api project authors.
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
## https://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##===----------------------------------------------------------------------===##

"""Convert LCOV to Sonar generic XML and enforce a line-coverage floor."""

import argparse
import posixpath
import xml.etree.ElementTree as ET
from pathlib import Path

GENERATED_SOURCE_SUFFIXES = (".generated.swift", ".pb.swift", ".grpc.swift")


def is_generated_source(path: str) -> bool:
    """Match the generated Swift exclusions used by SonarQube."""
    return path.endswith(GENERATED_SOURCE_SUFFIXES)


def clean_relative_path(path: str) -> str | None:
    """Normalize and reject coverage paths that escape the project."""
    normalized = posixpath.normpath(path.replace("\\", "/"))
    if normalized in ("", ".", "..") or normalized.startswith("../") or normalized.startswith("/"):
        return None
    return normalized


def relative_path(path: str, root: Path) -> str | None:
    """Return a Sonar-friendly project-relative path."""
    source = path.strip().replace("\\", "/")
    root_prefix = root.as_posix().rstrip("/") + "/"
    if source.startswith(root_prefix):
        source = source[len(root_prefix) :]
    elif source.startswith("/"):
        return None
    return clean_relative_path(source)


def parse_lcov(path: Path, root: Path) -> dict[str, dict[int, bool]]:
    """Parse LCOV records into covered-line maps."""
    files: dict[str, dict[int, bool]] = {}
    current: str | None = None
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if line.startswith("SF:"):
            current = relative_path(line[3:], root)
            if current is not None and not is_generated_source(current):
                files.setdefault(current, {})
            else:
                current = None
        elif line.startswith("DA:") and current is not None:
            number, count, *_ = line[3:].split(",")
            files[current][int(number)] = int(count) > 0
        elif line == "end_of_record":
            current = None
    return files


def write_xml(files: dict[str, dict[int, bool]], output: Path) -> tuple[int, int]:
    """Write Sonar generic XML and return covered and total line counts."""
    covered = 0
    total = 0
    coverage = ET.Element("coverage", version="1")
    for file_path in sorted(files):
        file_element = ET.SubElement(coverage, "file", path=file_path)
        for number in sorted(files[file_path]):
            is_covered = files[file_path][number]
            covered += int(is_covered)
            total += 1
            ET.SubElement(
                file_element,
                "lineToCover",
                lineNumber=str(number),
                covered=str(is_covered).lower(),
            )
    tree = ET.ElementTree(coverage)
    ET.indent(tree, space="  ")
    tree.write(output, encoding="utf-8", xml_declaration=True)
    return covered, total


def percentage(covered: int, total: int) -> float:
    """Calculate line coverage, treating an empty report as uncovered."""
    return covered * 100.0 / total if total else 0.0


def main() -> int:
    """Convert the report and fail when it does not meet the requested floor."""
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--minimum", type=float, default=90.0)
    parser.add_argument("--root", type=Path, default=Path("."))
    args = parser.parse_args()

    root = args.root.resolve()
    input_path = args.input.resolve()
    output_path = args.output.resolve()
    input_path.relative_to(root)
    output_path.relative_to(root)
    covered, total = write_xml(parse_lcov(input_path, root), output_path)
    actual = percentage(covered, total)
    print(f"Swift line coverage: {actual:.2f}% ({covered}/{total})")
    if actual + 1e-9 < args.minimum:
        print(f"Swift line coverage is below required {args.minimum:.2f}%")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
