#!/usr/bin/env python3
"""
librarian_http.py — remote librarian MCP server over Streamable HTTP, secured
with a static bearer token. For deploying on a VM.

Tool logic is shared with the stdio server via librarian_core.py, so this gets
the same live feed (.logs/librarian-feed.log) and audit log.

Run:
    export LIBRARIAN_TOKEN="<long-random-secret>"
    python3 mcp/librarian_http.py            # binds 127.0.0.1:8008 by default
    # override: LIBRARIAN_HOST=0.0.0.0 LIBRARIAN_PORT=8008 python3 mcp/librarian_http.py

Register from a client:
    claude mcp add --transport http librarian https://HOST/mcp \
      --header "Authorization: Bearer <same-token>"

SECURITY:
  - Refuses to start without LIBRARIAN_TOKEN (fail closed).
  - A bearer token over plain HTTP travels in cleartext. Bind to 127.0.0.1 and
    put an HTTPS reverse proxy (Caddy/nginx) in front, or use an SSH tunnel/VPN.
"""

import os
import sys
import hmac
from pathlib import Path

import uvicorn
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

sys.path.insert(0, str(Path(__file__).resolve().parent))
import librarian_core as core  # noqa: E402

TOKEN = os.environ.get("LIBRARIAN_TOKEN", "").strip()
HOST = os.environ.get("LIBRARIAN_HOST", "127.0.0.1")
PORT = int(os.environ.get("LIBRARIAN_PORT", "8008"))

if not TOKEN:
    print("FATAL: set LIBRARIAN_TOKEN to a long random secret before starting.",
          file=sys.stderr)
    sys.exit(1)

# DNS-rebinding protection: FastMCP's Streamable HTTP app validates the incoming
# `Host` header against an allowlist and rejects anything not on it with HTTP 421
# ("Invalid Host header"). The default allowlist is localhost only, so the moment
# you front this server with a reverse proxy / tunnel (Cloudflare, nginx, …) every
# request arrives with the *public* hostname as Host and gets refused — the MCP
# client just sees the connection drop. List the public hostname(s) here.
#
# LIBRARIAN_ALLOWED_HOSTS: comma-separated Host values to allow, e.g.
#   "bgx-librarian.bikinrame.com" (a ":*" suffix wildcards the port).
# When unset we DISABLE the Host check: this server already authenticates every
# request with a bearer token (below), which a browser-driven DNS-rebinding attack
# cannot forge, so the Host allowlist is redundant here. Set it to re-enable.
_allowed = [h.strip() for h in
            os.environ.get("LIBRARIAN_ALLOWED_HOSTS", "").split(",") if h.strip()]
if _allowed:
    _security = TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=_allowed + [f"{h}:*" for h in _allowed],
        allowed_origins=[f"https://{h}" for h in _allowed]
        + [f"http://{h}" for h in _allowed],
    )
else:
    _security = TransportSecuritySettings(enable_dns_rebinding_protection=False)

# Response mode. FastMCP can answer a POST either as a Server-Sent-Events stream
# (`text/event-stream`, the default) or as a single plain `application/json` body.
# Streaming through a buffering proxy/CDN (Cloudflare, nginx) is fragile: the edge
# holds the open SSE stream, so the client never sees the response headers — most
# importantly `Mcp-Session-Id` — and the connection looks dead (a bare "-1"). JSON
# mode sidesteps that entirely: ordinary request/response, ordinary headers, no
# long-lived stream to buffer. We default it ON because this server is built to sit
# behind a reverse proxy/tunnel. Set LIBRARIAN_JSON_RESPONSE=0 to restore SSE.
JSON_RESPONSE = os.environ.get("LIBRARIAN_JSON_RESPONSE", "1").strip().lower() \
    not in ("0", "false", "no", "")

mcp = FastMCP("librarian", host=HOST, port=PORT, transport_security=_security,
              json_response=JSON_RESPONSE)


