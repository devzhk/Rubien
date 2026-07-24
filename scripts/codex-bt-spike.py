#!/usr/bin/env python3
"""Behavioral probe for Rubien's proposed Codex B-T runtime posture.

This script talks directly to real `codex app-server` processes over JSON-RPC.
It uses short sequential compatibility preflights, then exercises the posture
matrix on one main server. It keeps all Rubien writes inside a temporary
library and verifies the important boundary through the app-server's
thread-aware MCP APIs, rather than asking the model to comply with a prompt.

The probe intentionally does not change Rubien production code. It exercises:

* opposite per-thread MCP, Apps, plugins, web, and cwd configuration;
* distinct per-thread Rubien MCP children and tool catalogs;
* a denied read-only write with an unchanged isolated library;
* a successful write-capable control call;
* loaded-thread resume and immediate post-unsubscribe negative controls;
* a cold resume after app-server restart.

The fixed 30-minute same-process idle unload is not waited by default. The cold
restart control proves cold-resume override application, while the report keeps
the same-process idle-unload transition explicitly separate.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import queue
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any, Callable


class ProbeFailure(RuntimeError):
    pass


class RPCError(RuntimeError):
    def __init__(self, method: str, error: dict[str, Any]):
        self.method = method
        self.error = error
        super().__init__(
            f"{method} failed: {error.get('code', '?')} {error.get('message', 'unknown error')}"
        )


class JSONRPCClient:
    def __init__(
        self,
        command: list[str],
        cwd: Path,
        request_timeout: float,
        environment: dict[str, str] | None = None,
    ) -> None:
        self.request_timeout = request_timeout
        self.process = subprocess.Popen(
            command,
            cwd=cwd,
            env=environment,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        if self.process.stdin is None or self.process.stdout is None or self.process.stderr is None:
            raise ProbeFailure("failed to open app-server stdio")
        self._stdin = self.process.stdin
        self._stdout = self.process.stdout
        self._stderr = self.process.stderr
        self._write_lock = threading.Lock()
        self._state = threading.Condition()
        self._pending: dict[int, queue.Queue[dict[str, Any]]] = {}
        self._notifications: list[dict[str, Any]] = []
        self._next_id = 1
        self._closed = False
        self._stdout_thread = threading.Thread(target=self._read_stdout, daemon=True)
        self._stderr_thread = threading.Thread(target=self._read_stderr, daemon=True)
        self._stdout_thread.start()
        self._stderr_thread.start()

    @property
    def pid(self) -> int:
        return self.process.pid

    @property
    def notification_count(self) -> int:
        with self._state:
            return len(self._notifications)

    def _send(self, payload: dict[str, Any]) -> None:
        encoded = json.dumps(payload, separators=(",", ":"))
        with self._write_lock:
            if self.process.poll() is not None:
                raise ProbeFailure(
                    f"app-server exited with status {self.process.returncode}"
                )
            self._stdin.write(encoded + "\n")
            self._stdin.flush()

    def request(
        self,
        method: str,
        params: dict[str, Any] | None = None,
        timeout: float | None = None,
    ) -> dict[str, Any]:
        with self._state:
            request_id = self._next_id
            self._next_id += 1
            response_queue: queue.Queue[dict[str, Any]] = queue.Queue(maxsize=1)
            self._pending[request_id] = response_queue
        self._send(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "method": method,
                "params": params or {},
            }
        )
        try:
            response = response_queue.get(timeout=timeout or self.request_timeout)
        except queue.Empty as exc:
            with self._state:
                self._pending.pop(request_id, None)
            raise ProbeFailure(f"timed out waiting for {method}") from exc
        if "error" in response:
            raise RPCError(method, response["error"])
        result = response.get("result")
        return result if isinstance(result, dict) else {}

    def notify(self, method: str, params: dict[str, Any] | None = None) -> None:
        self._send(
            {
                "jsonrpc": "2.0",
                "method": method,
                "params": params or {},
            }
        )

    def wait_for_notification(
        self,
        start_index: int,
        predicate: Callable[[dict[str, Any]], bool],
        timeout: float,
    ) -> tuple[dict[str, Any], list[dict[str, Any]]]:
        deadline = time.monotonic() + timeout
        with self._state:
            while True:
                current = self._notifications[start_index:]
                for message in current:
                    if predicate(message):
                        return message, list(current)
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise ProbeFailure("timed out waiting for app-server notification")
                self._state.wait(timeout=min(remaining, 1.0))

    def _read_stdout(self) -> None:
        for raw_line in self._stdout:
            line = raw_line.strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(message, dict):
                continue
            if "id" in message and "method" not in message:
                with self._state:
                    response_queue = self._pending.pop(message["id"], None)
                if response_queue is not None:
                    response_queue.put(message)
                continue
            if "id" in message and "method" in message:
                self._decline_server_request(message)
                continue
            with self._state:
                self._notifications.append(message)
                self._state.notify_all()
        self._wake_pending_after_eof()

    def _decline_server_request(self, message: dict[str, Any]) -> None:
        method = str(message.get("method", ""))
        request_id = message.get("id")
        if "requestApproval" in method:
            result: dict[str, Any] = {"decision": "decline"}
            payload = {"jsonrpc": "2.0", "id": request_id, "result": result}
        else:
            payload = {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32601, "message": "unsupported by B-T probe"},
            }
        try:
            self._send(payload)
        except ProbeFailure:
            pass

    def _read_stderr(self) -> None:
        for _ in self._stderr:
            pass

    def _wake_pending_after_eof(self) -> None:
        with self._state:
            pending = list(self._pending.values())
            self._pending.clear()
            self._state.notify_all()
        error = {
            "jsonrpc": "2.0",
            "error": {
                "code": -32000,
                "message": f"app-server exited with status {self.process.poll()}",
            },
        }
        for response_queue in pending:
            response_queue.put(error)

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        try:
            self._stdin.close()
        except OSError:
            pass


class ResultSet:
    def __init__(self) -> None:
        self.rows: list[dict[str, str]] = []

    def add(self, name: str, status: str, detail: str) -> None:
        if status not in {"PASS", "FAIL", "INCONCLUSIVE", "SKIP"}:
            raise ValueError(f"invalid result status: {status}")
        self.rows.append({"name": name, "status": status, "detail": detail})
        print(f"[{status}] {name}: {detail}", flush=True)

    def has_failures(self) -> bool:
        return any(row["status"] == "FAIL" for row in self.rows)

    def has_inconclusive(self) -> bool:
        return any(row["status"] in {"INCONCLUSIVE", "SKIP"} for row in self.rows)

    def summary(self) -> str:
        if self.has_failures():
            return "FAIL"
        if self.has_inconclusive():
            return "PARTIAL"
        return "PASS"


def locate_binary(value: str, repo_root: Path) -> str:
    candidate = Path(value)
    if candidate.is_absolute() and candidate.is_file():
        return str(candidate)
    repo_candidate = (repo_root / candidate).resolve()
    if repo_candidate.is_file():
        return str(repo_candidate)
    resolved = shutil.which(value)
    if resolved:
        return resolved
    raise ProbeFailure(f"binary not found: {value}")


def codex_version(codex: str) -> str:
    completed = subprocess.run(
        [codex, "--version"],
        text=True,
        capture_output=True,
        check=False,
        timeout=15,
    )
    if completed.returncode != 0:
        raise ProbeFailure("unable to read codex version")
    return completed.stdout.strip()


def safe_mcp_names(rows: list[dict[str, Any]]) -> list[str]:
    names: set[str] = set()
    for row in rows:
        # Match production CodexInvocation: touching a disabled legacy entry can
        # make Codex validate its stale transport and reject the whole config.
        if row.get("enabled") is False:
            continue
        name = row.get("name")
        if isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9_-]+", name):
            names.add(name)
    return sorted(names)


def local_plugin_mcp_name(
    all_rows: list[dict[str, Any]],
    without_plugins: list[dict[str, Any]],
) -> str | None:
    without_names = set(safe_mcp_names(without_plugins))
    for row in all_rows:
        name = row.get("name")
        if (
            isinstance(name, str)
            and name not in without_names
            and (
                isinstance(row.get("command"), str)
                or isinstance(row.get("url"), str)
            )
            and re.fullmatch(r"[A-Za-z0-9_-]+", name)
        ):
            return name
    return None


def app_server_command(
    codex: str,
    *,
    plugins_enabled: bool | None = None,
) -> list[str]:
    command = [
        codex,
        "app-server",
        "--disable",
        "apps",
    ]
    if plugins_enabled is not None:
        command += [
            "--enable" if plugins_enabled else "--disable",
            "plugins",
        ]
    command += ["-c", "web_search=disabled"]
    return command


def initialize(client: JSONRPCClient) -> None:
    client.request(
        "initialize",
        {
            "clientInfo": {
                "name": "rubien-bt-spike",
                "title": "Rubien B-T Spike",
                "version": "0.1.0",
            },
            "capabilities": {
                "experimentalApi": True,
                "requestAttestation": False,
            },
        },
    )
    client.notify("initialized", {})


def config_read_mcp_rows(
    client: JSONRPCClient,
    cwd: Path,
) -> list[dict[str, Any]]:
    result = client.request(
        "config/read",
        {"cwd": str(cwd), "includeLayers": False},
    )
    config = result.get("config")
    if not isinstance(config, dict):
        raise ProbeFailure("config/read returned no config object")
    servers = config.get("mcp_servers")
    if not isinstance(servers, dict):
        raise ProbeFailure("config/read returned no mcp_servers object")

    rows: list[dict[str, Any]] = []
    for name, entry in servers.items():
        if not isinstance(name, str) or not isinstance(entry, dict):
            raise ProbeFailure("config/read returned an invalid MCP entry")
        rows.append({"name": name, **entry})
    return rows


def live_config_read_mcp_rows(
    codex: str,
    repo_root: Path,
    cwd: Path,
    *,
    plugins_enabled: bool,
    request_timeout: float,
    environment: dict[str, str] | None = None,
) -> list[dict[str, Any]]:
    client = JSONRPCClient(
        app_server_command(codex, plugins_enabled=plugins_enabled),
        repo_root,
        request_timeout,
        environment,
    )
    try:
        initialize(client)
        return config_read_mcp_rows(client, cwd)
    finally:
        client.close()


def verify_config_read_catalog_shapes(
    codex: str,
    repo_root: Path,
    root: Path,
    request_timeout: float,
) -> None:
    empty_home = root / "config-read-empty-home"
    populated_home = root / "config-read-populated-home"
    empty_home.mkdir()
    populated_home.mkdir()
    (populated_home / "config.toml").write_text(
        """
