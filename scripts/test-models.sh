#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p .build/model-checks
swiftc Sources/CodexSentinel/Models.swift Tests/ModelChecks.swift -o .build/model-checks/ModelChecks
.build/model-checks/ModelChecks
swiftc Sources/CodexSentinel/Models.swift Sources/CodexSentinel/AppServerClient.swift Sources/CodexSentinel/DesktopIPCClient.swift Tests/AppServerChecks.swift -o .build/model-checks/AppServerChecks
.build/model-checks/AppServerChecks "$ROOT/Tests/Fixtures/fake-codex.sh"

swiftc Sources/CodexSentinel/Models.swift Tests/RetryChecks.swift -o .build/model-checks/RetryChecks
.build/model-checks/RetryChecks
swiftc Sources/CodexSentinel/Models.swift Sources/CodexSentinel/AppServerClient.swift Sources/CodexSentinel/DesktopIPCClient.swift Tests/ResumeRoutingChecks.swift -o .build/model-checks/ResumeRoutingChecks
.build/model-checks/ResumeRoutingChecks "$ROOT/Tests/Fixtures/fake-owned-codex.sh"
swiftc Sources/CodexSentinel/Models.swift Sources/CodexSentinel/AppServerClient.swift Sources/CodexSentinel/DesktopIPCClient.swift Tests/DesktopIPCChecks.swift -o .build/model-checks/DesktopIPCChecks
python3 Tests/Fixtures/check-desktop-ipc.py .build/model-checks/DesktopIPCChecks
swiftc Sources/CodexSentinel/Models.swift Sources/CodexSentinel/AppServerClient.swift Sources/CodexSentinel/DesktopIPCClient.swift Tests/FragmentedChecks.swift -o .build/model-checks/FragmentedChecks
.build/model-checks/FragmentedChecks "$ROOT/Tests/Fixtures/fake-fragmented-codex.py"
swiftc Sources/CodexSentinel/Models.swift Sources/CodexSentinel/AppServerClient.swift Sources/CodexSentinel/DesktopIPCClient.swift Tests/WriterReleaseChecks.swift -o .build/model-checks/WriterReleaseChecks
python3 Tests/Fixtures/check-cooperative-pool.py .build/model-checks/WriterReleaseChecks "$ROOT/Tests/Fixtures/fake-writer-codex.py"