@mcp.tool()
def ask_librarian(question: str, project: str | None = None,
                  repos: list[str] | None = None) -> str:
    """Ask a natural-language question about the organization's repositories and get a
    synthesized answer with citations (repo/path/file:line). Use for explanations, an
    API/contract, how something works, or anything spanning repos. Costs a Claude turn;
    to just locate code, prefer search_code. If you know the project code you're working on
    (e.g. 'acme', 'globex'), pass it as `project` to scope and speed up the answer."""
    return core.ask_librarian(question, repos, project)


@mcp.tool()
def list_repositories() -> str:
    """List the repositories in the mirror, GROUPED BY PROJECT CODE, each with its last commit
    and a one-line summary from its knowledge-base map. Cheap (no Claude turn). Use to discover
    the project codes and coverage, then read_project_map for a family or read_repo_map for one
    repo, then ask scoped with `project`."""
    return core.list_repositories()


@mcp.tool()
def read_project_map(project: str) -> str:
    """Return a project's synthesized overview: what the family of repos does, each member's
    role, the end-to-end flow and shared contracts WITHIN the project, with repo/path:line
    pointers. Cheap (no Claude turn). Read this FIRST when a question is scoped to a project
    code (e.g. 'acme') — it orients across the whole family before you drill into one repo
    with read_repo_map."""
    return core.read_project_map(project)


@mcp.tool()
def read_repo_map(repo: str | None = None) -> str:
    """Return a curated, pre-distilled map of the codebase: with no argument, the top-level
    index of all repos; with a repo name, that repo's overview — purpose, entry points, key
    components, APIs/contracts, where docs live, and gotchas, each with repo/path:line
    pointers. Cheap (no Claude turn). Read this FIRST to orient and locate the right files,
    then search_code/ask_librarian to dig in."""
    return core.read_repo_map(repo)


@mcp.tool()
def read_repo_history(repo: str) -> str:
    """Return a repo's decision log: a reverse-chronological, pre-distilled record of what
    changed and WHY, mined from its git history (newest first). Cheap (no Claude turn). Use
    for 'why does it work this way', 'when/why did X change', 'what changed recently' —
    questions about evolution and rationale, not current structure."""
    return core.read_repo_history(repo)


@mcp.tool()
def read_connections() -> str:
    """Return the cross-repo integration graph: which repo calls/depends on which and how, the
    shared contracts/schemas (with repo/path:line), and the end-to-end data flow across the
    system. Cheap (no Claude turn). Use FIRST for any question that spans repos or asks how one
    service's output reaches another."""
    return core.read_connections()


@mcp.tool()
def search_code(pattern: str, repos: list[str] | None = None) -> str:
    """Raw grep across the mirrored repos. Returns matching repo/path:line locations with
    snippets (capped at 50). Cheap (no Claude turn). Use to find where something lives when
    you'll read it yourself; use ask_librarian for synthesis."""
    return core.search_code(pattern, repos)


class BearerAuthMiddleware(BaseHTTPMiddleware):
    """Reject any request without a matching `Authorization: Bearer <token>`."""

    def __init__(self, app, token):
        super().__init__(app)
        self._token = token

    async def dispatch(self, request, call_next):
        if request.url.path == "/healthz":
            return JSONResponse({"status": "ok"})
        auth = request.headers.get("authorization", "")
        presented = auth[7:] if auth.startswith("Bearer ") else ""
        if not presented or not hmac.compare_digest(presented, self._token):
            return JSONResponse({"error": "unauthorized"}, status_code=401)
        response = await call_next(request)
        response.headers["X-Accel-Buffering"] = "no"
        return response


app = mcp.streamable_http_app()
app.add_middleware(BearerAuthMiddleware, token=TOKEN)


if __name__ == "__main__":
    print(f"[librarian-http] serving MCP on http://{HOST}:{PORT}/mcp "
          f"(mirror={core.REPOS_DIR})", file=sys.stderr)
    uvicorn.run(app, host=HOST, port=PORT, log_level="warning")
