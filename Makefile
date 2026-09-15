#===----------------------------------------------------------------------===#
# Copyright 2026 container-engine-api project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#===----------------------------------------------------------------------===#

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

SWIFT ?= swift
PYTHON ?= python3
COVERAGE_MIN ?= 90
SONAR_QUALITYGATE_WAIT ?= true
SWIFT_LLVM_COV ?= $(shell xcrun --find llvm-cov 2>/dev/null || command -v llvm-cov 2>/dev/null || true)
SWIFT_LLVM_PROFDATA ?= $(shell xcrun --find llvm-profdata 2>/dev/null || command -v llvm-profdata 2>/dev/null || true)

.PHONY: test coverage coverage-tools-test sonar-scan clean

test:
	$(SWIFT) test --disable-automatic-resolution

coverage-tools-test:
	$(PYTHON) -m unittest discover Tools/coverage

coverage: coverage-tools-test
	@test -n "$(SWIFT_LLVM_COV)" || { printf 'llvm-cov is required\n' >&2; exit 2; }
	@test -n "$(SWIFT_LLVM_PROFDATA)" || { printf 'llvm-profdata is required\n' >&2; exit 2; }
	@rm -f .build/*/debug/codecov/*.profraw .build/codecov/container-engine-api.profdata coverage.lcov coverage.xml
	$(SWIFT) build --disable-automatic-resolution --build-tests --enable-code-coverage
	test_bin_path="$$(swift build --disable-automatic-resolution --show-bin-path)"; \
	test_binary="$$test_bin_path/container-engine-apiPackageTests.xctest/Contents/MacOS/container-engine-apiPackageTests"; \
	Tools/ci/run-swift-testing-bundle.sh "$$test_binary" --no-parallel; \
	mkdir -p .build/codecov; \
	find .build -name '*.profraw' -type f -print0 | xargs -0 "$(SWIFT_LLVM_PROFDATA)" merge -sparse -o .build/codecov/container-engine-api.profdata; \
	"$(SWIFT_LLVM_COV)" export -format=lcov -instr-profile=.build/codecov/container-engine-api.profdata "$$test_binary" --sources Sources > coverage.lcov
	$(PYTHON) Tools/coverage/coverage.py coverage.lcov coverage.xml --minimum "$(COVERAGE_MIN)"

sonar-scan:
	@test -s coverage.xml || { printf 'coverage.xml is missing; run make coverage first\n' >&2; exit 2; }
	@sonar_project_version="$${SONAR_PROJECT_VERSION:-$$(git rev-parse HEAD)}"; \
	printf '%s\n' "$$sonar_project_version" | grep -Eq '^[0-9a-f]{40}$$' || { printf 'SONAR_PROJECT_VERSION must be an exact lowercase commit SHA\n' >&2; exit 2; }; \
	sonar-scanner -Dsonar.projectVersion="$$sonar_project_version" -Dsonar.qualitygate.wait="$(SONAR_QUALITYGATE_WAIT)"

clean:
	rm -f coverage.lcov coverage.xml
	rm -rf .scannerwork
