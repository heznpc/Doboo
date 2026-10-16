#!/usr/bin/env python3
"""Run connection cancellation regressions without a device, Keychain, or network."""
from pathlib import Path
import subprocess
import tempfile


def main():
    repo = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="doboo-connection-tests-") as temporary:
        executable = Path(temporary) / "connection-tests"
        command = ["swiftc", "-swift-version", "6", "-parse-as-library",
                   "Sources/Core/CharacterPack.swift", "Sources/Core/CompanionTask.swift",
                   "Sources/Core/TaskSubmission.swift", "Shared/TaskConnection.swift",
                   "ConnectionTests/TaskConnectionTests.swift", "-o", str(executable)]
        try:
            subprocess.run(command, cwd=repo, check=True, timeout=60)
            subprocess.run([str(executable)], cwd=repo, check=True, timeout=30)
        except subprocess.CalledProcessError as error:
            return error.returncode if error.returncode > 0 else 1
        except subprocess.TimeoutExpired:
            print("Connection regression test timed out.")
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
