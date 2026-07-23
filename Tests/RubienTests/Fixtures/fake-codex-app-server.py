#!/usr/bin/env python3
"""A fake `codex app-server` speaking the v2 JSON-RPC thread/turn/item protocol, for
driving `CodexProviderTests` end-to-end WITHOUT the real binary (or a login).

Long-lived like the real server: ONE process handles the initialize handshake and
then any number of thread/turn requests. Each turn runs on its own worker so tests
can exercise real app-server multiplexing while the main loop continues routing
responses and interrupts. Behavior is configured per-TURN by a `fake-codex.json`
file in the process cwd (the provider sets cwd = the turn's workspace; tests rewrite
the file between sends). It:

  * answers `--version` (for `isAvailable()`),
  * records its argv (`fake-codex-argv.json`) so tests can assert the `--disable
    apps` / `-c mcp_servers.rubien.*` injection,
  * records what it observed (`fake-codex-observed.json`): thread/turn counts, the
    approval decision it received + the JSON type of the response id (the verbatim-
    id contract), whether an unsupported request got answered, interrupts, its pid,
  * per config: streams deltas + a completed agentMessage + tokenUsage, raises a
    commandExecution approval REQUEST (numeric id, starts at 0) and BLOCKS until the
    response, raises an unknown server request, hangs until `turn/interrupt`, or
    exits non-zero after `turn/start` (crash path).

Config keys (all optional): deltas[], assistantText (supports "{threadStarts}",
"{threadId}", and "{turnId}"), completionDelayMs,
usageLast{...}, approval{reason,command,availableDecisions[]},
mcpApproval{server,tool,mutation}, unknownRequest(bool),
hang(bool), exitAfterTurnStart(int), models[] / modelListError (model/list).
`mcpListDelayMs` delays the standalone `mcp list --json` isolation probe.
History (3b-4): threads[] (thread/list data), searchHits[] (thread/search data,
each {thread,snippet}), transcript{turns:[…]} (thread/read), and
threadReadDelayOnceMs (delay the first read across respawns). All record params.
"""
import json
import os
import queue
import subprocess
import sys
import threading
import time

OBSERVED = {
    "pid": os.getpid(),
    "threadStarts": 0,
    "threadResumes": 0,
    "turnStarts": 0,
    "interrupts": 0,
}
OUTPUT_LOCK = threading.Lock()
OBSERVED_LOCK = threading.RLock()


def emit(obj):
    with OUTPUT_LOCK:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()


def notify(method, params):
    emit({"jsonrpc": "2.0", "method": method, "params": params})


def respond(req_id, result):
    emit({"jsonrpc": "2.0", "id": req_id, "result": result})


def _atomic_write_json(filename, obj):
    # Write a temp file then os.replace() (atomic rename) so a concurrent reader
    # never sees a truncated/empty file. Plain open(..., "w") truncates BEFORE
    # json.dump refills it; the Swift tests poll these files and intermittently
    # caught that empty window (flaky "Unable to parse empty data").
    tmp = filename + ".tmp"
    with open(tmp, "w") as handle:
        json.dump(obj, handle)
    os.replace(tmp, filename)


def record(**kv):
    with OBSERVED_LOCK:
        OBSERVED.update(kv)
        try:
            _atomic_write_json("fake-codex-observed.json", OBSERVED)
        except OSError:
            pass


def increment_observed(key, **kv):
    with OBSERVED_LOCK:
        value = OBSERVED.get(key, 0) + 1
        record(**{key: value}, **kv)
        return value


def record_approval(thread_id, key, value):
    with OBSERVED_LOCK:
        by_thread_key = key + "sByThread"
        by_thread = dict(OBSERVED.get(by_thread_key, {}))
        by_thread[thread_id] = value
        record(**{key: value, by_thread_key: by_thread})


def load_config(directory=None):
    try:
        path = os.path.join(directory or os.curdir, "fake-codex.json")
        with open(path) as handle:
            return json.load(handle)
    except Exception:
        return {}


def _seed_model_list_requests():
    """`model/list` probes are SHORT-LIVED — one fresh process per fetch, unlike
    the long-lived turn server the rest of OBSERVED tracks within a single
    process's lifetime — so the in-memory counter above would reset to 0 on
    every spawn. Seed it from the previous process's observed file (same cwd)
    so a test spanning multiple probe spawns (forceReload) can assert a
    cumulative request count."""
    try:
        with open("fake-codex-observed.json") as handle:
            prior = json.load(handle)
        OBSERVED["modelListRequests"] = prior.get("modelListRequests", 0)
    except Exception:
        pass


