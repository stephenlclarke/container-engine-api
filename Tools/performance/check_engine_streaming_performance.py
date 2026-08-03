#!/usr/bin/env python3
##===----------------------------------------------------------------------===##
## Copyright 2026 container-engine-api project authors.
## Licensed under the Apache License, Version 2.0.
##===----------------------------------------------------------------------===##

"""Compare shared Engine streaming transport with Docker on the same Mac."""

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import signal
import socket
import statistics
import struct
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote
import uuid
import xml.etree.ElementTree as ET


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_EVIDENCE_DIRECTORY = REPO_ROOT / ".build/performance/engine-streaming"
FIXTURE_IMAGE = "alpine:3.20"
FIXTURES = (
    ("resize", 0),
    ("websocket-roundtrip-32b", 32),
    ("websocket-roundtrip-1mib", 1024 * 1024),
)


class PerformanceFailure(RuntimeError):
    """Raised when a benchmark prerequisite or operation fails."""


@dataclass(frozen=True)
class Lane:
    name: str
    socket_path: str
    container_id: str


@dataclass(frozen=True)
class Sample:
    fixture: str
    lane: str
    repetition: int
    duration_seconds: float
    outcome: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--candidate-binary",
        type=Path,
        help="prebuilt ContainerEngineStreamingPerformanceFixture binary",
    )
    parser.add_argument(
        "--docker-socket",
        help="Docker Unix socket; defaults to the active Docker context",
    )
    parser.add_argument(
        "--evidence-dir",
        type=Path,
        default=DEFAULT_EVIDENCE_DIRECTORY,
    )
    parser.add_argument("--repetitions", type=int, default=11)
    parser.add_argument("--timeout-seconds", type=float, default=15.0)
    parser.add_argument("--max-ratio", type=float, default=10.0)
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run deterministic helper checks without Docker",
    )
    return parser.parse_args()


