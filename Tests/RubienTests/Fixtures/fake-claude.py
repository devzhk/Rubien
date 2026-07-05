#!/usr/bin/env python3
"""A fake `claude` CLI that speaks the stream-json + control protocol, for driving
`ClaudeCodeProviderTests` end-to-end WITHOUT the real binary (or a network/login).

Behavior is configured per-test by a `fake-claude.json` file in the process cwd (the
provider sets cwd = the turn's workspace, so the test writes the config there). It:

  * answers `--version` (for `isAvailable()`),
  * waits for the `user` message on stdin (proves prompt delivery),
  * emits `system/init`, text `stream_event` deltas, a truncated line, an `assistant`
    message,
  * optionally emits a `can_use_tool` control_request and BLOCKS until the matching
    `control_response` arrives on stdin (the approval round-trip),
  * optionally floods stderr (backpressure), spawns a grandchild in the same process
    group (process-tree kill), hangs (cancel), exits non-zero (error path),
  * emits a `result` carrying a ROTATED session id.

Config keys (all optional): sessionInit, sessionResult, deltas[], assistantText,
approval{requestId,toolName,input,toolUseId,description}, afterApprovalText,
floodStderr(int bytes), partialLine(bool), grandchild(bool), hang(bool),
exitCode(int), emitResult(bool), delayExitMs(int).
"""
import sys
import os
import json
import time
import threading
import subprocess


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def main():
    if "--version" in sys.argv:
        sys.stdout.write("9.9.9-fake (Claude Code)\n")
        sys.stdout.flush()
        return 0

    # Record the exact argv this turn was spawned with, so tests can assert the
    # flags the provider passed (e.g. the Phase-2b --mcp-config / --strict-mcp-config
    # content-channel wiring). Written into cwd (= the turn's workspace).
    try:
        with open("fake-claude-argv.json", "w") as argv_handle:
            json.dump(sys.argv, argv_handle)
    except OSError:
        pass

    cfg = {}
    try:
        with open("fake-claude.json") as handle:
            cfg = json.load(handle)
    except Exception:
        cfg = {}

    session_init = cfg.get("sessionInit", "fake-session-init")
    session_result = cfg.get("sessionResult", "fake-session-rotated")
    deltas = cfg.get("deltas", ["Hello"])
    assistant_text = cfg.get("assistantText", "".join(deltas))
    approval = cfg.get("approval")
    after_text = cfg.get("afterApprovalText", "Done.")
    flood = int(cfg.get("floodStderr", 0))
    partial_line = cfg.get("partialLine", True)
    grandchild = cfg.get("grandchild", False)
    hang = cfg.get("hang", False)
    exit_code = int(cfg.get("exitCode", 0))
    emit_result = cfg.get("emitResult", True)
    delay_exit_ms = int(cfg.get("delayExitMs", 0))
    stderr_message = cfg.get("stderrMessage")

    user_received = threading.Event()
    approval_resolved = threading.Event()
    approval_behavior = {"value": None}

    def read_stdin():
        while True:
            line = sys.stdin.readline()
            if not line:  # EOF (provider closed stdin)
                break
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            kind = obj.get("type")
            if kind == "user":
                user_received.set()
            elif kind == "control_response":
                inner = (obj.get("response") or {}).get("response") or {}
                approval_behavior["value"] = inner.get("behavior")
                approval_resolved.set()

    threading.Thread(target=read_stdin, daemon=True).start()

    # Prove the provider delivered the prompt on stdin (bounded so a broken test
    # can't wedge the harness forever).
    user_received.wait(timeout=10)

    emit({
        "type": "system", "subtype": "init", "session_id": session_init,
        "cwd": os.getcwd(), "tools": ["Read", "Write", "Bash"], "mcp_servers": [],
        "model": "claude-fake", "apiKeySource": "none", "claude_code_version": "9.9.9-fake",
    })

    for chunk in deltas:
        emit({
            "type": "stream_event",
            "event": {"type": "content_block_delta", "index": 0,
                      "delta": {"type": "text_delta", "text": chunk}},
            "session_id": session_init,
        })

    if partial_line:
        # A truncated line the tolerant parser must drop (never throw).
        sys.stdout.write('{"type":"assistant","message":{"content":[{"type":"tex\n')
        sys.stdout.flush()

    emit({
        "type": "assistant",
        "message": {"role": "assistant", "id": "msg_fake_1", "type": "message",
                    "model": "claude-fake",
                    "content": [{"type": "text", "text": assistant_text}],
                    "stop_reason": "end_turn"},
        "parent_tool_use_id": None, "session_id": session_init,
    })

    if grandchild:
        # A child that inherits our process group (Popen default) and stays alive —
        # `killpg` on cancel must reap it. It records its own pid and does NOT hold
        # our stdout pipe (redirected to /dev/null) so the happy path can EOF.
        code = ("import os, time\n"
                "open('grandchild.pid', 'w').write(str(os.getpid()))\n"
                "time.sleep(300)\n")
        devnull = open(os.devnull, "w")
        subprocess.Popen([sys.executable, "-c", code],
                         stdout=devnull, stderr=devnull, stdin=subprocess.DEVNULL)

    if approval:
        emit({
            "type": "control_request",
            "request_id": approval.get("requestId", "req-1"),
            "request": {
                "subtype": "can_use_tool",
                "tool_name": approval.get("toolName", "Write"),
                "display_name": approval.get("toolName", "Write"),
                "input": approval.get("input", {"file_path": "out.txt", "content": "x"}),
                "description": approval.get("description", "out.txt"),
                "tool_use_id": approval.get("toolUseId", "toolu_appr_1"),
            },
        })
        approval_resolved.wait(timeout=10)
        if approval_behavior["value"] == "allow":
            emit({
                "type": "assistant",
                "message": {"role": "assistant", "content": [{"type": "text", "text": after_text}]},
                "session_id": session_init,
            })

    if flood > 0:
        blob = "E" * 1024 + "\n"
        written = 0
        while written < flood:
            sys.stderr.write(blob)
            written += len(blob)
        sys.stderr.flush()

    if hang:
        # Wait to be killed (cancel test). The whole process group dies on killpg.
        while True:
            time.sleep(1)

    if emit_result:
        denials = []
        if approval and approval_behavior["value"] == "deny":
            denials = [{
                "tool_name": approval.get("toolName", "Write"),
                "tool_use_id": approval.get("toolUseId", "toolu_appr_1"),
                "tool_input": approval.get("input", {}),
            }]
        emit({
            "type": "result", "subtype": "success", "is_error": False,
            "session_id": session_result, "result": assistant_text, "total_cost_usd": 0.0123,
            "usage": {"input_tokens": 11, "output_tokens": 7,
                      "cache_read_input_tokens": 200, "cache_creation_input_tokens": 15},
            "permission_denials": denials,
        })

    if stderr_message:
        # Final error bytes written just before exit — the provider's failure path
        # must wait for the stderr drain's EOF before reading this (A5).
        sys.stderr.write(stderr_message + "\n")
        sys.stderr.flush()

    if delay_exit_ms > 0:
        time.sleep(delay_exit_ms / 1000.0)

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
