#!/usr/bin/env python3
"""
librarian_core.py — shared tool logic for the librarian, transport-agnostic.

Imported by both transports:
  - librarian_mcp.py   (stdio, zero-dependency, for local use)
  - librarian_http.py  (Streamable HTTP + bearer token, for VM deployment)

Every call is appended to librarian.log (one line: time, tool, status, duration,
detail) so you can `tail -f librarian.log` to watch all traffic — the same
observability whether the server runs locally or on a VM.
"""

import os
import re
import json
import shutil
import threading
import subprocess
from datetime import datetime
from pathlib import Path


def _find_root(start):
    """Locate the project root (where CLAUDE.md / .repositories live), so this
    works whether the server file sits at the root or in a subdir like utils/."""
    d = start
    for _ in range(6):
        if (d / "CLAUDE.md").exists() or (d / ".repositories").is_dir():
            return d
        if d.parent == d:
            break
        d = d.parent
    return start


ROOT_DIR = _find_root(Path(__file__).resolve().parent)
REPOS_DIR = ROOT_DIR / ".repositories"
KNOW_DIR = ROOT_DIR / ".knowledge"            # curated maps, built by utils/digest.sh
LOG_DIR = ROOT_DIR / ".logs"
LOG_FILE = LOG_DIR / "librarian.log"          # concise one-line-per-call audit
FEED_FILE = LOG_DIR / "librarian-feed.log"    # live trace of Claude's steps (tail -f in tmux)

def _config(key, default):
    """Resolve a librarian setting, shared with the shell scripts via the repo's
    librarian.conf. Order: an env var of the same name wins, else the value in
    librarian.conf (shell `: "${KEY:=value}"` or `KEY=value`, comments skipped),
    else `default`. So one edit in librarian.conf applies to shell and Python alike.
    """
    val = os.environ.get(key)
    if val:
        return val
    conf = ROOT_DIR / "librarian.conf"
    if conf.exists():
        pat = re.compile(re.escape(key) + r':?=["\']?([^"\'}\s]+)')
        for line in conf.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):    # skip blanks and comments
                continue
            m = pat.search(line)
            if m:
                return m.group(1)
    return default


def _config_int(key, default):
    """_config() coerced to int, falling back to the default on a bad value."""
    try:
        return int(_config(key, str(default)))
    except ValueError:
        return default


AGENT = _config("LIBRARIAN_AGENT", "agy")           # CLI agent, defaults to agy
MODEL = _config("LIBRARIAN_MODEL", "sonnet")        # passed to `--model`
ALLOWED_TOOLS = "Read,Grep,Glob,Bash(git log:*),Bash(git show:*),Bash(git blame:*)"
ASK_TIMEOUT = _config_int("LIBRARIAN_ASK_TIMEOUT", 300)   # seconds for a librarian query
SEARCH_CAP = _config_int("LIBRARIAN_SEARCH_CAP", 50)      # max grep matches returned
LINE_CAP = _config_int("LIBRARIAN_LINE_CAP", 300)         # max chars per match line
MAX_LOG_BYTES = 10 * 1024 * 1024   # cap each log file at 10 MB, keep one rollover


def _rotate_if_big(path):
    """Roll a log over to <name>.1 once it hits the size cap, so the active
    file never exceeds MAX_LOG_BYTES. Best-effort; tolerant of concurrent writers."""
    try:
        if path.exists() and path.stat().st_size >= MAX_LOG_BYTES:
            path.replace(path.with_name(path.name + ".1"))
    except Exception:
        pass


def _log(tool, status, dur, detail=""):
    """Append one observability line. Best-effort — never breaks a call."""
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        _rotate_if_big(LOG_FILE)
        ts = datetime.now().astimezone().isoformat(timespec="seconds")
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(f"{ts}\t{tool}\t{status}\t{dur:.1f}s\t{detail}\n")
    except Exception:
        pass


