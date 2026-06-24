#!/usr/bin/env bash
#
# ask.sh — ask the librarian a question about the mirrored repositories.
#
# Spawns a fresh, read-only headless agent query (agy or claude) from the project
# root, so it loads the librarian instructions and reads across .repositories/ to
# answer with citations. Stateless and concurrent: every call is independent.
#
# Usage:
#   bash utils/ask.sh "how does authentication work in the billing service?"
#   echo "where are the API docs for service X?" | bash utils/ask.sh
#
# Uses the machine's logged-in Claude subscription (no API key, no --bare).

set -uo pipefail

# This script lives in utils/; the project root is one level up.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load central settings (model selection, etc.) from librarian.conf at the repo
# root; an env var of the same name still wins. See that file to change the model.
[ -f "$ROOT_DIR/librarian.conf" ] && . "$ROOT_DIR/librarian.conf"
AGENT="${LIBRARIAN_AGENT:-agy}"
MODEL="${LIBRARIAN_MODEL:-sonnet}"

# Question from args, or from stdin if none were given.
QUESTION="$*"
if [ -z "$QUESTION" ] && [ ! -t 0 ]; then
  QUESTION="$(cat)"
fi
if [ -z "${QUESTION// /}" ]; then
  echo "usage: bash utils/ask.sh \"your question about the repos\"" >&2
  exit 1
fi

if ! command -v "$AGENT" >/dev/null 2>&1; then
  echo "error: the '$AGENT' CLI is not on PATH." >&2
  exit 1
fi

# Force subscription auth: an API key in the env would switch to metered
# billing, and --bare would bypass the OAuth/keychain credential entirely.
unset ANTHROPIC_API_KEY

# Run from the project root so the librarian's instructions auto-load (CLAUDE.md
# for `claude`, AGENTS.md for `agy`) and .repositories/ is in scope.
cd "$ROOT_DIR"
if [ "$AGENT" = "claude" ]; then
  # Claude enforces read-only at the CLI via an explicit tool allowlist.
  exec claude -p "$QUESTION" --model "$MODEL" \
    --allowedTools "Read,Grep,Glob,Bash(git log:*),Bash(git show:*),Bash(git blame:*)"
else
  # Antigravity (agy) has no --allowedTools flag — it auto-approves tools in
  # print mode and emits a plain-text answer. Read-only scope is enforced by the
  # librarian's instructions (AGENTS.md), not a CLI allowlist.
  exec "$AGENT" -p "$QUESTION" --model "$MODEL"
fi
