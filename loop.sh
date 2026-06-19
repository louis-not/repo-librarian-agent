#!/usr/bin/env bash
#
# loop.sh — sync every repository listed in .repos.input.
#
# Reads the hidden input file, then for each repo link: clones it into
# .repositories/ if missing, or fast-forward pulls it if already there.
# Skips repos with uncommitted changes (never clobbers local work). Repos are
# synced in parallel (LIBRARIAN_SYNC_CONCURRENCY, default 8) since it's network-bound.
#
# Run init.sh first to create the input file. Safe to run repeatedly — this is
# what the sync daemon calls every interval.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_DIR="$SCRIPT_DIR/.repositories"
INPUT_FILE="$SCRIPT_DIR/.repos.input"

if [ ! -f "$INPUT_FILE" ]; then
  echo "error: $INPUT_FILE not found — run  bash init.sh  first" >&2
  exit 1
fi
mkdir -p "$REPOS_DIR"

# Central settings (sync concurrency, etc.) from librarian.conf; env still wins.
[ -f "$SCRIPT_DIR/librarian.conf" ] && . "$SCRIPT_DIR/librarian.conf"

# Syncing is network-bound, so walking the list one repo at a time is slow. Run up
# to SYNC_CONC clone/pull jobs at once (override: LIBRARIAN_SYNC_CONCURRENCY).
SYNC_CONC="${LIBRARIAN_SYNC_CONCURRENCY:-8}"
[ "$SYNC_CONC" -lt 1 ] && SYNC_CONC=1

# Bounded-parallel runner: keep at most $max jobs in flight, then drain.
parallel_map() {
  local max="$1" func="$2"; shift 2
  local item
  for item in "$@"; do
    "$func" "$item" &
    while [ "$(jobs -rp | wc -l)" -ge "$max" ]; do wait -n 2>/dev/null || true; done
  done
  wait
}

# --- Parse the input into (url|name) entries (cheap, sequential) --------------
# Only string normalization/validation here; the network work runs in parallel.
entries=()
failed=0
failed_names=()
while IFS= read -r line || [ -n "$line" ]; do
  entry="$(echo "$line" | xargs)"        # trim whitespace
  [ -z "$entry" ] && continue            # blank line
  case "$entry" in \#*) continue ;; esac # comment

  # Normalize shorthand (org/repo) into an HTTPS URL.
  case "$entry" in
    *://*|git@*) url="$entry" ;;
    */*)         url="https://github.com/$entry.git" ;;
    *)
      echo "FAIL   '$entry' (unrecognized format)"
      failed=$((failed + 1)); failed_names+=("$entry"); continue ;;
  esac

  name="$(basename "$url")"; name="${name%.git}"
  entries+=("$url|$name")
done < "$INPUT_FILE"

# --- Clone/pull every repo in parallel ---------------------------------------
# Each worker appends one "status<TAB>name" line to RESULTS. The lines are short
# (well under PIPE_BUF), so concurrent O_APPEND writes don't interleave — that's
# how we tally accurately even though counters can't cross the background-job fork.
RESULTS="$(mktemp)"
trap 'rm -f "$RESULTS"' EXIT

sync_one() {
  local entry="$1" url name dest
  url="${entry%%|*}"; name="${entry#*|}"
  dest="$REPOS_DIR/$name"

  if [ -d "$dest/.git" ]; then
    if [ -n "$(git -C "$dest" status --porcelain 2>/dev/null)" ]; then
      echo "skip   $name (uncommitted changes)"
      printf 'skip\t%s\n' "$name" >> "$RESULTS"
    elif git -C "$dest" pull --ff-only --quiet; then
      echo "pull   $name"
      printf 'pull\t%s\n' "$name" >> "$RESULTS"
    else
      echo "FAIL   $name (pull failed — diverged or network)"
      printf 'fail\t%s\n' "$name" >> "$RESULTS"
    fi
  else
    if git clone --quiet "$url" "$dest"; then
      echo "clone  $name"
      printf 'clone\t%s\n' "$name" >> "$RESULTS"
    else
      echo "FAIL   $name (clone failed)"
      printf 'fail\t%s\n' "$name" >> "$RESULTS"
    fi
  fi
}

[ "${#entries[@]}" -gt 0 ] && parallel_map "$SYNC_CONC" sync_one "${entries[@]}"

# --- Tally (format errors already counted above) -----------------------------
cloned=0 pulled=0 skipped=0
while IFS=$'\t' read -r status name; do
  case "$status" in
    clone) cloned=$((cloned + 1)) ;;
    pull)  pulled=$((pulled + 1)) ;;
    skip)  skipped=$((skipped + 1)) ;;
    fail)  failed=$((failed + 1)); failed_names+=("$name") ;;
  esac
done < "$RESULTS"

echo "----"
echo "cloned: $cloned  pulled: $pulled  skipped: $skipped  failed: $failed"
[ "$failed" -gt 0 ] && echo "failed: ${failed_names[*]}"

# --- Refresh the knowledge base ---------------------------------------------
# After syncing source, rebuild the curated maps in .knowledge/ for any repo
# whose commit changed (digest.sh is incremental, so unchanged repos are free).
# Runs even if some repos failed above — the ones that synced still merit a map.
# Skip with LIBRARIAN_NO_DIGEST=1, or if digest.sh isn't present.
#
# Defer while a cold-start backfill is in progress: it is already building every
# map (in parallel) and holds the lock, so running digest.sh now would race it.
# Consider it active if the lock pid is alive, OR (belt-and-suspenders, covering
# the brief boot window before the pid is written) its tmux session exists.
BACKFILL_LOCK="$SCRIPT_DIR/.knowledge/.backfill.lock"
backfill_active() {
  if [ -f "$BACKFILL_LOCK" ]; then
    local pid; pid="$(cat "$BACKFILL_LOCK" 2>/dev/null || true)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
  fi
  tmux has-session -t "=librarian-backfill" 2>/dev/null && return 0
  return 1
}
if backfill_active; then
  echo "----"
  echo "cold-start backfill in progress — deferring knowledge refresh this cycle."
elif [ -z "${LIBRARIAN_NO_DIGEST:-}" ] && [ -f "$SCRIPT_DIR/utils/digest.sh" ]; then
  echo "----"
  echo "refreshing knowledge base..."
  bash "$SCRIPT_DIR/utils/digest.sh" || true
fi

[ "$failed" -gt 0 ] && exit 1
exit 0