[mcp_servers.rubien_probe]
command = "/usr/bin/true"
enabled = true

[mcp_servers.rubien_disabled]
command = "/usr/bin/true"
enabled = false
""".lstrip(),
        encoding="utf-8",
    )

    empty_environment = os.environ.copy()
    empty_environment["CODEX_HOME"] = str(empty_home)
    populated_environment = os.environ.copy()
    populated_environment["CODEX_HOME"] = str(populated_home)
    empty_rows = live_config_read_mcp_rows(
        codex,
        repo_root,
        root,
        plugins_enabled=False,
        request_timeout=request_timeout,
        environment=empty_environment,
    )
    populated_rows = live_config_read_mcp_rows(
        codex,
        repo_root,
        root,
        plugins_enabled=False,
        request_timeout=request_timeout,
        environment=populated_environment,
    )
    if empty_rows:
        raise ProbeFailure("isolated config/read MCP catalog was not empty")
    if safe_mcp_names(populated_rows) != ["rubien_probe"]:
        raise ProbeFailure(
            "populated config/read MCP catalog did not preserve enabled state"
        )


def posture_config(
    rubien_cli: str,
    library_root: Path,
    *,
    read_only: bool,
    web: bool,
    apps: bool,
    plugins: bool,
    plugin_mcp_name: str | None,
    disabled_mcp_names: list[str],
) -> dict[str, Any]:
    rubien_args = ["mcp", "--read-only"] if read_only else ["mcp"]
    mcp_servers: dict[str, Any] = {
        name: {"enabled": False} for name in disabled_mcp_names
    }
    mcp_servers["rubien"] = {
        "enabled": True,
        "command": rubien_cli,
        "args": rubien_args,
        "env": {
            "RUBIEN_LIBRARY_ROOT": str(library_root),
            "RUBIEN_APP_PRESENTATION": "1",
        },
        "tool_timeout_sec": 60,
    }
    if plugin_mcp_name:
        mcp_servers[plugin_mcp_name] = {"enabled": plugins}
    return {
        "features": {"apps": apps, "plugins": plugins},
        # Current 0.145 config uses the explicit WebSearchMode enum. Rubien's
        # launch path still carries the older tools.web_search Boolean, but the
        # generic thread config should exercise the current typed surface.
        "web_search": "live" if web else "disabled",
        "mcp_servers": mcp_servers,
        "model_reasoning_effort": "low",
    }


def start_thread(
    client: JSONRPCClient,
    cwd: Path,
    config: dict[str, Any],
    label: str,
) -> tuple[str, dict[str, Any]]:
    result = client.request(
        "thread/start",
        {
            "cwd": str(cwd),
            "sandbox": "read-only",
            "approvalPolicy": "never",
            "approvalsReviewer": "user",
            "ephemeral": False,
            "developerInstructions": (
                "This is an automated Rubien runtime-isolation probe. "
                f"The posture label is {label}. Never use shell, file-write, or MCP tools "
                "unless the user message explicitly requests the built-in web search probe."
            ),
            "config": config,
        },
        timeout=120,
    )
    thread = result.get("thread")
    if not isinstance(thread, dict) or not isinstance(thread.get("id"), str):
        raise ProbeFailure("thread/start returned no thread id")
    return thread["id"], thread


def resume_thread(
    client: JSONRPCClient,
    thread_id: str,
    cwd: Path,
    config: dict[str, Any],
) -> dict[str, Any]:
    return client.request(
        "thread/resume",
        {
            "threadId": thread_id,
            "cwd": str(cwd),
            "approvalsReviewer": "user",
            "config": config,
        },
        timeout=120,
    )


def thread_mcp_catalog(client: JSONRPCClient, thread_id: str) -> dict[str, set[str]]:
    result = client.request(
        "mcpServerStatus/list",
        {"threadId": thread_id, "detail": "full"},
        timeout=120,
    )
    output: dict[str, set[str]] = {}
    for row in result.get("data", []):
        if not isinstance(row, dict) or not isinstance(row.get("name"), str):
            continue
        tools = row.get("tools")
        output[row["name"]] = set(tools.keys()) if isinstance(tools, dict) else set()
    return output


def feature_map(client: JSONRPCClient, thread_id: str) -> dict[str, bool]:
    result = client.request(
        "experimentalFeature/list",
        {"threadId": thread_id, "limit": 500},
    )
    output: dict[str, bool] = {}
    for row in result.get("data", []):
        if (
            isinstance(row, dict)
            and isinstance(row.get("name"), str)
            and isinstance(row.get("enabled"), bool)
        ):
            output[row["name"]] = row["enabled"]
    return output


def installed_app_counts(client: JSONRPCClient, thread_id: str) -> tuple[int, int]:
    try:
        result = client.request(
            "app/installed",
            {"threadId": thread_id, "forceRefresh": False},
            timeout=120,
        )
        apps = result.get("apps")
        enabled_key = "enabled"
        callable_key = "callable"
    except RPCError as error:
        message = str(error.error.get("message", ""))
        if "unknown variant `app/installed`" not in message:
            raise
        # Codex 0.142.5 exposes the same thread-aware boundary through the
        # earlier app/list method and names the runtime flags differently.
        result = client.request(
            "app/list",
            {
                "threadId": thread_id,
                "forceRefetch": False,
                "limit": 500,
            },
            timeout=120,
        )
        apps = result.get("data")
        enabled_key = "isEnabled"
        callable_key = "isAccessible"
    if not isinstance(apps, list):
        return 0, 0
    enabled = sum(
        1 for app in apps
        if isinstance(app, dict) and app.get(enabled_key) is True
    )
    callable_count = sum(
        1 for app in apps
        if isinstance(app, dict) and app.get(callable_key) is True
    )
    return enabled, callable_count


def mcp_tool_call(
    client: JSONRPCClient,
    thread_id: str,
    tool: str,
    arguments: dict[str, Any],
) -> dict[str, Any]:
    return client.request(
        "mcpServer/tool/call",
        {
            "threadId": thread_id,
            "server": "rubien",
            "tool": tool,
            "arguments": arguments,
        },
        timeout=120,
    )


def reference_titles(rubien_cli: str, library_root: Path) -> list[str]:
    environment = os.environ.copy()
    environment["RUBIEN_LIBRARY_ROOT"] = str(library_root)
    completed = subprocess.run(
        [rubien_cli, "list", "--limit", "0"],
        env=environment,
        text=True,
        capture_output=True,
        check=False,
        timeout=30,
    )
    if completed.returncode != 0:
        raise ProbeFailure("unable to inspect the isolated Rubien library")
    try:
        value = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise ProbeFailure("rubien-cli list returned invalid JSON") from exc
    if not isinstance(value, list):
        return []
    return [
        row["title"]
        for row in value
        if isinstance(row, dict) and isinstance(row.get("title"), str)
    ]


def descendant_commands(root_pid: int) -> list[tuple[int, str]]:
    completed = subprocess.run(
        ["ps", "-Ao", "pid=,ppid=,command="],
        text=True,
        capture_output=True,
        check=True,
        timeout=10,
    )
    rows: dict[int, tuple[int, str]] = {}
    for line in completed.stdout.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) != 3:
            continue
        try:
            pid, parent = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        rows[pid] = (parent, parts[2])
    descendants = {root_pid}
    changed = True
    while changed:
        changed = False
        for pid, (parent, _) in rows.items():
            if parent in descendants and pid not in descendants:
                descendants.add(pid)
                changed = True
    return [(pid, rows[pid][1]) for pid in descendants if pid != root_pid and pid in rows]


def turn_start(client: JSONRPCClient, thread_id: str) -> tuple[str, int]:
    start_index = client.notification_count
    result = client.request(
        "turn/start",
        {
            "threadId": thread_id,
            "input": [
                {
                    "type": "text",
                    "text": (
                        "Use the built-in web search tool exactly once to find the official "
                        "OpenAI Codex app-server documentation. Do not use MCP, shell, or any "
                        "other tool. If web search is unavailable, say WEB_UNAVAILABLE. "
                        "Otherwise, after the search say WEB_PROBE_DONE."
                    ),
                    "text_elements": [],
                }
            ],
            "effort": "low",
        },
        timeout=60,
    )
    turn = result.get("turn")
    if not isinstance(turn, dict) or not isinstance(turn.get("id"), str):
        raise ProbeFailure("turn/start returned no turn id")
    return turn["id"], start_index


def wait_for_turn(
    client: JSONRPCClient,
    turn_id: str,
    start_index: int,
    timeout: float,
) -> list[dict[str, Any]]:
    def completed(message: dict[str, Any]) -> bool:
        if message.get("method") != "turn/completed":
            return False
        params = message.get("params")
        turn = params.get("turn") if isinstance(params, dict) else None
        return isinstance(turn, dict) and turn.get("id") == turn_id

    _, messages = client.wait_for_notification(start_index, completed, timeout)
    return messages


def contains_web_event(value: Any) -> bool:
    if isinstance(value, dict):
        for key, nested in value.items():
            if key == "type" and nested in {
                "webSearch",
                "web_search",
                "web_search_call",
            }:
                return True
            if contains_web_event(nested):
                return True
    elif isinstance(value, list):
        return any(contains_web_event(item) for item in value)
    return False


def web_event_summary(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    summary: list[dict[str, Any]] = []
    for message in messages:
        params = message.get("params")
        item = params.get("item") if isinstance(params, dict) else None
        if not isinstance(item, dict) or item.get("type") != "webSearch":
            continue
        results = item.get("results")
        action = item.get("action")
        summary.append(
            {
                "method": message.get("method"),
                "resultCount": len(results) if isinstance(results, list) else None,
                "action": action.get("type") if isinstance(action, dict) else None,
            }
        )
    return summary


def archive_thread(client: JSONRPCClient, thread_id: str) -> None:
    try:
        client.request("thread/archive", {"threadId": thread_id}, timeout=30)
    except (ProbeFailure, RPCError):
        pass


def unsubscribe(client: JSONRPCClient, thread_id: str) -> str:
    result = client.request(
        "thread/unsubscribe",
        {"threadId": thread_id},
        timeout=30,
    )
    return str(result.get("status", "unknown"))


def run_launch_web_off_control(
    codex: str,
    repo_root: Path,
    cwd: Path,
    disabled_mcp_names: list[str],
    web_override: str,
    request_timeout: float,
    turn_timeout: float,
) -> list[dict[str, Any]]:
    command = [
        codex,
        "app-server",
        "--disable",
        "apps",
        "--disable",
        "plugins",
        "-c",
        web_override,
    ]
    for name in disabled_mcp_names:
        command += ["-c", f"mcp_servers.{name}.enabled=false"]
    client = JSONRPCClient(command, repo_root, request_timeout)
    thread_id: str | None = None
    try:
        initialize(client)
        thread_id, _ = start_thread(
            client,
            cwd,
            {"model_reasoning_effort": "low"},
            "launch-web-off-control",
        )
        turn_id, start_index = turn_start(client, thread_id)
        return wait_for_turn(client, turn_id, start_index, turn_timeout)
    finally:
        if thread_id:
            archive_thread(client, thread_id)
        client.close()


def run_launch_web_controls_only(
    args: argparse.Namespace,
) -> tuple[ResultSet, dict[str, Any]]:
    repo_root = Path(__file__).resolve().parent.parent
    codex = locate_binary(args.codex, repo_root)
    version = codex_version(codex)
    print(f"Codex: {version}", flush=True)
    results = ResultSet()

    with tempfile.TemporaryDirectory(prefix="rubien-bt-web-control-") as temporary:
        cwd = Path(temporary) / "workspace"
        cwd.mkdir()
        no_plugin_rows = live_config_read_mcp_rows(
            codex,
            repo_root,
            cwd,
            plugins_enabled=False,
            request_timeout=args.request_timeout,
        )
        disabled_mcp_names = safe_mcp_names(no_plugin_rows)
        controls = [
            ("legacy launch-level web-off control", "tools.web_search=false"),
            ("typed launch-level web-off control", "web_search=disabled"),
        ]
        for name, override in controls:
            try:
                messages = run_launch_web_off_control(
                    codex,
                    repo_root,
                    cwd,
                    disabled_mcp_names,
                    override,
                    args.request_timeout,
                    args.turn_timeout,
                )
                summary = web_event_summary(messages)
                if any(contains_web_event(message) for message in messages):
                    results.add(
                        name,
                        "FAIL",
                        f"{override} produced web-search items: {summary}",
                    )
                else:
                    results.add(
                        name,
                        "PASS",
                        f"{override} suppressed web-search events",
                    )
            except (ProbeFailure, RPCError) as error:
                results.add(
                    name,
                    "INCONCLUSIVE",
                    f"single-thread launch control did not complete: {error}",
                )

    return results, {
        "codexVersion": version,
        "launchWebControlsOnly": True,
    }


def run_config_read_controls_only(
    args: argparse.Namespace,
) -> tuple[ResultSet, dict[str, Any]]:
    repo_root = Path(__file__).resolve().parent.parent
    codex = locate_binary(args.codex, repo_root)
    version = codex_version(codex)
    print(f"Codex: {version}", flush=True)
    results = ResultSet()
    with tempfile.TemporaryDirectory(prefix="rubien-bt-config-read-") as temporary:
        verify_config_read_catalog_shapes(
            codex,
            repo_root,
            Path(temporary),
            args.request_timeout,
        )
    results.add(
        "config/read MCP compatibility",
        "PASS",
        "live app-server returned the expected empty and populated MCP catalogs",
    )
    return results, {
        "codexVersion": version,
        "configReadControlsOnly": True,
    }


def run_probe(args: argparse.Namespace) -> tuple[ResultSet, dict[str, Any]]:
    repo_root = Path(__file__).resolve().parent.parent
    codex = locate_binary(args.codex, repo_root)
    rubien_cli = locate_binary(args.rubien_cli, repo_root)
    version = codex_version(codex)
    print(f"Codex: {version}", flush=True)

    results = ResultSet()
    metadata: dict[str, Any] = {
        "codexVersion": version,
        "idleUnloadWaited": False,
    }

    with tempfile.TemporaryDirectory(prefix="rubien-bt-spike-") as temporary:
        root = Path(temporary)
        library_root = root / "library"
        full_cwd = root / "full-workspace"
        read_only_cwd = root / "read-only-workspace"
        library_root.mkdir()
        full_cwd.mkdir()
        read_only_cwd.mkdir()

        verify_config_read_catalog_shapes(
            codex,
            repo_root,
            root,
            args.request_timeout,
        )
        results.add(
            "config/read MCP compatibility",
            "PASS",
            "live app-server returned the expected empty and populated MCP catalogs",
        )
        ambient_rows = live_config_read_mcp_rows(
            codex,
            repo_root,
            full_cwd,
            plugins_enabled=True,
            request_timeout=args.request_timeout,
        )
        no_plugin_rows = live_config_read_mcp_rows(
            codex,
            repo_root,
            read_only_cwd,
            plugins_enabled=False,
            request_timeout=args.request_timeout,
        )
        # MCP disable overrides live in each thread config. Applying them at
        # process scope happens before plugin transports are layered and can
        # recreate transport-less entries.
        non_plugin_ambient_names = safe_mcp_names(no_plugin_rows)
        plugin_mcp = local_plugin_mcp_name(ambient_rows, no_plugin_rows)
        metadata["pluginMCPAvailable"] = plugin_mcp is not None
        command = app_server_command(codex, plugins_enabled=True)

        full_config = posture_config(
            rubien_cli,
            library_root,
            read_only=False,
            web=True,
            apps=True,
            plugins=True,
            plugin_mcp_name=plugin_mcp,
            # Plugin transports are layered after generic config overrides.
            # Naming a plugin-provided MCP here recreates a transport-less entry;
            # leave plugin MCPs to the feature gate and user plugin config.
            disabled_mcp_names=non_plugin_ambient_names,
        )
        read_only_config = posture_config(
            rubien_cli,
            library_root,
            read_only=True,
            web=False,
            apps=False,
            plugins=False,
            plugin_mcp_name=plugin_mcp,
            disabled_mcp_names=non_plugin_ambient_names,
        )

        first = JSONRPCClient(command, repo_root, args.request_timeout)
        thread_ids: list[str] = []
        durable_threads = False
        try:
            initialize(first)
            print("Starting opposite-posture threads on one app-server...", flush=True)
            full_id, full_thread = start_thread(first, full_cwd, full_config, "full")
            read_only_id, read_only_thread = start_thread(
                first, read_only_cwd, read_only_config, "read-only"
            )
            thread_ids = [full_id, read_only_id]
            metadata["threadIds"] = thread_ids

            full_reported_cwd = full_thread.get("cwd")
            read_only_reported_cwd = read_only_thread.get("cwd")
            if (
                full_reported_cwd == str(full_cwd)
                and read_only_reported_cwd == str(read_only_cwd)
            ):
                results.add(
                    "opposite cwd",
                    "PASS",
                    "each loaded thread reports its own requested workspace",
                )
            else:
                results.add(
                    "opposite cwd",
                    "FAIL",
                    "thread/start did not preserve both requested workspaces",
                )

            print("Reading thread-scoped MCP catalogs...", flush=True)
            full_catalog = thread_mcp_catalog(first, full_id)
            read_only_catalog = thread_mcp_catalog(first, read_only_id)
            full_tools = full_catalog.get("rubien", set())
            read_only_tools = read_only_catalog.get("rubien", set())
            if (
                "rubien_create_reference" in full_tools
                and "rubien_create_reference" not in read_only_tools
                and "rubien_list_references" in full_tools
                and "rubien_list_references" in read_only_tools
            ):
                results.add(
                    "opposite Rubien MCP catalogs",
                    "PASS",
                    "full exposes writes; read-only exposes reads but no create tool",
                )
            else:
                results.add(
                    "opposite Rubien MCP catalogs",
                    "FAIL",
                    "the two threads did not resolve distinct expected Rubien catalogs",
                )

            descendants = descendant_commands(first.pid)
            rubien_children = [
                command_line
                for _, command_line in descendants
                if rubien_cli in command_line and " mcp" in command_line
            ]
            has_full_child = any("--read-only" not in command_line for command_line in rubien_children)
            has_read_only_child = any("--read-only" in command_line for command_line in rubien_children)
            if len(rubien_children) >= 2 and has_full_child and has_read_only_child:
                results.add(
                    "per-thread MCP processes",
                    "PASS",
                    "one app-server owns distinct full and read-only Rubien MCP children",
                )
            else:
                results.add(
                    "per-thread MCP processes",
                    "FAIL",
                    "did not observe both full and read-only Rubien MCP child commands",
                )

            sentinel = "Rubien B-T isolated write sentinel"
            before = reference_titles(rubien_cli, library_root)
            read_only_rejected = False
            try:
                response = mcp_tool_call(
                    first,
                    read_only_id,
                    "rubien_create_reference",
                    {"title": sentinel},
                )
                read_only_rejected = response.get("isError") is True
            except RPCError:
                read_only_rejected = True
            after_read_only = reference_titles(rubien_cli, library_root)
            if read_only_rejected and before == after_read_only and sentinel not in after_read_only:
                results.add(
                    "read-only write enforcement",
                    "PASS",
                    "direct write call was rejected and the isolated library stayed unchanged",
                )
            else:
                results.add(
                    "read-only write enforcement",
                    "FAIL",
                    "read-only write was not rejected cleanly or changed the isolated library",
                )

            try:
                full_response = mcp_tool_call(
                    first,
                    full_id,
                    "rubien_create_reference",
                    {"title": sentinel},
                )
                full_call_ok = full_response.get("isError") is not True
            except RPCError:
                full_call_ok = False
            after_full = reference_titles(rubien_cli, library_root)
            if full_call_ok and sentinel in after_full:
                results.add(
                    "write-capable control",
                    "PASS",
                    "the opposite thread created the sentinel in the isolated library",
                )
            else:
                results.add(
                    "write-capable control",
                    "FAIL",
                    "the full-posture control could not create the isolated sentinel",
                )

            full_features = feature_map(first, full_id)
            read_only_features = feature_map(first, read_only_id)
            feature_pairs = {
                name: (full_features.get(name), read_only_features.get(name))
                for name in ("apps", "plugins")
            }
            if all(pair == (True, False) for pair in feature_pairs.values()):
                results.add(
                    "thread-scoped Apps/plugins flags",
                    "PASS",
                    "feature inventory reports enabled on full and disabled on read-only",
                )
            else:
                results.add(
                    "thread-scoped Apps/plugins flags",
                    "FAIL",
                    f"unexpected feature states: {feature_pairs}",
                )

            if plugin_mcp:
                full_plugin_tools = full_catalog.get(plugin_mcp, set())
                read_only_plugin_tools = read_only_catalog.get(plugin_mcp, set())
                plugin_in_full = bool(full_plugin_tools)
                plugin_in_read_only = bool(read_only_plugin_tools)
                if plugin_in_full and not plugin_in_read_only:
                    results.add(
                        "plugin MCP enforcement",
                        "PASS",
                        "a local plugin MCP is present only on the plugin-enabled thread",
                    )
                elif not plugin_in_full and not plugin_in_read_only:
                    results.add(
                        "plugin MCP enforcement",
                        "INCONCLUSIVE",
                        "the safe local plugin canary exposed no tools on the enabled control",
                    )
                else:
                    results.add(
                        "plugin MCP enforcement",
                        "FAIL",
                        "local plugin MCP tool counts were "
                        f"full={len(full_plugin_tools)}, "
                        f"read-only={len(read_only_plugin_tools)}",
                    )
            else:
                results.add(
                    "plugin MCP enforcement",
                    "INCONCLUSIVE",
                    "no local stdio plugin MCP was available as a safe behavioral canary",
                )

            try:
                full_enabled_apps, full_callable_apps = installed_app_counts(first, full_id)
                read_only_enabled_apps, read_only_callable_apps = installed_app_counts(
                    first, read_only_id
                )
                if (
                    read_only_enabled_apps == 0
                    and read_only_callable_apps == 0
                    and (full_enabled_apps > 0 or full_callable_apps > 0)
                ):
                    results.add(
                        "Apps runtime enforcement",
                        "PASS",
                        "only the Apps-enabled thread reports enabled/callable Apps",
                    )
                elif read_only_enabled_apps == 0 and read_only_callable_apps == 0:
                    results.add(
                        "Apps runtime enforcement",
                        "INCONCLUSIVE",
                        "Apps are off on read-only, but no enabled control App was available",
                    )
                else:
                    results.add(
                        "Apps runtime enforcement",
                        "FAIL",
                        "the Apps-disabled thread still reports an enabled or callable App",
                    )
            except (ProbeFailure, RPCError) as error:
                results.add(
                    "Apps runtime enforcement",
                    "INCONCLUSIVE",
                    f"thread-aware app inventory was unavailable: {error}",
                )

            if args.exercise_web:
                print("Starting concurrent web-on/web-off turns...", flush=True)
                web_on_turn, web_on_start = turn_start(first, full_id)
                web_off_turn, web_off_start = turn_start(first, read_only_id)
                durable_threads = True
                try:
                    web_on_messages = wait_for_turn(
                        first, web_on_turn, web_on_start, args.turn_timeout
                    )
                    web_off_messages = wait_for_turn(
                        first, web_off_turn, web_off_start, args.turn_timeout
                    )
                    web_on_used = any(contains_web_event(message) for message in web_on_messages)
                    web_off_used = any(contains_web_event(message) for message in web_off_messages)
                    web_on_summary = web_event_summary(web_on_messages)
                    web_off_summary = web_event_summary(web_off_messages)
                    if web_on_used and not web_off_used:
                        results.add(
                            "web-search enforcement",
                            "PASS",
                            "concurrent turns used web only on the web-enabled thread",
                        )
                    elif not web_off_used:
                        results.add(
                            "web-search enforcement",
                            "INCONCLUSIVE",
                            "web-off emitted no web event, but the enabled control also did not search",
                        )
                    else:
                        results.add(
                            "web-search enforcement",
                            "FAIL",
                            "web-disabled thread emitted web-search items: "
                            f"{web_off_summary}; enabled control: {web_on_summary}",
                        )
                except (ProbeFailure, RPCError) as error:
                    results.add(
                        "web-search enforcement",
                        "INCONCLUSIVE",
                        f"web control turns did not complete cleanly: {error}",
                    )
            else:
                results.add(
                    "web-search enforcement",
                    "SKIP",
                    "rerun with --exercise-web to use authenticated model turns",
                )

            if durable_threads:
                print("Running loaded-resume negative controls...", flush=True)
                loaded_resume = resume_thread(first, read_only_id, full_cwd, full_config)
                loaded_resume_catalog = thread_mcp_catalog(first, read_only_id)
                loaded_resume_tools = loaded_resume_catalog.get("rubien", set())
                loaded_resume_features = feature_map(first, read_only_id)
                loaded_thread = loaded_resume.get("thread")
                loaded_cwd = (
                    loaded_thread.get("cwd") if isinstance(loaded_thread, dict) else None
                )
                if (
                    "rubien_create_reference" not in loaded_resume_tools
                    and loaded_resume_features.get("apps") is False
                    and loaded_resume_features.get("plugins") is False
                    and loaded_cwd == str(read_only_cwd)
                ):
                    results.add(
                        "loaded resume ignores posture override",
                        "PASS",
                        "subscribed resume retained old MCP/features/cwd",
                    )
                else:
                    results.add(
                        "loaded resume ignores posture override",
                        "FAIL",
                        "subscribed resume changed at least one posture dimension",
                    )

                unsubscribe_status = unsubscribe(first, read_only_id)
                transition_resume = resume_thread(
                    first, read_only_id, full_cwd, full_config
                )
                immediate_catalog = thread_mcp_catalog(first, read_only_id)
                immediate_tools = immediate_catalog.get("rubien", set())
                immediate_features = feature_map(first, read_only_id)
                transition_thread = transition_resume.get("thread")
                transition_cwd = (
                    transition_thread.get("cwd")
                    if isinstance(transition_thread, dict)
                    else None
                )
                if (
                    unsubscribe_status == "unsubscribed"
                    and "rubien_create_reference" in immediate_tools
                    and immediate_features.get("apps") is True
                    and immediate_features.get("plugins") is True
                    and transition_cwd == str(full_cwd)
                ):
                    results.add(
                        "unsubscribe/resume posture transition",
                        "PASS",
                        "immediate resume applied new MCP/features/cwd on the same server",
                    )
                else:
                    results.add(
                        "unsubscribe/resume posture transition",
                        "FAIL",
                        f"status={unsubscribe_status}, "
                        f"write={'rubien_create_reference' in immediate_tools}, "
                        f"apps={immediate_features.get('apps')}, "
                        f"plugins={immediate_features.get('plugins')}, "
                        f"cwdChanged={transition_cwd == str(full_cwd)}",
                    )
            else:
                results.add(
                    "loaded resume ignores posture override",
                    "SKIP",
                    "a durable turn is required; rerun with --exercise-web",
                )
                results.add(
                    "unsubscribe/resume posture transition",
                    "SKIP",
                    "a durable turn is required; rerun with --exercise-web",
                )

            for thread_id in thread_ids:
                try:
                    unsubscribe(first, thread_id)
                except (ProbeFailure, RPCError):
                    pass
        finally:
            first.close()

        print("Restarting app-server for a true cold-resume control...", flush=True)
        second = JSONRPCClient(command, repo_root, args.request_timeout)
        try:
            initialize(second)
            if len(thread_ids) == 2 and durable_threads:
                _, read_only_id = thread_ids
                resume_thread(second, read_only_id, full_cwd, full_config)
                cold_catalog = thread_mcp_catalog(second, read_only_id)
                cold_tools = cold_catalog.get("rubien", set())
                cold_features = feature_map(second, read_only_id)
                if (
                    "rubien_create_reference" in cold_tools
                    and cold_features.get("apps") is True
                    and cold_features.get("plugins") is True
                ):
                    results.add(
                        "cold resume applies new posture",
                        "PASS",
                        "same thread id resumed after restart with full MCP/feature posture",
                    )
                else:
                    results.add(
                        "cold resume applies new posture",
                        "FAIL",
                        "cold resume did not apply the requested full posture",
                    )
                try:
                    unsubscribe(second, read_only_id)
                except (ProbeFailure, RPCError):
                    pass
            else:
                results.add(
                    "cold resume applies new posture",
                    "SKIP",
                    "a durable turn is required; rerun with --exercise-web",
                )
            for thread_id in thread_ids:
                archive_thread(second, thread_id)
        finally:
            second.close()

        if args.exercise_web:
            print("Running Rubien's current launch-level web-off control...", flush=True)
            try:
                launch_web_messages = run_launch_web_off_control(
                    codex,
                    repo_root,
                    read_only_cwd,
                    non_plugin_ambient_names,
                    "tools.web_search=false",
                    args.request_timeout,
                    args.turn_timeout,
                )
                launch_web_summary = web_event_summary(launch_web_messages)
                if any(contains_web_event(message) for message in launch_web_messages):
                    results.add(
                        "launch-level web-off control",
                        "FAIL",
                        "Rubien's current tools.web_search=false launch flag still "
                        f"produced web-search items: {launch_web_summary}",
                    )
                else:
                    results.add(
                        "launch-level web-off control",
                        "PASS",
                        "Rubien's current launch flag suppressed web-search events",
                    )
            except (ProbeFailure, RPCError) as error:
                results.add(
                    "launch-level web-off control",
                    "INCONCLUSIVE",
                    f"single-thread launch control did not complete: {error}",
                )
            try:
                typed_launch_messages = run_launch_web_off_control(
                    codex,
                    repo_root,
                    read_only_cwd,
                    non_plugin_ambient_names,
                    "web_search=disabled",
                    args.request_timeout,
                    args.turn_timeout,
                )
                typed_launch_summary = web_event_summary(typed_launch_messages)
                if any(contains_web_event(message) for message in typed_launch_messages):
                    results.add(
                        "typed launch-level web-off control",
                        "FAIL",
                        "web_search=disabled still produced web-search items: "
                        f"{typed_launch_summary}",
                    )
                else:
                    results.add(
                        "typed launch-level web-off control",
                        "PASS",
                        "web_search=disabled suppressed web-search events",
                    )
            except (ProbeFailure, RPCError) as error:
                results.add(
                    "typed launch-level web-off control",
                    "INCONCLUSIVE",
                    f"single-thread typed control did not complete: {error}",
                )
        else:
            results.add(
                "launch-level web-off control",
                "SKIP",
                "rerun with --exercise-web",
            )
            results.add(
                "typed launch-level web-off control",
                "SKIP",
                "rerun with --exercise-web",
            )

        results.add(
            "same-process idle unload",
            "SKIP",
            "Codex uses a fixed 30-minute last-subscriber idle timeout",
        )

    return results, metadata


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default="codex", help="Codex CLI path")
    parser.add_argument(
        "--rubien-cli",
        default=".build/debug/rubien-cli",
        help="rubien-cli path (default: existing debug build)",
    )
    parser.add_argument(
        "--request-timeout",
        type=float,
        default=180.0,
        help="JSON-RPC request timeout in seconds",
    )
    parser.add_argument(
        "--turn-timeout",
        type=float,
        default=300.0,
        help="completion timeout for each optional web turn",
    )
    parser.add_argument(
        "--exercise-web",
        action="store_true",
        help="run two authenticated model turns to verify web on/off behavior",
    )
    parser.add_argument(
        "--launch-web-controls-only",
        action="store_true",
        help="test only legacy and typed process-level web-off settings",
    )
    parser.add_argument(
        "--config-read-controls-only",
        action="store_true",
        help="test only empty and populated app-server config/read MCP catalogs",
    )
    parser.add_argument(
        "--json-output",
        type=Path,
        help="optional path for the machine-readable result report",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.config_read_controls_only:
            results, metadata = run_config_read_controls_only(args)
        elif args.launch_web_controls_only:
            results, metadata = run_launch_web_controls_only(args)
        else:
            results, metadata = run_probe(args)
    except (ProbeFailure, RPCError, OSError, subprocess.SubprocessError) as error:
        print(f"[FATAL] {error}", file=sys.stderr, flush=True)
        return 1

    report = {
        "summary": results.summary(),
        "metadata": metadata,
        "checks": results.rows,
    }
    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    print(json.dumps(report, indent=2, sort_keys=True), flush=True)
    return 1 if results.has_failures() else (2 if results.has_inconclusive() else 0)


if __name__ == "__main__":
    raise SystemExit(main())