def run_checked(
    command: list[str],
    *,
    timeout: float = 300.0,
    cwd: Path = REPO_ROOT,
) -> str:
    completed = subprocess.run(
        command,
        cwd=cwd,
        check=False,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise PerformanceFailure(
            f"{command[0]} exited {completed.returncode}: {detail}"
        )
    return completed.stdout.strip()


def active_docker_socket(explicit: str | None) -> str:
    if explicit:
        path = explicit.removeprefix("unix://")
    else:
        endpoint = run_checked(
            [
                "docker",
                "context",
                "inspect",
                "--format",
                "{{.Endpoints.docker.Host}}",
            ]
        )
        if not endpoint.startswith("unix://"):
            raise PerformanceFailure(
                f"active Docker endpoint is not a Unix socket: {endpoint}"
            )
        path = endpoint.removeprefix("unix://")
    if not Path(path).is_socket():
        raise PerformanceFailure(f"Docker Unix socket does not exist: {path}")
    return path


def release_fixture_binary(explicit: Path | None) -> Path:
    if explicit:
        binary = explicit.resolve()
    else:
        run_checked(
            [
                "swift",
                "run",
                "--configuration",
                "release",
                "--disable-automatic-resolution",
                "ContainerEngineStreamingPerformanceFixture",
                "--help",
            ],
            timeout=900.0,
        )
        binary_directory = Path(
            run_checked(
                [
                    "swift",
                    "build",
                    "--configuration",
                    "release",
                    "--disable-automatic-resolution",
                    "--show-bin-path",
                ]
            )
        )
        binary = binary_directory / "ContainerEngineStreamingPerformanceFixture"
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise PerformanceFailure(f"candidate fixture is not executable: {binary}")
    return binary


def wait_for_socket(path: Path, process: subprocess.Popen[bytes], timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise PerformanceFailure(
                f"candidate fixture exited before readiness with {process.returncode}"
            )
        if path.is_socket():
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                    connection.settimeout(0.2)
                    connection.connect(str(path))
                return
            except OSError:
                pass
        time.sleep(0.01)
    raise PerformanceFailure(f"candidate fixture did not create {path}")


def read_exact(connection: socket.socket, count: int) -> bytes:
    chunks: list[bytes] = []
    remaining = count
    while remaining:
        chunk = connection.recv(remaining)
        if not chunk:
            raise PerformanceFailure("socket closed before the expected payload")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_until(connection: socket.socket, marker: bytes, maximum: int) -> bytes:
    value = bytearray()
    while marker not in value:
        chunk = connection.recv(4096)
        if not chunk:
            raise PerformanceFailure("socket closed before the expected delimiter")
        value.extend(chunk)
        if len(value) > maximum:
            raise PerformanceFailure("response exceeded its bounded header size")
    return bytes(value)


def masked_frame(opcode: int, payload: bytes) -> bytes:
    mask = b"\x12\x34\x56\x78"
    length = len(payload)
    if length <= 125:
        header = bytes((0x80 | opcode, 0x80 | length))
    elif length <= 0xFFFF:
        header = bytes((0x80 | opcode, 0x80 | 126)) + struct.pack("!H", length)
    else:
        header = bytes((0x80 | opcode, 0x80 | 127)) + struct.pack("!Q", length)
    masked = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    return header + mask + masked


def read_websocket_payload(connection: socket.socket, expected_count: int) -> bytes:
    result = bytearray()
    while len(result) < expected_count:
        first, second = read_exact(connection, 2)
        opcode = first & 0x0F
        masked = second & 0x80 != 0
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", read_exact(connection, 2))[0]
        elif length == 127:
            length = struct.unpack("!Q", read_exact(connection, 8))[0]
        mask = read_exact(connection, 4) if masked else b""
        payload = read_exact(connection, length)
        if masked:
            payload = bytes(
                value ^ mask[index % 4] for index, value in enumerate(payload)
            )
        if opcode in (0x0, 0x1, 0x2):
            result.extend(payload)
        elif opcode == 0x8:
            raise PerformanceFailure("server closed the WebSocket before echoing input")
        elif opcode == 0x9:
            connection.sendall(masked_frame(0xA, payload))
        elif opcode != 0xA:
            raise PerformanceFailure(f"unexpected WebSocket opcode {opcode}")
        if len(result) > expected_count:
            raise PerformanceFailure("WebSocket returned more bytes than requested")
    return bytes(result)


def resize_once(lane: Lane, timeout: float) -> None:
    target = (
        f"/v1.53/containers/{quote(lane.container_id, safe='')}/resize?h=48&w=132"
    )
    request = (
        f"POST {target} HTTP/1.1\r\n"
        "Host: localhost\r\n"
        "Content-Length: 0\r\n"
        "Connection: close\r\n\r\n"
    ).encode()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(timeout)
        connection.connect(lane.socket_path)
        connection.sendall(request)
        response = read_until(connection, b"\r\n\r\n", 64 * 1024)
    first_line = response.split(b"\r\n", 1)[0]
    if b" 200 " not in first_line:
        raise PerformanceFailure(
            f"{lane.name} resize returned {first_line.decode(errors='replace')}"
        )


def websocket_roundtrip_once(
    lane: Lane,
    payload: bytes,
    timeout: float,
    *,
    request_frame: bytes | None = None,
) -> None:
    target = (
        f"/v1.53/containers/{quote(lane.container_id, safe='')}/attach/ws"
        "?stream=1&stdin=1&stdout=1&stderr=1"
    )
    request = (
        f"GET {target} HTTP/1.1\r\n"
        "Host: localhost\r\n"
        "Connection: Upgrade\r\n"
        "Upgrade: websocket\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
    ).encode()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(timeout)
        connection.connect(lane.socket_path)
        connection.sendall(request)
        response = read_until(connection, b"\r\n\r\n", 64 * 1024)
        first_line = response.split(b"\r\n", 1)[0]
        if b" 101 " not in first_line:
            raise PerformanceFailure(
                f"{lane.name} WebSocket returned "
                f"{first_line.decode(errors='replace')}"
            )
        connection.sendall(request_frame or masked_frame(0x2, payload))
        echoed = read_websocket_payload(connection, len(payload))
        if echoed != payload:
            raise PerformanceFailure(f"{lane.name} WebSocket changed echo bytes")
        connection.sendall(masked_frame(0x8, b"\x03\xe8"))


def payload_for(count: int) -> bytes:
    return bytes(0x41 + index % 26 for index in range(count))


def run_sample(
    fixture: str,
    payload_size: int,
    lane: Lane,
    repetition: int,
    timeout: float,
) -> Sample:
    payload = payload_for(payload_size)
    request_frame = masked_frame(0x2, payload) if payload else None
    started = time.monotonic()
    outcome = "success"
    try:
        if fixture == "resize":
            resize_once(lane, timeout)
        else:
            websocket_roundtrip_once(
                lane,
                payload,
                timeout,
                request_frame=request_frame,
            )
    except socket.timeout:
        outcome = "timeout"
    except Exception as error:  # Preserve the bounded failure class in evidence.
        outcome = f"error:{type(error).__name__}"
    duration = time.monotonic() - started
    return Sample(fixture, lane.name, repetition, duration, outcome)


def percentile_95(values: list[float]) -> float:
    return sorted(values)[math.ceil(len(values) * 0.95) - 1]


def direction_assessment(reference: float, candidate: float) -> str:
    noise = max(reference * 0.10, 0.0005)
    difference = candidate - reference
    if difference < -noise:
        return "better"
    if abs(difference) <= noise:
        return "comparable"
    return "slower"


def write_evidence(
    directory: Path,
    samples: list[Sample],
    fingerprints: dict[str, object],
    repetitions: int,
    maximum_ratio: float,
) -> list[str]:
    directory.mkdir(parents=True, exist_ok=True)
    timing_path = directory / "timings.tsv"
    with timing_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
        writer.writerow(
            ("fixture", "lane", "repetition", "duration_seconds", "outcome")
        )
        for sample in samples:
            writer.writerow(
                (
                    sample.fixture,
                    sample.lane,
                    sample.repetition,
                    f"{sample.duration_seconds:.9f}",
                    sample.outcome,
                )
            )
    (directory / "fingerprints.json").write_text(
        json.dumps(fingerprints, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    grouped: dict[str, dict[str, list[Sample]]] = {}
    for sample in samples:
        grouped.setdefault(sample.fixture, {}).setdefault(sample.lane, []).append(
            sample
        )
    failures: list[str] = []
    summary: dict[str, object] = {
        "comparisonMethod": (
            "lower-is-better median/P95; fail on timeout, incomplete lane, or "
            f"candidate median >= {maximum_ratio:g}x Docker"
        ),
        "fixtures": {},
        "schemaVersion": 1,
    }
    suite = ET.Element(
        "testsuite",
        name="container-engine-streaming-performance",
        tests=str(len(FIXTURES)),
    )
    matrix_rows: list[tuple[str, ...]] = []
    for fixture, _ in FIXTURES:
        lanes = grouped.get(fixture, {})
        docker = lanes.get("docker", [])
        candidate = lanes.get("container-engine", [])
        testcase = ET.SubElement(
            suite,
            "testcase",
            classname="performance.engine-streaming",
            name=fixture,
        )
        all_samples = docker + candidate
        ET.SubElement(testcase, "system-out").text = "\n".join(
            f"{sample.lane} repetition={sample.repetition} "
            f"duration={sample.duration_seconds:.9f} outcome={sample.outcome}"
            for sample in all_samples
        )
        reason: str | None = None
        if len(docker) != repetitions or len(candidate) != repetitions:
            reason = "fixture is missing required repetitions in one or both lanes"
        elif any(sample.outcome != "success" for sample in all_samples):
            reason = "fixture did not complete successfully in both lanes"
        if reason:
            failures.append(f"{fixture}: {reason}")
            ET.SubElement(testcase, "failure", message=reason).text = reason
            matrix_rows.append((fixture, "n/a", "n/a", "n/a", "n/a", "n/a", "n/a", "FAIL"))
            continue

        docker_values = [sample.duration_seconds for sample in docker]
        candidate_values = [sample.duration_seconds for sample in candidate]
        docker_median = statistics.median(docker_values)
        candidate_median = statistics.median(candidate_values)
        ratio = candidate_median / docker_median
        assessment = direction_assessment(docker_median, candidate_median)
        result = "PASS"
        if ratio >= maximum_ratio:
            reason = (
                f"candidate median is {ratio:.2f}x Docker; threshold is "
                f"<{maximum_ratio:g}x"
            )
            failures.append(f"{fixture}: {reason}")
            ET.SubElement(testcase, "failure", message=reason).text = reason
            result = "FAIL"
        testcase.set("time", f"{candidate_median:.9f}")
        fixture_summary = {
            "candidateMedianSeconds": candidate_median,
            "candidateP95Seconds": percentile_95(candidate_values),
            "candidateToDockerMedianRatio": ratio,
            "directionAssessment": assessment,
            "dockerMedianSeconds": docker_median,
            "dockerP95Seconds": percentile_95(docker_values),
            "regressionGate": result.lower(),
        }
        summary["fixtures"][fixture] = fixture_summary  # type: ignore[index]
        matrix_rows.append(
            (
                fixture,
                f"{docker_median:.6f}",
                f"{percentile_95(docker_values):.6f}",
                f"{candidate_median:.6f}",
                f"{percentile_95(candidate_values):.6f}",
                f"{ratio:.2f}x",
                assessment,
                result,
            )
        )

    suite.set("failures", str(len(failures)))
    ET.ElementTree(suite).write(
        directory / "timings.junit.xml",
        encoding="utf-8",
        xml_declaration=True,
    )
    (directory / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    lines = [
        "# Shared Engine Streaming Performance",
        "",
        (
            "Same-host release-build transport samples. This lane covers the public "
            "Unix listener, shared gateway, private provider session, logging controller, "
            "and a bounded in-memory backend. It does not replace production-runtime or "
            "logging-driver performance evidence."
        ),
        "",
        (
            "The executable regression rule is timeout, incomplete execution, or a "
            f"candidate median at least {maximum_ratio:g}x Docker. Direction assessment "
            "uses a lower-is-better 10%/0.5 ms noise band."
        ),
        "",
        "| Fixture | Docker median (s) | Docker P95 (s) | Engine median (s) | Engine P95 (s) | Candidate/reference | Direction | Gate |",
        "| --- | ---: | ---: | ---: | ---: | ---: | --- | --- |",
    ]
    lines.extend(f"| {' | '.join(row)} |" for row in matrix_rows)
    lines.extend(
        (
            "",
            "Raw samples are in `timings.tsv`; fingerprints are in `fingerprints.json`; machine comparison is in `summary.json`.",
            "",
        )
    )
    matrix = "\n".join(lines)
    (directory / "timing-matrix.md").write_text(matrix, encoding="utf-8")
    print(matrix)
    return failures


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def optional_command(command: list[str]) -> str | None:
    try:
        return run_checked(command, timeout=30.0)
    except (PerformanceFailure, FileNotFoundError, subprocess.TimeoutExpired):
        return None


def fingerprints(binary: Path, repetitions: int) -> dict[str, object]:
    diff = subprocess.run(
        ["git", "diff", "--binary", "HEAD"],
        cwd=REPO_ROOT,
        check=True,
        capture_output=True,
    ).stdout
    docker_version = run_checked(
        ["docker", "version", "--format", "{{json .Server}}"]
    )
    return {
        "candidate": {
            "binary": str(binary),
            "binarySHA256": sha256_file(binary),
            "gitHead": run_checked(["git", "rev-parse", "HEAD"]),
            "trackedDiffSHA256": hashlib.sha256(diff).hexdigest(),
            "worktreeDirty": bool(run_checked(["git", "status", "--porcelain"])),
        },
        "capturedAt": datetime.now(timezone.utc).isoformat(),
        "conditions": {
            "backend": "bounded in-memory echo/resize fixture",
            "build": "release",
            "image": FIXTURE_IMAGE,
            "repetitions": repetitions,
            "scope": "public-listener+gateway+private-provider+logging-controller",
        },
        "docker": {
            "context": run_checked(["docker", "context", "show"]),
            "engine": json.loads(docker_version),
        },
        "host": {
            "architecture": platform.machine(),
            "hardwareMemoryBytes": optional_command(["sysctl", "-n", "hw.memsize"]),
            "hardwareModel": optional_command(["sysctl", "-n", "hw.model"]),
            "macOSVersion": platform.mac_ver()[0],
        },
        "schemaVersion": 1,
    }


def prepare_docker_container(name: str, timeout: float) -> None:
    run_checked(
        [
            "docker",
            "run",
            "--detach",
            "--interactive",
            "--tty",
            "--name",
            name,
            "--pull",
            "missing",
            FIXTURE_IMAGE,
            "sh",
            "-c",
            "stty raw -echo; touch /tmp/engine-streaming-ready; exec cat",
        ],
        timeout=300.0,
    )
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        completed = subprocess.run(
            ["docker", "exec", name, "test", "-f", "/tmp/engine-streaming-ready"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if completed.returncode == 0:
            return
        time.sleep(0.02)
    raise PerformanceFailure("Docker echo container did not become ready")


def self_test() -> None:
    for size in (0, 32, 126, 65536):
        frame = masked_frame(0x2, payload_for(size))
        if not frame or frame[0] != 0x82 or frame[1] & 0x80 == 0:
            raise PerformanceFailure(f"invalid masked frame for payload size {size}")
    if percentile_95([1.0, 2.0, 3.0, 4.0]) != 4.0:
        raise PerformanceFailure("P95 helper is incorrect")
    if direction_assessment(0.010, 0.0104) != "comparable":
        raise PerformanceFailure("direction noise-band helper is incorrect")
    print("engine streaming performance helper checks passed")


def main() -> int:
    arguments = parse_args()
    if arguments.self_test:
        self_test()
        return 0
    if arguments.repetitions <= 0:
        raise PerformanceFailure("--repetitions must be positive")
    if arguments.timeout_seconds <= 0:
        raise PerformanceFailure("--timeout-seconds must be positive")
    if arguments.max_ratio <= 0:
        raise PerformanceFailure("--max-ratio must be positive")

    run_checked(["docker", "info"])
    docker_socket = active_docker_socket(arguments.docker_socket)
    candidate_binary = release_fixture_binary(arguments.candidate_binary)
    evidence_directory = arguments.evidence_dir.resolve()
    evidence_directory.mkdir(parents=True, exist_ok=True)
    container_name = f"cea-stream-perf-{uuid.uuid4().hex[:12]}"
    process: subprocess.Popen[bytes] | None = None
    samples: list[Sample] = []

    with tempfile.TemporaryDirectory(prefix="cea-stream-perf-") as temporary:
        temporary_path = Path(temporary)
        os.chmod(temporary_path, 0o700)
        public_socket = temporary_path / "docker.sock"
        provider_socket = temporary_path / "provider.sock"
        log_path = evidence_directory / "candidate-fixture.log"
        with log_path.open("wb") as log:
            try:
                prepare_docker_container(container_name, arguments.timeout_seconds)
                process = subprocess.Popen(
                    [
                        str(candidate_binary),
                        "--public-socket",
                        str(public_socket),
                        "--provider-socket",
                        str(provider_socket),
                    ],
                    cwd=REPO_ROOT,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
                wait_for_socket(public_socket, process, arguments.timeout_seconds)
                lanes = (
                    Lane("docker", docker_socket, container_name),
                    Lane("container-engine", str(public_socket), "fixture"),
                )
                for lane in lanes:
                    try:
                        resize_once(lane, arguments.timeout_seconds)
                        websocket_roundtrip_once(
                            lane,
                            payload_for(32),
                            arguments.timeout_seconds,
                        )
                    except Exception as error:
                        raise PerformanceFailure(
                            f"{lane.name} warm-up failed: {error}"
                        ) from error
                for repetition in range(1, arguments.repetitions + 1):
                    ordered_lanes = lanes if repetition % 2 else tuple(reversed(lanes))
                    for fixture, payload_size in FIXTURES:
                        for lane in ordered_lanes:
                            sample = run_sample(
                                fixture,
                                payload_size,
                                lane,
                                repetition,
                                arguments.timeout_seconds,
                            )
                            samples.append(sample)
                            print(
                                f"{fixture} {lane.name} repetition {repetition}: "
                                f"{sample.duration_seconds:.6f}s ({sample.outcome})"
                            )
            finally:
                if process is not None and process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=10.0)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=5.0)
                subprocess.run(
                    ["docker", "rm", "--force", container_name],
                    check=False,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=30.0,
                )

    failures = write_evidence(
        evidence_directory,
        samples,
        fingerprints(candidate_binary, arguments.repetitions),
        arguments.repetitions,
        arguments.max_ratio,
    )
    if failures:
        raise PerformanceFailure("; ".join(failures))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (PerformanceFailure, FileNotFoundError, subprocess.TimeoutExpired) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
