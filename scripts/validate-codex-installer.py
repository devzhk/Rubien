#!/usr/bin/env python3
"""Opt-in macOS validation of the current official native Codex updater.

Run after `swift test --filter ProviderMaintenanceTests` has built the test bundle.
Downloads real releases into a new build/ProviderUpdateValidation/live-codex-*
home. Never uses the account's Codex home, credentials, or installed CLI.
Evidence and disposable packages remain in the printed directory for inspection.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import tempfile
import time


REPOSITORY = Path(__file__).resolve().parent.parent


def run(command, environment, directory, log, timeout=240):
    with log.open("wb") as output:
        process = subprocess.Popen(command, env=environment, cwd=directory,
                                   stdin=subprocess.DEVNULL, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            status = process.wait(timeout=timeout)
        except BaseException:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise
    if status:
        raise RuntimeError(f"Command exited {status}: see {log}")


class Server:
    def __init__(self, binary, environment, directory, log):
        self.log = log.open("wb")
        self.process = subprocess.Popen([str(binary), "app-server"], env=environment,
                                        cwd=directory, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=self.log,
                                        start_new_session=True)
        self.buffer = b""

    def request(self, method, identifier, params):
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": identifier,
                                            "method": method, "params": params}).encode() + b"\n")
        self.process.stdin.flush()
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                message = json.loads(line)
                if message.get("id") == identifier:
                    if "result" not in message:
                        raise RuntimeError(f"RPC failed: {message}")
                    return message["result"]
            if select.select([self.process.stdout], [], [], 0.5)[0]:
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError(f"Server exited during {method}")
                self.buffer += chunk
        raise TimeoutError(f"RPC timed out: {method}")

    def close(self):
        try:
            os.killpg(self.process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.process.wait(timeout=10)
        self.process.stdin.close()
        self.process.stdout.close()
        self.log.close()


def hashes(directory):
    return {str(path.relative_to(directory)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in directory.rglob("*") if path.is_file()}


def main():
    if os.uname().sysname != "Darwin":
        raise SystemExit("This validates Rubien's macOS native updater only")
    base = REPOSITORY / "build/ProviderUpdateValidation"
    base.mkdir(parents=True, exist_ok=True)
    # Exercise lsof's escaped output. These characters have no decomposed form,
    # so Python and Foundation retain the same path bytes across installer runs.
    evidence = Path(tempfile.mkdtemp(prefix="live-codex-retention-測試-", dir=base))
    home = evidence / "home"
    home.mkdir()
    temporary = home / "tmp"
    temporary.mkdir()
    (home / ".retention-fixture").touch()
    environment = {"HOME": str(home), "TMPDIR": str(temporary),
                   "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/zsh",
                   "CODEX_NON_INTERACTIVE": "1", "LANG": "en_US.UTF-8", "TERM": "dumb"}
    script = evidence / "install.sh"
    print(f"Evidence: {evidence}", flush=True)
    run(["/usr/bin/curl", "--disable", "--fail", "--location", "--proto", "=https",
         "--proto-redir", "=https", "--max-time", "60", "--max-filesize", "2097152",
         "--dump-header", str(evidence / "headers.txt"), "--output", str(script),
         "https://chatgpt.com/codex/install.sh"], environment, home, evidence / "download.log")
    actual_hash = hashlib.sha256(script.read_bytes()).hexdigest()
    print(f"Official installer SHA-256 (diagnostic): {actual_hash}", flush=True)

    launcher = home / ".local/bin/codex"
    native_root = home / ".codex/packages/standalone"
    servers = []
    releases = []
    cwd_process = None
    try:
        for version in ("0.163.0", "0.164.0"):
            print(f"Installing disposable Codex {version}", flush=True)
            run(["/bin/sh", str(script), "--release", version], environment, home,
                evidence / f"install-{version}.log")
            release = launcher.resolve().parent.parent
            server = Server(launcher.resolve(), environment, home, evidence / f"server-{version}.log")
            servers.append(server)
            server.request("initialize", 1, {"clientInfo": {"name": "rubien-retention-test", "version": "1"},
                                              "capabilities": {}})
            releases.append((version, release, hashes(release)))

        # --release intentionally pins. Recreate the verified latest-channel marker
        # that an ordinary unpinned 0.164 installation has, before production planning.
        (native_root / "auto-update-version").write_text(releases[-1][1].name)
        driver_environment = dict(os.environ, RUBIEN_CODEX_UPDATE_LIVE_HOME=str(home))
        print("Running production native update with both old server generations alive", flush=True)
        run(["swift", "test", "--skip-build", "--filter",
             "ProviderUpdaterLiveTests/testNativeCodexProductionUpdate"], driver_environment,
            # Allow the production runner's 900-second mutation deadline and
            # termination/reaping to finish before killing the test driver.
            REPOSITORY, evidence / "production-test.log", timeout=1200)
        current = launcher.resolve().parent.parent
        selected = re.fullmatch(r"(\d+\.\d+\.\d+)-(?:aarch64|x86_64)-apple-darwin", current.name)
        if not selected or tuple(map(int, selected[1].split("."))) < (0, 166, 0):
            raise RuntimeError(f"Expected stable Codex 0.166.0 or newer, found {current}")
        installed_version = selected[1]
        history = (native_root / "selection-history").read_text().splitlines()
        if history[:2] != [current.name, releases[-1][1].name]:
            raise RuntimeError(f"Unexpected selection history: {history}")
        current_hashes = hashes(current)
        metadata = (current / "codex-package.json").read_text()
        if not re.search(r'"execServer"\s*:', metadata) or not os.access(current / "bin/codex-exec-server", os.X_OK):
            raise RuntimeError("Updated package did not install its executable exec-server helper")

        for server, (version, release, before) in zip(servers, releases):
            server.request("model/list", 2, {"limit": 100})
            if hashes(release) != before:
                raise RuntimeError(f"Codex {version} resources changed during update")
            run([str(release / "bin/codex"), "--version"], environment, home,
                evidence / f"retained-{version}.log")
            helpers = [path for path in release.rglob("rg") if os.access(path, os.X_OK)]
            if not helpers:
                raise RuntimeError(f"No bundled helper found in {release}")
            for index, helper in enumerate(helpers):
                run([str(helper), "--version"], environment, home, evidence / f"helper-{version}-{index}.log")

        # A cwd at the release root must also protect an otherwise unused tree.
        cwd_process = subprocess.Popen(["/bin/sleep", "600"], cwd=releases[0][1],
                                       env=environment, stdin=subprocess.DEVNULL,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for server in servers:
            server.close()
        servers.clear()
        print("Checking retention for a process whose cwd is the release root", flush=True)
        run(["/bin/sh", str(script)], environment, home, evidence / "cwd-retention.log")
        if hashes(releases[0][1]) != releases[0][2]:
            raise RuntimeError("Release resources changed while a process held its root as cwd")
        cwd_process.terminate()
        cwd_process.wait(timeout=10)
        cwd_process = None

        # Active 0.163 is older than 'previous', so its survival exercises the
        # process-inspection branch. After all uses exit, a no-op must retire it
        # while preserving the selected and previous releases and their history.
        print("Checking cleanup after old sessions exit", flush=True)
        run(["/bin/sh", str(script)], environment, home, evidence / "cleanup.log")
        if releases[0][1].exists():
            raise RuntimeError("Unused 0.163 release was not pruned; inspect cleanup.log for incomplete process visibility")
        if hashes(releases[1][1]) != releases[1][2]:
            raise RuntimeError("Previous release changed during cleanup")
        if launcher.resolve().parent.parent != current or hashes(current) != current_hashes:
            raise RuntimeError("Selected release changed during cleanup")
        run([str(launcher), "--version"], environment, home, evidence / "selected-after-cleanup.log")
        if (native_root / "selection-history").read_text().splitlines() != history:
            raise RuntimeError("No-op installer replaced selection history")
        result = {"scriptHash": actual_hash, "installedVersion": installed_version,
                  "retainedFiles": {version: len(before) for version, _, before in releases},
                  "twoServerGenerationsSurvived": True, "lateHelpersRunnable": True,
                  "nonASCIIHomeValidated": True, "releaseRootCwdRetained": True,
                  "execServerExecutable": True,
                  "unusedOldReleasePruned": True, "previousReleaseRetained": True,
                  "selectedReleaseRetained": True,
                  "latestPolicyPreserved": (native_root / "auto-update-version").read_text() == current.name}
        if not result["latestPolicyPreserved"]:
            raise RuntimeError("Latest-channel marker changed")
        (evidence / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2), flush=True)
    finally:
        if cwd_process is not None:
            cwd_process.terminate()
            cwd_process.wait(timeout=10)
        for server in servers:
            server.close()


if __name__ == "__main__":
    main()
