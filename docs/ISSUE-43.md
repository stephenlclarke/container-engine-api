# Issue 43: import authoritative Swift coverage into SonarQube

## Problem

The SonarQube analysis runs without test coverage, an exact commit version, pull-request analysis, or a waited quality gate. The dashboard consequently reports 0% coverage and cannot enforce the Container-family previous-version policy. It also reports SHA-1 use in the RFC 6455 WebSocket handshake as a security vulnerability even though that protocol-required digest is not used to protect credentials or data.

## Acceptance criteria

- Generate and import Swift line coverage from the real package tests.
- Verify the project-level `Previous version` policy before every scan.
- Analyze pull requests and `main` at the exact lowercase 40-character Git SHA and wait for the gate.
- Require zero unresolved new issues and zero security hotspots.
- Narrowly document the RFC 6455 SHA-1 protocol exception without suppressing other cryptographic findings.
- Retain coverage evidence and keep CI green.

GitHub issue: [#43](https://github.com/stephenlclarke/container-engine-api/issues/43)
