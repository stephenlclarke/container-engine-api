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

"""Tests for the Swift-to-Sonar coverage conversion."""

import importlib.util
import tempfile
import unittest
from pathlib import Path


def load_module():
    """Load the CLI module from its filesystem path."""
    path = Path(__file__).with_name("coverage.py")
    spec = importlib.util.spec_from_file_location("container_engine_coverage", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


coverage = load_module()


class CoverageTests(unittest.TestCase):
    """Validate path confinement and line accounting."""

    def test_parse_lcov_keeps_only_project_sources(self) -> None:
        """Absolute records outside the checkout are omitted."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = root / "coverage.lcov"
            report.write_text(
                f"SF:{root}/Sources/API.swift\nDA:1,1\nDA:2,0\nend_of_record\n"
                "SF:/private/outside/Secret.swift\nDA:1,1\nend_of_record\n",
                encoding="utf-8",
            )
            self.assertEqual(
                coverage.parse_lcov(report, root),
                {"Sources/API.swift": {1: True, 2: False}},
            )

    def test_write_xml_reports_line_totals(self) -> None:
        """The generic report and threshold use the same line totals."""
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "coverage.xml"
            counts = coverage.write_xml({"Sources/API.swift": {1: True, 2: False}}, output)
            self.assertEqual(counts, (1, 2))
            self.assertIn('lineNumber="2" covered="false"', output.read_text(encoding="utf-8"))

    def test_empty_report_is_zero_percent(self) -> None:
        """An empty report cannot pass as complete coverage."""
        self.assertEqual(coverage.percentage(0, 0), 0.0)

    def test_direct_test_bundle_writes_profiles_to_merge_directory(self) -> None:
        """The direct runner and profile merge must share one explicit path."""
        makefile = Path(__file__).parents[2] / "Makefile"
        source = makefile.read_text(encoding="utf-8")
        self.assertIn('LLVM_PROFILE_FILE=".build/codecov/%p-%m.profraw"', source)
        self.assertIn("find .build/codecov -name '*.profraw'", source)

    def test_coverage_includes_service_executable(self) -> None:
        """Untested executable entry-point lines remain in the denominator."""
        makefile = Path(__file__).parents[2] / "Makefile"
        source = makefile.read_text(encoding="utf-8")
        self.assertIn('service_binary="$$test_bin_path/container-engine"', source)
        self.assertIn('-object "$$service_binary" --sources Sources', source)


if __name__ == "__main__":
    unittest.main()