def read_message():
    line = sys.stdin.readline()
    if not line:
        return None
    line = line.strip()
    if not line:
        return {}
    try:
        return json.loads(line)
    except ValueError:
        return {}


def spawn_grandchild():
    """A sleeping grandchild in the SAME process group, to prove process-tree kill
    reaps orphans (mirrors fake-claude). It must NOT inherit our stdout, or it would
    hold the pipe open and the parent would never see EOF after we exit."""
    try:
        child = subprocess.Popen(
            ["/bin/sleep", "30"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        record(grandchildPID=child.pid)
    except OSError:
        pass


class Server:
    def __init__(self):
        self.thread_id = "TH-1"
        self.thread_seq = 0
        self.turn_seq = 0
        self.server_req_seq = 0  # server-initiated request ids: 0, 1, 2… (real codex)
        self.seen_initialized = False
        self.state_lock = threading.RLock()
        self.response_waiters = {}
        self.turn_interrupts = {}
        self.thread_workspaces = {}
        self.shutdown_event = threading.Event()

    def next_server_request(self, method, params):
        with self.state_lock:
            req_id = self.server_req_seq
            self.server_req_seq += 1
            self.response_waiters[req_id] = queue.Queue(maxsize=1)
        emit({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params})
        return req_id

    def wait_for_response(self, req_id, interrupt_event):
        """Wait without consuming stdin. The main loop demultiplexes responses and
        interrupts so several turn workers can block independently."""
        with self.state_lock:
            waiter = self.response_waiters.get(req_id)
        if waiter is None:
            return ("eof", None)
        try:
            while not self.shutdown_event.is_set():
                if interrupt_event.is_set():
                    return ("interrupted", None)
                try:
                    msg = waiter.get(timeout=0.05)
                    id_type = "int" if isinstance(msg["id"], int) else "str"
                    return ("response", {"message": msg, "idType": id_type})
                except queue.Empty:
                    pass
            return ("eof", None)
        finally:
            with self.state_lock:
                self.response_waiters.pop(req_id, None)

    def run_turn(self, req_id, params):
        with self.state_lock:
            self.turn_seq += 1
            turn_id = f"TU-{self.turn_seq}"
            interrupt_event = threading.Event()
            self.turn_interrupts[turn_id] = interrupt_event
            thread_id = params.get("threadId", self.thread_id)
            thread_workspace = self.thread_workspaces.get(thread_id)
        cfg = load_config(thread_workspace)
        increment_observed("turnStarts", lastTurnParams=params)
        respond(req_id, {"turn": {"id": turn_id, "status": "inProgress"}})
        base = {"threadId": thread_id, "turnId": turn_id}
        notify("turn/started", {"threadId": thread_id, "turn": {"id": turn_id}})

        # A straggler completion for a DIFFERENT (old/abandoned) turn id: the positive
        # turn-id filter must DROP it, not finish this turn's stream early (review #2).
        if cfg.get("emitStaleCompletion"):
            notify("turn/completed", {"threadId": thread_id,
                                      "turn": {"id": "TU-OLD-STALE", "status": "completed", "error": None}})

        if cfg.get("closeStdoutStayAlive"):
            # Close stdout at the OS level but DON'T exit — the connection's SIGKILL
            # must force us down so pending requests don't hang (review #4).
            try:
                sys.stdout.flush()
                os.close(1)
            except OSError:
                pass
            time.sleep(30)
            return True

        if cfg.get("exitAfterTurnStart") is not None:
            sys.stderr.write("fake-codex: deliberate crash\n")
            sys.stderr.flush()
            os._exit(int(cfg["exitAfterTurnStart"]))

        # Approval flow: item/started(commandExecution) → server request → wait.
        if "approval" in cfg:
            approval = cfg["approval"] or {}
            item = {
                "type": "commandExecution",
                "id": "call_FAKE",
                "command": approval.get("command", "touch out.txt"),
                "status": "inProgress",
            }
            notify("item/started", dict(base, item=item))
            req = {
                "threadId": thread_id,
                "turnId": turn_id,
                "itemId": "call_FAKE",
                "startedAtMs": 0,
                "reason": approval.get("reason", "Allow writing out.txt?").replace(
                    "{threadId}", thread_id
                ),
                "command": approval.get("command", "touch out.txt"),
                "availableDecisions": approval.get(
                    "availableDecisions", ["accept", "acceptForSession", "decline", "cancel"]
                ),
            }
            server_req = self.next_server_request("item/commandExecution/requestApproval", req)
            kind, payload = self.wait_for_response(server_req, interrupt_event)
            if kind == "eof":
                return False
            if kind == "interrupted":
                notify("turn/completed", {"threadId": thread_id, "turn": {"id": turn_id, "status": "interrupted", "error": None}})
                return True
            decision = (payload["message"].get("result") or {}).get("decision")
            record_approval(
                thread_id, "approval",
                {"decision": decision, "idType": payload["idType"]}
            )
            notify("serverRequest/resolved", {"threadId": thread_id, "requestId": server_req})
            accepted = isinstance(decision, str) and decision.startswith("accept")
            item_done = dict(item, status="completed" if accepted else "declined")
            if not accepted:
                item_done["aggregatedOutput"] = "declined by user"
            notify("item/completed", dict(base, item=item_done))

        # Real Codex 0.144 MCP write approval shape: an mcpToolCall item plus an
        # mcpServer/elicitation/request whose response uses `action`, not the
        # command/file approval `decision` field.
        if "mcpApproval" in cfg:
            approval = cfg["mcpApproval"] or {}
            server = approval.get("server", "rubien")
            tool = approval.get("tool", "rubien_create_reference")
            item = {
                "type": "mcpToolCall",
                "id": "mcp_FAKE",
                "server": server,
                "tool": tool,
                "status": "inProgress",
                "arguments": approval.get("arguments", {"title": "Approval Capture"}),
            }
            notify("item/started", dict(base, item=item))
            req = {
                "threadId": thread_id,
                "turnId": turn_id,
                "serverName": server,
                "mode": "form",
                "_meta": {
                    "codex_approval_kind": "mcp_tool_call",
                    "tool_params": item["arguments"],
                },
                "message": f'Allow the {server} MCP server to run tool "{tool}"?',
                "requestedSchema": {"type": "object", "properties": {}},
            }
            server_req = self.next_server_request("mcpServer/elicitation/request", req)
            kind, payload = self.wait_for_response(server_req, interrupt_event)
            if kind == "eof":
                return False
            if kind == "interrupted":
                notify("turn/completed", {"threadId": thread_id, "turn": {"id": turn_id, "status": "interrupted", "error": None}})
                return True
            action = (payload["message"].get("result") or {}).get("action")
            record_approval(
                thread_id, "mcpApproval",
                {"action": action, "idType": payload["idType"]}
            )
            notify("serverRequest/resolved", {"threadId": thread_id, "requestId": server_req})
            accepted = action == "accept"
            mutation = approval.get("mutation")
            if accepted and mutation:
                mutation_env = os.environ.copy()
                mutation_env.update(mutation.get("environment", {}))
                completed = subprocess.run(
                    [mutation["executable"], *mutation.get("arguments", [])],
                    env=mutation_env,
                    stdin=subprocess.DEVNULL,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                record(mcpMutation={"exitCode": completed.returncode})
            item_done = dict(item, status="completed" if accepted else "failed")
            if not accepted:
                item_done["error"] = {"message": "user rejected MCP tool call"}
            notify("item/completed", dict(base, item=item_done))

        # An unsupported server request the client must still answer (no wedge).
        if cfg.get("unknownRequest"):
            server_req = self.next_server_request("mock/experimentalThing", {"threadId": thread_id})
            kind, payload = self.wait_for_response(server_req, interrupt_event)
            if kind == "eof":
                return False
            if kind == "response":
                record(unknownResponse={"idType": payload["idType"],
                                        "hadError": "error" in payload["message"]})

        for delta in cfg.get("deltas", ["Hel", "lo"]):
            delta = delta.replace("{threadId}", thread_id)
            delta = delta.replace("{turnId}", turn_id)
            notify("item/agentMessage/delta", dict(base, itemId="msg_1", delta=delta))

        if cfg.get("hang"):
            # No completion — wait for turn/interrupt (the stop path), then finish
            # the turn as interrupted. The SERVER keeps running afterwards.
            while not self.shutdown_event.is_set():
                if interrupt_event.wait(timeout=0.05):
                    notify("turn/completed", {"threadId": thread_id, "turn": {"id": turn_id, "status": "interrupted", "error": None}})
                    return True
            return False

        if cfg.get("completionDelayMs"):
            interrupted = interrupt_event.wait(
                timeout=int(cfg["completionDelayMs"]) / 1000.0
            )
            if interrupted:
                notify("turn/completed", {"threadId": thread_id, "turn": {"id": turn_id, "status": "interrupted", "error": None}})
                return True

        text = cfg.get("assistantText", "Hello")
        text = text.replace("{threadStarts}", str(OBSERVED["threadStarts"]))
        text = text.replace("{threadId}", thread_id)
        text = text.replace("{turnId}", turn_id)
        notify("item/completed", dict(base, item={"type": "agentMessage", "id": "msg_1", "text": text}))
        usage = cfg.get("usageLast", {"inputTokens": 100, "outputTokens": 5, "cachedInputTokens": 20})
        notify("thread/tokenUsage/updated", dict(base, tokenUsage={"total": {"inputTokens": 999999}, "last": usage}))
        notify("turn/completed", {"threadId": thread_id, "turn": {"id": turn_id, "status": "completed", "error": None}})
        return True

    def serve(self):
        while True:
            msg = read_message()
            if msg is None:
                self.shutdown_event.set()
                with self.state_lock:
                    for event in self.turn_interrupts.values():
                        event.set()
                return 0
            method = msg.get("method")
            req_id = msg.get("id")
            if method is None and req_id is not None:
                with self.state_lock:
                    waiter = self.response_waiters.get(req_id)
                if waiter is not None:
                    try:
                        waiter.put_nowait(msg)
                    except queue.Full:
                        pass
            elif method == "initialize":
                cfg = load_config()
                if cfg.get("grandchild"):
                    spawn_grandchild()
                if cfg.get("initDelayOnceMs"):
                    try:
                        descriptor = os.open(
                            ".fake-codex-init-delayed",
                            os.O_CREAT | os.O_EXCL | os.O_WRONLY,
                        )
                        os.close(descriptor)
                        time.sleep(int(cfg["initDelayOnceMs"]) / 1000.0)
                    except FileExistsError:
                        pass
                if cfg.get("initDelayMs"):
                    time.sleep(int(cfg["initDelayMs"]) / 1000.0)
                respond(req_id, {"userAgent": "fake-codex/0.142.5", "codexHome": os.path.expanduser("~/.codex"),
                                 "platformFamily": "unix", "platformOs": "macos"})
            elif method == "initialized":
                self.seen_initialized = True
                record(initialized=True)
            elif method == "thread/start":
                if not self.seen_initialized:
                    # A thread request BEFORE the initialized handshake completed is a
                    # protocol violation — the handshake gate must prevent it (review #1).
                    record(protocolViolation="thread/start before initialized")
                with self.state_lock:
                    self.thread_seq += 1
                    thread_id = f"TH-{self.thread_seq}"
                    cwd = (msg.get("params") or {}).get("cwd")
                    if cwd:
                        self.thread_workspaces[thread_id] = cwd
                increment_observed(
                    "threadStarts",
                    lastThreadStartParams=msg.get("params", {})
                )
                respond(req_id, {"thread": {"id": thread_id, "preview": ""}, "model": "gpt-5.5-fake"})
                notify("thread/started", {"thread": {"id": thread_id}})
            elif method == "thread/resume":
                resumed = (msg.get("params") or {}).get("threadId", self.thread_id)
                with self.state_lock:
                    self.thread_workspaces.setdefault(resumed, os.getcwd())
                increment_observed("threadResumes")
                respond(req_id, {"thread": {"id": resumed, "preview": ""}, "model": "gpt-5.5-fake"})
                notify("thread/started", {"thread": {"id": resumed}})
            elif method == "turn/start":
                threading.Thread(
                    target=self.run_turn,
                    args=(req_id, msg.get("params") or {}),
                    daemon=True,
                ).start()
            elif method == "turn/interrupt":
                params = msg.get("params") or {}
                with self.state_lock:
                    interrupt_event = self.turn_interrupts.get(
                        params.get("turnId")
                    )
                if interrupt_event is not None:
                    interrupt_event.set()
                increment_observed("interrupts")
                respond(req_id, {})
            elif method == "thread/list":
                # History recents (3b-4). `data[]` of thread summaries; the real server
                # pre-sorts newest-first. Params recorded so tests assert cwd/sourceKinds.
                cfg = load_config()
                record(threadListParams=msg.get("params", {}))
                respond(req_id, {"data": cfg.get("threads", [
                    {"id": "TH-A", "preview": "First conversation", "updatedAt": 1700000200},
                    {"id": "TH-B", "preview": "Second conversation", "updatedAt": 1700000100},
                ])})
            elif method == "thread/search":
                # History search (3b-4). Each `data[]` hit wraps the thread + a `snippet`.
                # Codex search is GLOBAL — the provider filters hits by thread.cwd, so
                # the default hit's cwd echoes the REQUESTED cwd (== the workspace the
                # provider passed), representing an in-workspace hit.
                params = msg.get("params", {})
                cfg = load_config()
                record(threadSearchParams=params)
                respond(req_id, {"data": cfg.get("searchHits", [
                    {"thread": {"id": "TH-9", "preview": "Matched conversation",
                                "updatedAt": 1700000150, "cwd": params.get("cwd")},
                     "snippet": "…the matching   text…"},
                ])})
            elif method == "thread/read":
                # History transcript preview (3b-4) + the scoped-filter reads: a
                # per-thread `transcripts[threadId]` wins over the single global
                # `transcript`, and every read's threadId is appended for assertions.
                cfg = load_config()
                params = msg.get("params", {})
                record(threadReadParams=params,
                       threadReadIds=OBSERVED.get("threadReadIds", []) + [params.get("threadId")])
                delay_once_ms = cfg.get("threadReadDelayOnceMs")
                if delay_once_ms:
                    sentinel = ".fake-codex-thread-read-delayed"
                    try:
                        fd = os.open(sentinel, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                        os.close(fd)
                        time.sleep(int(delay_once_ms) / 1000.0)
                    except FileExistsError:
                        pass
                # `is None`, not `or`: an explicitly configured EMPTY per-thread
                # transcript ({}) must be served, not swallowed by falsiness.
                thread = cfg.get("transcripts", {}).get(params.get("threadId"))
                if thread is None:
                    thread = cfg.get("transcript", {"turns": [
                        {"items": [
                            {"type": "userMessage", "content": [{"type": "text", "text": "Question?"}]},
                            {"type": "reasoning", "text": "thinking (should be dropped)"},
                            {"type": "agentMessage", "text": "The answer."},
                            {"type": "fileChange", "status": "completed", "changes": []},
                        ]},
                    ]})
                respond(req_id, {"thread": thread})
            elif method == "model/list":
                # Model auto-discovery. Config `models` overrides the default set;
                # `modelListError: true` answers with a JSON-RPC error (old-codex /
                # failure path); `modelListDelayMs` delays the response (in-flight
                # race tests). Request count recorded for memoization assertions.
                cfg = load_config()
                record(modelListRequests=OBSERVED.get("modelListRequests", 0) + 1)
                if cfg.get("modelListDelayMs"):
                    time.sleep(int(cfg["modelListDelayMs"]) / 1000.0)
                if cfg.get("modelListError"):
                    emit({"jsonrpc": "2.0", "id": req_id,
                          "error": {"code": -32601, "message": "Method not found"}})
                else:
                    respond(req_id, {"data": cfg.get("models", [
                        {"id": "fake-default", "displayName": "Fake Default", "hidden": False,
                         "isDefault": True, "defaultReasoningEffort": "medium",
                         "description": "The fake default model.",
                         "supportedReasoningEfforts": [
                             {"reasoningEffort": "low", "description": "Fast"},
                             {"reasoningEffort": "medium", "description": "Balanced"},
                             {"reasoningEffort": "high", "description": "Deep"},
                         ]},
                        {"id": "fake-frontier", "displayName": "Fake Frontier", "hidden": False,
                         "isDefault": False, "defaultReasoningEffort": "low",
                         "supportedReasoningEfforts": [
                             {"reasoningEffort": "low", "description": "Fast"},
                             {"reasoningEffort": "max", "description": "Maximum"},
                             {"reasoningEffort": "ultra", "description": "Delegating"},
                         ]},
                        {"id": "fake-hidden", "displayName": "Fake Hidden", "hidden": True,
                         "isDefault": False},
                    ])})
            elif req_id is not None:
                respond(req_id, {})


def main():
    if "--version" in sys.argv:
        sys.stdout.write("0.142.5-fake (codex-cli)\n")
        sys.stdout.flush()
        return 0
    if len(sys.argv) >= 3 and sys.argv[1:3] == ["login", "status"]:
        sys.stdout.write("Logged in using ChatGPT\n")
        sys.stdout.flush()
        return 0
    if len(sys.argv) >= 4 and sys.argv[-3:] == ["mcp", "list", "--json"]:
        cfg = load_config()
        if cfg.get("mcpListDelayMs"):
            time.sleep(int(cfg["mcpListDelayMs"]) / 1000.0)
        sys.stdout.write(json.dumps(cfg.get("mcpServers", [])) + "\n")
        sys.stdout.flush()
        return 0
    try:
        _atomic_write_json("fake-codex-argv.json", sys.argv)
    except OSError:
        pass
    _seed_model_list_requests()
    record(pid=os.getpid())
    return Server().serve() or 0


if __name__ == "__main__":
    sys.exit(main())
