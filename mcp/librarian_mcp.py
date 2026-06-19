#!/usr/bin/env python3
"""
librarian_mcp.py — MCP server exposing the repository librarian over STDIO.

Zero-dependency: speaks MCP over stdio (newline-delimited JSON-RPC 2.0). Tool
logic lives in librarian_core.py (shared with the HTTP transport). Register:

    claude mcp add --scope user librarian -- python3 /ABS/PATH/utils/librarian_mcp.py

All diagnostics go to stderr; stdout carries ONLY JSON-RPC messages.
"""

import sys
import json
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import librarian_core as core  # noqa: E402

DISPATCH = {
    "ask_librarian": lambda a: core.ask_librarian(a.get("question"), a.get("repos"), a.get("project")),
    "list_repositories": lambda a: core.list_repositories(),
    "read_project_map": lambda a: core.read_project_map(a.get("project")),
    "read_repo_map": lambda a: core.read_repo_map(a.get("repo")),
    "read_repo_history": lambda a: core.read_repo_history(a.get("repo")),
    "read_connections": lambda a: core.read_connections(),
    "search_code": lambda a: core.search_code(a.get("pattern"), a.get("repos")),
}


def log(msg):
    print(f"[librarian-mcp] {msg}", file=sys.stderr, flush=True)


def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def handle(req):
    method = req.get("method")
    rid = req.get("id")

    if method == "initialize":
        params = req.get("params") or {}
        return {"jsonrpc": "2.0", "id": rid, "result": {
            "protocolVersion": params.get("protocolVersion", "2024-11-05"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "librarian", "version": "0.2.0"},
        }}

    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": rid, "result": {"tools": core.TOOLS}}

    if method == "tools/call":
        params = req.get("params") or {}
        name = params.get("name")
        args = params.get("arguments") or {}
        fn = DISPATCH.get(name)
        if not fn:
            return {"jsonrpc": "2.0", "id": rid,
                    "error": {"code": -32602, "message": f"unknown tool: {name}"}}
        try:
            text = fn(args)
        except Exception as e:  # never crash the server on a tool error
            text = f"error: {e}"
        is_err = isinstance(text, str) and text.startswith("error:")
        return {"jsonrpc": "2.0", "id": rid,
                "result": {"content": [{"type": "text", "text": text}], "isError": is_err}}

    if method == "ping":
        return {"jsonrpc": "2.0", "id": rid, "result": {}}

    if rid is None:  # notification — no response
        return None
    return {"jsonrpc": "2.0", "id": rid,
            "error": {"code": -32601, "message": f"method not found: {method}"}}


def main():
    log(f"started; mirror={core.REPOS_DIR}")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            log("skipping non-JSON line")
            continue
        resp = handle(req)
        if resp is not None:
            send(resp)
    log("stdin closed, exiting")


if __name__ == "__main__":
    main()
