#!/usr/bin/env bash
#
# watch.sh — live view of the librarian answering, in tmux.
#
# Tails librarian-feed.log, where ask_librarian streams Claude's real steps
# (each grep/read/reason + the final answer). Attach here to watch every query
# unfold as agents hit the MCP server.
#
#   bash mcp/watch.sh            # create/attach the viewer
#   Ctrl-b then d                # detach (queries keep being served)
#
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FEED="$ROOT_DIR/.logs/librarian-feed.log"
SESSION="librarian-feed"

mkdir -p "$ROOT_DIR/.logs"
touch "$FEED"

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux not installed — falling back to plain tail. Ctrl-c to stop."
  exec tail -n 200 -f "$FEED"
fi

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux new-session -d -s "$SESSION" -c "$ROOT_DIR" "tail -n 200 -f '$FEED'"
fi

if [ -t 1 ]; then
  exec tmux attach -t "$SESSION"
else
  echo "Watcher session '$SESSION' ready. Attach with:  tmux attach -t $SESSION"
fi