def _now():
    return datetime.now().timestamp()


# --- live feed: render Claude's streamed steps for the tmux watcher ----------

def _feed(line):
    """Append a line to the live feed (watched via `tail -f` in tmux)."""
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        _rotate_if_big(FEED_FILE)
        with open(FEED_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def _brief(inp, limit=160):
    """One-line summary of a tool_use input."""
    if isinstance(inp, dict):
        parts = []
        for k, v in inp.items():
            vs = str(v).replace("\n", " ")
            if len(vs) > 60:
                vs = vs[:60] + "…"
            parts.append(f"{k}={vs}")
        s = ", ".join(parts)
    else:
        s = str(inp)
    return s[:limit] + ("…" if len(s) > limit else "")


def _preview(content, limit=120):
    """Short preview of a tool_result's content."""
    if isinstance(content, list):
        s = " ".join(b.get("text", "") for b in content
                     if isinstance(b, dict) and b.get("type") == "text")
    else:
        s = str(content)
    s = s.replace("\n", " ").strip()
    return (s[:limit] + "…") if len(s) > limit else s


def _render_event(evt):
    """Turn one stream-json event into a readable feed line (or None to skip)."""
    t = evt.get("type")
    if t == "assistant":
        out = []
        for block in evt.get("message", {}).get("content", []):
            bt = block.get("type")
            if bt == "text":
                txt = block.get("text", "").strip()
                if txt:
                    out.append("  " + txt)
            elif bt == "tool_use":
                out.append(f"  → {block.get('name')}({_brief(block.get('input', {}))})")
        return "\n".join(out) if out else None
    if t == "user":
        for block in evt.get("message", {}).get("content", []):
            if block.get("type") == "tool_result":
                return f"    ✓ {_preview(block.get('content', ''))}"
    return None


# --- knowledge base helpers --------------------------------------------------

def _map_path(repo):
    """Path to a repo's curated map, or None if the name is unsafe/absent."""
    repo = (repo or "").strip().strip("/")
    if not repo or "/" in repo or repo.startswith("."):
        return None
    return KNOW_DIR / repo / "index.md"


def _map_summary(repo):
    """The one-line `summary:` from a repo's map frontmatter, or '' if none."""
    p = _map_path(repo)
    if not p or not p.is_file():
        return ""
    try:
        lines = p.read_text(encoding="utf-8").splitlines()
    except Exception:
        return ""
    if not lines or lines[0].strip() != "---":
        return ""
    for line in lines[1:]:           # scan only within the frontmatter block
        if line.strip() == "---":
            break
        if line.startswith("summary:"):
            return line[len("summary:"):].strip()
    return ""


def _project_of(name):
    """Project code = the prefix before the first '_' or '-' delimiter. Repos in
    the org share a high-level project code (e.g. acme_crawler-service and
    acme_harvest-agent both belong to 'acme'); the delimiter may be
    either '_' or '-', so we split on whichever comes first."""
    return re.split(r"[_-]", (name or "").strip(), maxsplit=1)[0]


def _mapped_repos():
    """Names of repos that have a curated map (a .knowledge/<repo>/index.md)."""
    if not KNOW_DIR.is_dir():
        return []
    return sorted(d.name for d in KNOW_DIR.iterdir()
                  if d.is_dir() and (d / "index.md").is_file())


def _projects():
    """Map of project code -> sorted member repo names, over mapped repos."""
    groups = {}
    for name in _mapped_repos():
        groups.setdefault(_project_of(name), []).append(name)
    for members in groups.values():
        members.sort()
    return groups


def _overview_path(project):
    """Path to a project's synthesized overview, or None if the name is unsafe."""
    project = (project or "").strip().strip("/")
    if not project or "/" in project or project.startswith("."):
        return None
    return KNOW_DIR / project / "overview.md"


# --- tools: each returns a text string --------------------------------------

def list_repositories():
    t0 = _now()
    if not REPOS_DIR.is_dir():
        _log("list_repositories", "error", _now() - t0, "no mirror dir")
        return "error: mirror directory .repositories/ not found."
    repos = sorted((p for p in REPOS_DIR.iterdir() if p.is_dir()), key=lambda p: p.name)
    if not repos:
        _log("list_repositories", "ok", _now() - t0, "empty")
        return "Mirror is empty — no repositories cloned yet."

    def describe(p):
        if (p / ".git").exists():
            try:
                h = subprocess.run(["git", "-C", str(p), "rev-parse", "--short", "HEAD"],
                                   capture_output=True, text=True, timeout=10).stdout.strip()
                d = subprocess.run(["git", "-C", str(p), "log", "-1", "--format=%cI"],
                                   capture_output=True, text=True, timeout=10).stdout.strip()
                head = f"{p.name}  @{h}  (last commit {d})"
            except Exception:
                head = f"{p.name}  (git info unavailable)"
        else:
            head = f"{p.name}  (not a git repo)"
        # Append the curated one-liner so callers can pick a repo without a query.
        summary = _map_summary(p.name)
        return f"  {head}\n      {summary}" if summary else f"  {head}"

    # Group by project code so a caller can scope a question to one family.
    groups = {}
    for p in repos:
        groups.setdefault(_project_of(p.name), []).append(p)

    blocks = []
    for proj in sorted(groups):
        members = groups[proj]
        has_overview = _overview_path(proj) and _overview_path(proj).is_file()
        tag = "  [project overview available]" if has_overview else ""
        body = "\n".join(describe(p) for p in members)
        blocks.append(f"project {proj}  ({len(members)} repo(s)){tag}\n{body}")

    mapped = sum(1 for p in repos if _map_summary(p.name))
    hint = ("" if mapped == len(repos)
            else f"\n\n({mapped}/{len(repos)} have a knowledge-base map; "
                 "run utils/digest.sh to build the rest.)")
    header = (f"{len(repos)} repositories across {len(groups)} project(s). Pass a "
              "project code to ask_librarian/read_project_map to scope a question.\n\n")
    _log("list_repositories", "ok", _now() - t0, f"{len(repos)} repos / {len(groups)} projects")
    return header + "\n\n".join(blocks) + hint


def read_repo_map(repo=None):
    """Return a curated knowledge-base map: the top-level index when no repo is
    named, or a single repo's map. Cheap — pre-distilled, no Claude turn."""
    t0 = _now()
    if not repo:
        idx = KNOW_DIR / "index.md"
        if not idx.is_file():
            _log("read_repo_map", "ok", _now() - t0, "no index")
            return ("No knowledge base yet — run utils/digest.sh (or the sync loop) "
                    "to build .knowledge/. Use list_repositories meanwhile.")
        _log("read_repo_map", "ok", _now() - t0, "index")
        return idx.read_text(encoding="utf-8")

    p = _map_path(repo)
    if p is None:
        _log("read_repo_map", "error", _now() - t0, f"bad name {repo!r}")
        return f"error: invalid repo name {repo!r}."
    if not p.is_file():
        names = sorted(d.name for d in KNOW_DIR.iterdir() if d.is_dir()) \
            if KNOW_DIR.is_dir() else []
        avail = (" Available maps: " + ", ".join(names)) if names else ""
        _log("read_repo_map", "ok", _now() - t0, f"no map {repo}")
        return (f"No map for '{repo}' yet (run utils/digest.sh to build it)."
                f"{avail}")
    _log("read_repo_map", "ok", _now() - t0, repo)
    return p.read_text(encoding="utf-8")


def read_project_map(project):
    """Return a project's synthesized overview: what the family of repos does, the
    role of each member, the end-to-end flow and shared contracts within the
    project. Cheap — pre-distilled, no Claude turn. The right FIRST read when a
    question is scoped to a project code."""
    t0 = _now()
    if not project:
        _log("read_project_map", "error", _now() - t0, "no project")
        return "error: 'project' is required (see list_repositories for project codes)."
    p = _overview_path(project)
    if p is None:
        _log("read_project_map", "error", _now() - t0, f"bad name {project!r}")
        return f"error: invalid project code {project!r}."
    members = _projects().get(project, [])
    if p.is_file():
        _log("read_project_map", "ok", _now() - t0, project)
        return p.read_text(encoding="utf-8")
    # No synthesized overview. A single-repo project IS its repo map; fall back.
    if len(members) == 1:
        _log("read_project_map", "ok", _now() - t0, f"{project} (single-repo fallback)")
        return (f"Project '{project}' is a single repository; see its map:\n\n"
                + read_repo_map(members[0]))
    if members:
        listing = "\n".join(f"  - {m}: {_map_summary(m) or '(no summary)'}" for m in members)
        _log("read_project_map", "ok", _now() - t0, f"{project} (no overview)")
        return (f"No synthesized overview for project '{project}' yet (run "
                f"utils/digest.sh to build it). Its {len(members)} member repos:\n"
                f"{listing}\n\nUse read_repo_map on any of these meanwhile.")
    avail = ", ".join(sorted(_projects())) or "(none)"
    _log("read_project_map", "ok", _now() - t0, f"no project {project}")
    return f"No project '{project}' in the knowledge base. Known projects: {avail}."


def read_repo_history(repo):
    """Return a repo's decision log: a reverse-chronological record, mined from
    git history, of what changed and why. Cheap — pre-distilled, no Claude turn."""
    t0 = _now()
    if not repo:
        _log("read_repo_history", "error", _now() - t0, "no repo")
        return "error: 'repo' is required (see list_repositories)."
    base = _map_path(repo)
    if base is None:
        _log("read_repo_history", "error", _now() - t0, f"bad name {repo!r}")
        return f"error: invalid repo name {repo!r}."
    p = base.with_name("decisions.md")
    if not p.is_file():
        _log("read_repo_history", "ok", _now() - t0, f"no log {repo}")
        return (f"No decision log for '{repo}' yet — it is appended as the sync loop "
                "picks up new commits (run utils/digest.sh to seed it now).")
    _log("read_repo_history", "ok", _now() - t0, repo)
    return p.read_text(encoding="utf-8")


def read_connections():
    """Return the cross-repo integration graph: who calls whom, shared contracts,
    and the end-to-end data flow across repos. Cheap — no Claude turn."""
    t0 = _now()
    p = KNOW_DIR / "connections.md"
    if not p.is_file():
        _log("read_connections", "ok", _now() - t0, "absent")
        return ("No cross-repo connections graph yet — it is built once at least two "
                "repos have maps (run utils/digest.sh). Use list_repositories meanwhile.")
    _log("read_connections", "ok", _now() - t0, "ok")
    return p.read_text(encoding="utf-8")


def search_code(pattern, repos=None):
    t0 = _now()
    pattern = (pattern or "").strip()
    if not pattern:
        return "error: 'pattern' is required."
    repos = repos or []
    if repos:
        targets = [str(REPOS_DIR / r) for r in repos if (REPOS_DIR / r).is_dir()]
        if not targets:
            _log("search_code", "error", _now() - t0, "bad repos")
            return "error: none of the named repos exist in the mirror."
    else:
        targets = [str(REPOS_DIR)]

    cmd = ["grep", "-rnI", "--exclude-dir=.git", "-e", pattern, "--"] + targets
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        _log("search_code", "timeout", _now() - t0, pattern[:80])
        return "error: search timed out."

    lines = res.stdout.splitlines()
    if not lines:
        _log("search_code", "ok", _now() - t0, f"0 matches: {pattern[:80]}")
        return f"No matches for: {pattern}"

    prefix = str(REPOS_DIR) + "/"
    shown = []
    for ln in lines[:SEARCH_CAP]:
        ln = ln.replace(prefix, "")
        if len(ln) > LINE_CAP:
            ln = ln[:LINE_CAP] + " …"
        shown.append(ln)
    note = ("" if len(lines) <= SEARCH_CAP
            else f"\n… {len(lines) - SEARCH_CAP} more (showing first {SEARCH_CAP})")
    _log("search_code", "ok", _now() - t0, f"{len(lines)} matches: {pattern[:80]}")
    return f"{len(lines)} match(es) for '{pattern}':\n" + "\n".join(shown) + note


def ask_librarian(question, repos=None, project=None):
    t0 = _now()
    question = (question or "").strip()
    if not question:
        return "error: 'question' is required."
    if not shutil.which(AGENT):
        _log("ask_librarian", "error", _now() - t0, f"no {AGENT} CLI")
        return f"error: the '{AGENT}' CLI is not on PATH."

    repos = repos or []
    project = (project or "").strip()

    # Build a context preamble. A project code is a soft scope hint: point the
    # sub-agent at that family's overview and members first, but don't forbid
    # reaching into other repos if the answer needs it. Explicit `repos` is a
    # harder limit.
    preamble = ""
    if project:
        members = _projects().get(project, [])
        scope = (f" Its member repos: {', '.join(members)}." if members else "")
        preamble += (
            f"The agent asking is working on the '{project}' project. Start from that "
            f"project's curated overview at .knowledge/{project}/overview.md, then its "
            f"member repos' maps under .knowledge/{project}_*/ — they are the most "
            f"likely place for the answer.{scope} Consult other repos only if the "
            f"answer clearly lies outside this project.\n\n")
    if repos:
        preamble += f"Limit your search to these repositories: {', '.join(repos)}.\n\n"
    prompt = f"{preamble}{question}" if preamble else question

    env = dict(os.environ)
    env.pop("ANTHROPIC_API_KEY", None)  # force subscription auth (no metered API)

    scope_label = f"project={project}" if project else f"repos={repos or 'all'}"
    detail = f"{scope_label} q={question[:120]!r}"
    ts = datetime.now().astimezone().isoformat(timespec="seconds")
    _feed(f"\n┌─ {ts}  ask_librarian  ({scope_label})")
    _feed(f"│  Q: {question}")

    # Stream Claude's real steps so a tmux watcher can see the work live, while
    # still capturing the final answer to return to the caller.
    cmd = [AGENT, "-p", prompt, "--model", MODEL, "--allowedTools", ALLOWED_TOOLS,
           "--verbose", "--output-format", "stream-json"]
    proc = subprocess.Popen(cmd, cwd=str(ROOT_DIR), env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, bufsize=1)
    timer = threading.Timer(ASK_TIMEOUT, proc.kill)
    timer.start()

    result_text = None
    assistant_texts = []
    try:
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                evt = json.loads(line)
            except json.JSONDecodeError:
                continue
            if evt.get("type") == "result":
                result_text = evt.get("result")
            elif evt.get("type") == "assistant":
                for b in evt.get("message", {}).get("content", []):
                    if b.get("type") == "text" and b.get("text", "").strip():
                        assistant_texts.append(b["text"].strip())
            rendered = _render_event(evt)
            if rendered:
                _feed(rendered)
        proc.wait()
    finally:
        timer.cancel()

    if proc.returncode and proc.returncode != 0:
        _feed("└─ FAILED")
        _log("ask_librarian", "fail", _now() - t0, detail)
        err = (proc.stderr.read() or "").strip()[:1000] if proc.stderr else ""
        return f"error: librarian query failed.\n{err}"

    answer = (result_text or "\n\n".join(assistant_texts)).strip()
    _feed(f"└─ done in {_now() - t0:.1f}s")
    _log("ask_librarian", "ok", _now() - t0, detail)
    return answer or "(no answer returned)"


# Tool metadata (used by the stdio server's hand-rolled tools/list).
TOOLS = [
    {
        "name": "ask_librarian",
        "description": (
            "Ask a natural-language question about the organization's repositories and get a "
            "synthesized answer with citations (repo/path/file:line). Use for explanations, an "
            "API/contract, how something works, or anything spanning repos. Costs a Claude turn; "
            "to just locate code, prefer search_code. If you know the project code you're working "
            "on (e.g. 'acme', 'globex'), pass it as `project` to scope and speed up the answer."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "question": {"type": "string", "description": "The question to answer."},
                "project": {"type": "string",
                            "description": "Optional project code (prefix shared by a family of repos, "
                                           "e.g. 'acme'). Points the librarian at that project's "
                                           "overview and member repos first. See list_repositories."},
                "repos": {"type": "array", "items": {"type": "string"},
                          "description": "Optional: hard-limit the search to these repo names (see list_repositories)."},
            },
            "required": ["question"],
        },
    },
    {
        "name": "list_repositories",
        "description": (
            "List the repositories in the mirror, GROUPED BY PROJECT CODE, each with its last "
            "commit and a one-line summary from its knowledge-base map. Cheap (no Claude turn). "
            "Use to discover the project codes and coverage, then read_project_map for a family "
            "or read_repo_map for one repo, then ask scoped with `project`."
        ),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "read_project_map",
        "description": (
            "Return a project's synthesized overview: what the family of repos does, each "
            "member's role, the end-to-end flow and shared contracts WITHIN the project, with "
            "repo/path:line pointers. Cheap (no Claude turn). Read this FIRST when a question is "
            "scoped to a project code (e.g. 'acme') — it orients across the whole family before "
            "you drill into one repo with read_repo_map."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "project": {"type": "string",
                            "description": "Project code (prefix shared by a family of repos; see list_repositories)."},
            },
            "required": ["project"],
        },
    },
    {
        "name": "read_repo_map",
        "description": (
            "Return a curated, pre-distilled map of the codebase: with no argument, the "
            "top-level index of all repos; with a repo name, that repo's overview — purpose, "
            "entry points, key components, APIs/contracts, where docs live, and gotchas, each "
            "with repo/path:line pointers. Cheap (no Claude turn). Read this FIRST to orient "
            "and locate the right files, then search_code/ask_librarian to dig in."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "repo": {"type": "string",
                         "description": "Optional repo name (see list_repositories). Omit for the top-level index."},
            },
        },
    },
    {
        "name": "read_repo_history",
        "description": (
            "Return a repo's decision log: a reverse-chronological, pre-distilled record of "
            "what changed and WHY, mined from its git history (newest first). Cheap (no Claude "
            "turn). Use for 'why does it work this way', 'when/why did X change', 'what changed "
            "recently' — questions about evolution and rationale, not current structure."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "repo": {"type": "string",
                         "description": "Repo name (see list_repositories)."},
            },
            "required": ["repo"],
        },
    },
    {
        "name": "read_connections",
        "description": (
            "Return the cross-repo integration graph: which repo calls/depends on which and "
            "how, the shared contracts/schemas (with repo/path:line), and the end-to-end data "
            "flow across the system. Cheap (no Claude turn). Use FIRST for any question that "
            "spans repos or asks how one service's output reaches another."
        ),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "search_code",
        "description": (
            "Raw grep across the mirrored repos. Returns matching repo/path:line locations with "
            "snippets (capped at 50). Cheap (no Claude turn). Use to find where something lives "
            "when you'll read it yourself; use ask_librarian for synthesis."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "pattern": {"type": "string", "description": "Text or basic-regex pattern."},
                "repos": {"type": "array", "items": {"type": "string"},
                          "description": "Optional: limit to these repo names."},
            },
            "required": ["pattern"],
        },
    },
]
