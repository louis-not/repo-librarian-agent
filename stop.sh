#!/usr/bin/env bash
#
# stop.sh — stop ALL librarian background services and their workers.
#
# Kills the tmux sessions started by init.sh:
#   librarian           — bash sync daemon (loop.sh on an interval)
#   librarian-backfill  — cold-start knowledge build (Stage A/B/C)
#   librarian-http      — Streamable HTTP MCP server
#   librarian-feed      — the watch.sh live viewer
#
# Killing a tmux session kills the foreground shell in it, but the sync, backfill,
# and digest paths fan out into PARALLEL headless `claude -p` workers (and the MCP
# ask path spawns one per question). Those can outlive their parent shell, so after
# the sessions are down we reap any stray librarian `claude` workers too.
#
# The reap is scoped to print-mode (`claude -p`) processes whose working directory
# is THIS repo — so it never touches an interactive Claude session, not even one
# you have open in this same directory (interactive sessions don't run with -p).
#
# Safe to run anytime; idempotent.
#
#   bash stop.sh
#
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -f "$ROOT_DIR/librarian.conf" ] && . "$ROOT_DIR/librarian.conf"
AGENT="${LIBRARIAN_AGENT:-agy}"

SESSIONS=(librarian librarian-backfill librarian-http librarian-feed)

# --- 1. Stop the orchestrators first (so they can't spawn new workers) --------
stopped=0
for s in "${SESSIONS[@]}"; do
  if tmux has-session -t "=$s" 2>/dev/null; then
    tmux kill-session -t "=$s" 2>/dev/null && { echo "stopped  $s"; stopped=$((stopped + 1)); }
  else
    echo "skip     $s (not running)"
  fi
done

# --- 2. Reap stray librarian agent workers (backfill / digest / ask) ---------
# Orphaned `$AGENT -p` children survive their tmux pane; hand-run `bash utils/ask.sh`
# and MCP-spawned workers live outside tmux entirely. Scope by cwd (this repo) AND
# print-mode so an interactive Claude/Antigravity session in this directory is never touched.
reaped=0
if [ -d /proc ]; then
  for pid in $(pgrep -f "$AGENT" 2>/dev/null); do
    [ "$pid" = "$$" ] && continue
    cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null)" || continue
    case "$cwd" in "$ROOT_DIR"|"$ROOT_DIR"/*) ;; *) continue ;; esac
    cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" || continue
    case " $cmdline" in
      *" -p "*|*" -p"|*" --print "*|*" --print")
        kill "$pid" 2>/dev/null && { echo "stopped  agent worker (pid $pid)"; reaped=$((reaped + 1)); } ;;
    esac
  done
fi

# Belt-and-suspenders: reap any HTTP server left running outside tmux
# (e.g. started by hand), so the port is always freed.
if pgrep -f "mcp/librarian_http.py" >/dev/null 2>&1; then
  pkill -f "mcp/librarian_http.py" 2>/dev/null && echo "stopped  stray librarian_http.py process(es)"
fi

echo "----"
if [ "$stopped" -eq 0 ] && [ "$reaped" -eq 0 ]; then
  echo "Nothing was running."
else
  echo "All librarian services and agent workers stopped."
fi
