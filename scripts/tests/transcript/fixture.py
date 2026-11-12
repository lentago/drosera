#!/usr/bin/env python3
"""Write a worker's home tree for the transcript shipper test (#305).

    fixture.py write  <root>   create the tree, native session files and links
    fixture.py append <root>   append late lines (tailing through a symlink)

<root> is mounted at /home/claude in the Alloy container, so every path and
symlink target below is the path the container sees. Each line is stamped
with the current time, inside the shipper's 1-hour window, except the one
line that tests the window.

Every field the shipper must never send carries a LEAK- marker; check.py
fails if any marker reaches Loki. The lines that should ship are listed in
expected.json. Stdlib only.
"""
import json
import os
import sys
from datetime import datetime, timedelta, timezone

HOME = "/home/claude"

CLAUDE_SID = "c0ffee00-0000-4000-8000-000000000001"
GEMINI_SID = "9e0e0e00-0000-4000-8000-000000000002"
GEMINI_RUNID = "20261112T000000Z-transcript-gemini"
CODEX_SID = "0c0dec00-0000-4000-8000-000000000003"
CODEX_RUNID = "20261112T000000Z-transcript-codex"

GEMINI_NATIVE = f"{HOME}/.gemini/tmp/p1/chats/session-2026-11-12T00-00-9e0e0e00.jsonl"
GEMINI_LINK = f"{HOME}/.claytonia/live/gemini/p1/{GEMINI_RUNID}/{GEMINI_SID}.jsonl"
CODEX_NATIVE = f"{HOME}/.codex/sessions/2026/11/12/rollout-2026-11-12T00-00-00-{CODEX_SID}.jsonl"
CODEX_LINK = f"{HOME}/.claytonia/live/codex/adhoc/{CODEX_RUNID}/{CODEX_SID}.jsonl"


def now(offset_s=0):
    t = datetime.now(timezone.utc) + timedelta(seconds=offset_s)
    return t.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def host(root, path):
    return os.path.join(root, os.path.relpath(path, HOME))


def write_lines(root, path, lines, mode="w"):
    p = host(root, path)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, mode) as f:
        for line in lines:
            f.write(json.dumps(line) + "\n")


def link(root, target, path):
    p = host(root, path)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    os.symlink(target, p)


def claude_lines():
    return [
        {"type": "user", "timestamp": now(-30), "message": {"role": "user", "content": "LEAK-CLAUDE-PROMPT"}},
        {"type": "assistant", "timestamp": now(-29), "message": {"role": "assistant", "content": [
            {"type": "thinking", "thinking": "LEAK-CLAUDE-THINKING"},
            {"type": "text", "text": "Claude narration one"},
            {"type": "tool_use", "name": "Bash", "input": {"command": "LEAK-CLAUDE-TOOL-INPUT"}},
        ]}},
        {"type": "user", "timestamp": now(-28), "message": {"role": "user", "content": [
            {"type": "tool_result", "content": "LEAK-CLAUDE-TOOL-RESULT"}]}},
    ]


def gemini_lines():
    def msg(mid, ts, content="", tools=None):
        m = {"id": mid, "timestamp": ts, "type": "gemini", "content": content,
             "thoughts": [{"subject": "LEAK-GEMINI-THOUGHT", "description": "LEAK-GEMINI-THOUGHT", "timestamp": ts}],
             "tokens": {"input": 10, "output": 1, "cached": 0, "thoughts": 5, "tool": 0, "total": 16},
             "model": "gemini-3.8-flash"}
        if tools is not None:
            m["toolCalls"] = tools
        return m

    def call(name, status):
        return {"id": f"{name}-1", "name": name, "args": {"command": "LEAK-GEMINI-TOOL-ARGS"},
                "result": [{"functionResponse": {"response": {"output": "LEAK-GEMINI-TOOL-RESULT"}}}],
                "status": status, "timestamp": now(-20), "displayName": "LEAK-GEMINI-DISPLAY",
                "description": "LEAK-GEMINI-TOOL-DESC", "resultDisplay": "LEAK-GEMINI-RESULT-DISPLAY",
                "renderOutputAsMarkdown": True}

    return [
        {"sessionId": GEMINI_SID, "projectHash": "LEAK-GEMINI-HEADER", "startTime": now(-40),
         "lastUpdated": now(-40), "kind": "main"},
        {"id": "u1", "timestamp": now(-39), "type": "user", "content": "LEAK-GEMINI-USER"},
        {"id": "old", "timestamp": now(-7200), "type": "gemini", "content": "LEAK-GEMINI-OLDER-THAN-1H"},
        # A tool turn: written without toolCalls, then again once the call finishes.
        msg("g1", now(-38)),
        {"$set": {"lastUpdated": "LEAK-GEMINI-SET"}},
        msg("g1", now(-38), tools=[call("run_shell_command", "success")]),
        # Text and a tool call in one message: the text ships once, from the first write.
        msg("g2", now(-37), content="Gemini text before a tool"),
        msg("g2", now(-37), content="Gemini text before a tool", tools=[call("read_file", "success")]),
        # A call still executing ships nothing until its final write.
        msg("g3", now(-36), tools=[call("write_file", "executing")]),
        msg("g3", now(-36), tools=[call("write_file", "success")]),
        # Text beside a call still executing ships from that write; the final
        # write ships the tool name only.
        msg("g5", now(-35), content="Gemini text beside a running tool", tools=[call("list_directory", "executing")]),
        msg("g5", now(-35), content="Gemini text beside a running tool", tools=[call("list_directory", "success")]),
        {"id": "i1", "timestamp": now(-35), "type": "info", "content": "LEAK-GEMINI-INFO"},
    ]


