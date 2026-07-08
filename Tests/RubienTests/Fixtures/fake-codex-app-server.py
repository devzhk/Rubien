#!/usr/bin/env python3
"""A fake `codex app-server` speaking the v2 JSON-RPC thread/turn/item protocol, for
driving `CodexProviderTests` end-to-end WITHOUT the real binary (or a login).

Long-lived like the real server: ONE process handles the initialize handshake and
then any number of thread/turn requests. Behavior is configured per-TURN by a
`fake-codex.json` file in the process cwd (the provider sets cwd = the turn's
workspace; tests rewrite the file between sends). It:

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

Config keys (all optional): deltas[], assistantText (supports "{threadStarts}"),
usageLast{...}, approval{reason,command,availableDecisions[]}, unknownRequest(bool),
hang(bool), exitAfterTurnStart(int). History (3b-4): threads[] (thread/list data),
searchHits[] (thread/search data, each {thread,snippet}), transcript{turns:[…]}
(thread/read). All three also record their request params for assertion.
"""
import json
import os
import subprocess
import sys
import time

OBSERVED = {
    "pid": os.getpid(),
    "threadStarts": 0,
    "threadResumes": 0,
    "turnStarts": 0,
    "interrupts": 0,
}


def emit(obj):
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
    OBSERVED.update(kv)
    try:
        _atomic_write_json("fake-codex-observed.json", OBSERVED)
    except OSError:
        pass


def load_config():
    try:
        with open("fake-codex.json") as handle:
            return json.load(handle)
    except Exception:
        return {}


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
        self.turn_seq = 0
        self.server_req_seq = 0  # server-initiated request ids: 0, 1, 2… (real codex)
        self.seen_initialized = False

    def next_server_request(self, method, params):
        req_id = self.server_req_seq
        self.server_req_seq += 1
        emit({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params})
        return req_id

    def wait_for_response(self, req_id):
        """Read messages until the response to `req_id` arrives. Handles a
        `turn/interrupt` arriving mid-wait (returns ("interrupted", None))."""
        while True:
            msg = read_message()
            if msg is None:
                return ("eof", None)
            if msg.get("id") is not None and "method" not in msg:
                if msg["id"] == req_id:
                    id_type = "int" if isinstance(msg["id"], int) else "str"
                    return ("response", {"message": msg, "idType": id_type})
                continue  # a response to something else — ignore
            if msg.get("method") == "turn/interrupt":
                record(interrupts=OBSERVED["interrupts"] + 1)
                respond(msg["id"], {})
                return ("interrupted", None)
            # Other client requests mid-wait are unexpected; answer emptily.
            if msg.get("id") is not None:
                respond(msg["id"], {})

    def run_turn(self, req_id, params):
        cfg = load_config()
        self.turn_seq += 1
        turn_id = f"TU-{self.turn_seq}"
        record(turnStarts=OBSERVED["turnStarts"] + 1, lastTurnParams=params)
        respond(req_id, {"turn": {"id": turn_id, "status": "inProgress"}})
        thread_id = params.get("threadId", self.thread_id)
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
            sys.exit(int(cfg["exitAfterTurnStart"]))

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
                "reason": approval.get("reason", "Allow writing out.txt?"),
                "command": approval.get("command", "touch out.txt"),
                "availableDecisions": approval.get(
                    "availableDecisions", ["accept", "acceptForSession", "decline", "cancel"]
                ),
            }
            server_req = self.next_server_request("item/commandExecution/requestApproval", req)
            kind, payload = self.wait_for_response(server_req)
            if kind == "eof":
                return False
            if kind == "interrupted":
                notify("turn/completed", {"threadId": thread_id, "turn": {"id": turn_id, "status": "interrupted", "error": None}})
                return True
            decision = (payload["message"].get("result") or {}).get("decision")
            record(approval={"decision": decision, "idType": payload["idType"]})
            notify("serverRequest/resolved", {"threadId": thread_id, "requestId": server_req})
            accepted = isinstance(decision, str) and decision.startswith("accept")
            item_done = dict(item, status="completed" if accepted else "declined")
            if not accepted:
                item_done["aggregatedOutput"] = "declined by user"
            notify("item/completed", dict(base, item=item_done))

        # An unsupported server request the client must still answer (no wedge).
        if cfg.get("unknownRequest"):
            server_req = self.next_server_request("mock/experimentalThing", {"threadId": thread_id})
            kind, payload = self.wait_for_response(server_req)
            if kind == "eof":
                return False
            if kind == "response":
                record(unknownResponse={"idType": payload["idType"],
                                        "hadError": "error" in payload["message"]})

        for delta in cfg.get("deltas", ["Hel", "lo"]):
            notify("item/agentMessage/delta", dict(base, itemId="msg_1", delta=delta))

        if cfg.get("hang"):
            # No completion — wait for turn/interrupt (the stop path), then finish
            # the turn as interrupted. The SERVER keeps running afterwards.
            while True:
                msg = read_message()
                if msg is None:
                    return False
                if msg.get("method") == "turn/interrupt":
                    record(interrupts=OBSERVED["interrupts"] + 1)
                    respond(msg["id"], {})
                    notify("turn/completed", {"threadId": thread_id, "turn": {"id": turn_id, "status": "interrupted", "error": None}})
                    return True
                if msg.get("id") is not None and "method" in msg:
                    respond(msg["id"], {})

        text = cfg.get("assistantText", "Hello")
        text = text.replace("{threadStarts}", str(OBSERVED["threadStarts"]))
        notify("item/completed", dict(base, item={"type": "agentMessage", "id": "msg_1", "text": text}))
        usage = cfg.get("usageLast", {"inputTokens": 100, "outputTokens": 5, "cachedInputTokens": 20})
        notify("thread/tokenUsage/updated", dict(base, tokenUsage={"total": {"inputTokens": 999999}, "last": usage}))
        notify("turn/completed", {"threadId": thread_id, "turn": {"id": turn_id, "status": "completed", "error": None}})
        return True

    def serve(self):
        while True:
            msg = read_message()
            if msg is None:
                return 0
            method = msg.get("method")
            req_id = msg.get("id")
            if method == "initialize":
                cfg = load_config()
                if cfg.get("grandchild"):
                    spawn_grandchild()
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
                record(threadStarts=OBSERVED["threadStarts"] + 1, lastThreadStartParams=msg.get("params", {}))
                respond(req_id, {"thread": {"id": self.thread_id, "preview": ""}, "model": "gpt-5.5-fake"})
                notify("thread/started", {"thread": {"id": self.thread_id}})
            elif method == "thread/resume":
                resumed = (msg.get("params") or {}).get("threadId", self.thread_id)
                record(threadResumes=OBSERVED["threadResumes"] + 1)
                respond(req_id, {"thread": {"id": resumed, "preview": ""}, "model": "gpt-5.5-fake"})
                notify("thread/started", {"thread": {"id": resumed}})
            elif method == "turn/start":
                if not self.run_turn(req_id, msg.get("params") or {}):
                    return 0
            elif method == "turn/interrupt":
                # Stray interrupt outside a hanging turn: acknowledge it.
                record(interrupts=OBSERVED["interrupts"] + 1)
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
    try:
        _atomic_write_json("fake-codex-argv.json", sys.argv)
    except OSError:
        pass
    record(pid=os.getpid())
    return Server().serve() or 0


if __name__ == "__main__":
    sys.exit(main())