def gemini_late():
    return [{"id": "g4", "timestamp": now(), "type": "gemini",
             "content": "Gemini late narration, token: LEAK-GEMINI-SECRET-VALUE",
             "thoughts": [], "tokens": {}, "model": "gemini-3.8-flash"}]


def codex_lines():
    def item(ts, payload, typ="response_item"):
        return {"timestamp": ts, "type": typ, "payload": payload}

    return [
        item(now(-40), {"id": CODEX_SID, "cwd": "/home/claude/work/adhoc",
                        "base_instructions": {"text": "LEAK-CODEX-BASE-INSTRUCTIONS"}}, "session_meta"),
        item(now(-39), {"model": "gpt-6.1-sol", "cwd": "/home/claude/work/adhoc",
                        "summary": "LEAK-CODEX-TURN-CONTEXT"}, "turn_context"),
        item(now(-39), {"full": "LEAK-CODEX-WORLD-STATE"}, "world_state"),
        item(now(-38), {"type": "message", "role": "developer",
                        "content": [{"type": "input_text", "text": "LEAK-CODEX-DEVELOPER"}]}),
        item(now(-38), {"type": "message", "role": "user",
                        "content": [{"type": "input_text", "text": "LEAK-CODEX-USER"}]}),
        item(now(-38), {"type": "user_message", "message": "LEAK-CODEX-USER-MESSAGE"}, "event_msg"),
        item(now(-37), {"type": "reasoning", "summary": [{"type": "summary_text", "text": "LEAK-CODEX-REASONING"}],
                        "encrypted_content": "LEAK-CODEX-ENCRYPTED"}),
        item(now(-36), {"type": "message", "role": "assistant", "phase": "commentary", "status": "completed",
                        "content": [{"type": "output_text", "text": "Codex narration one"}]}),
        item(now(-36), {"type": "item_completed", "item": {"type": "AgentMessage",
                        "content": [{"type": "Text", "text": "LEAK-CODEX-ITEM-AGENT-MESSAGE"}]}}, "event_msg"),
        item(now(-36), {"type": "agent_message", "message": "LEAK-CODEX-AGENT-MESSAGE-EVENT"}, "event_msg"),
        item(now(-35), {"type": "custom_tool_call", "name": "exec", "status": "completed",
                        "input": "LEAK-CODEX-TOOL-INPUT", "call_id": "c1"}),
        item(now(-35), {"type": "custom_tool_call_output", "call_id": "c1", "output": "LEAK-CODEX-TOOL-OUTPUT"}),
        item(now(-34), {"type": "item_completed", "item": {"type": "CommandExecution",
                        "command": "LEAK-CODEX-COMMAND", "aggregated_output": "LEAK-CODEX-COMMAND-OUTPUT"}},
             "event_msg"),
        item(now(-33), {"type": "function_call", "name": "apply_patch", "arguments": "LEAK-CODEX-FUNCTION-ARGS",
                        "call_id": "f1"}),
        item(now(-33), {"type": "function_call_output", "call_id": "f1", "output": "LEAK-CODEX-FUNCTION-OUTPUT"}),
        item(now(-32), {"type": "token_count", "info": "LEAK-CODEX-TOKEN-COUNT"}, "event_msg"),
        item(now(-32), {"usage": "LEAK-CODEX-TOKEN-USAGE"}, "token_usage_record"),
    ]


def codex_late():
    return [{"timestamp": now(), "type": "response_item",
             "payload": {"type": "message", "role": "assistant", "phase": "final_answer", "status": "completed",
                         "content": [{"type": "output_text", "text": "Codex final answer, password=LEAK-CODEX-SECRET-VALUE"}]}}]


def write(root):
    # Claude: the existing pipeline, unchanged, as a regression check.
    write_lines(root, f"{HOME}/.claude/projects/-home-claude-work-p1/{CLAUDE_SID}.jsonl", claude_lines())
    write_lines(root, f"{HOME}/.claude/projects/-home-claude-private-p2/{CLAUDE_SID[:-1]}9.jsonl",
                [{"type": "assistant", "timestamp": now(-20), "message": {"content": [
                    {"type": "text", "text": "LEAK-CLAUDE-PRIVATE-PROJECT"}]}}])
    # Gemini and Codex: native files, linked into the live prefix.
    write_lines(root, GEMINI_NATIVE, gemini_lines())
    link(root, GEMINI_NATIVE, GEMINI_LINK)
    write_lines(root, CODEX_NATIVE, codex_lines())
    link(root, CODEX_NATIVE, CODEX_LINK)
    # A private project's native files: no link, so they must never ship.
    write_lines(root, f"{HOME}/.gemini/tmp/p2/chats/session-2026-11-12T00-00-deadbeef.jsonl",
                [{"id": "x", "timestamp": now(-20), "type": "gemini", "content": "LEAK-GEMINI-PRIVATE-PROJECT"}])
    write_lines(root, f"{HOME}/.codex/sessions/2026/11/12/rollout-2026-11-12T00-00-00-private.jsonl",
                [{"timestamp": now(-20), "type": "response_item", "payload": {
                    "type": "message", "role": "assistant",
                    "content": [{"type": "output_text", "text": "LEAK-CODEX-PRIVATE-PROJECT"}]}}])


def append(root):
    write_lines(root, GEMINI_NATIVE, gemini_late(), mode="a")
    write_lines(root, CODEX_NATIVE, codex_late(), mode="a")


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("write", "append"):
        sys.exit(__doc__)
    {"write": write, "append": append}[sys.argv[1]](sys.argv[2])
