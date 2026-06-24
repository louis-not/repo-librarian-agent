#!/usr/bin/env bash
#
# backfill.sh — PACED, pausable, resumable cold-start build of the knowledge
# base. Built to work AROUND Claude usage limits rather than blow through them:
# it deep-maps the mirror a bounded BATCH of repos at a time, then sleeps for a
# pacing interval (default 2h) so the next batch lands in a fresh usage window,
# repeating until every repo is mapped. It is fully resumable — each cycle
# recomputes what still needs work (missing / provisional / stale-commit) — so a
# kill, a pause, or a reboot loses no finished work.
#
# Stages:
#   stubs         provisional, naming-based stub maps for breadth — auto on a cold
#                 start, or forced with BACKFILL_STUBS=1 (skip via BACKFILL_NO_STUBS=1)
#   maps          authoritative per-repo deep maps, paced in batches, priority
#                 ordered by last commit, run CONC-at-a-time within a batch
#   aggregate     project overviews + cross-project graph (digest.sh agg-only)
#
# Pause/continue:
#   bash utils/backfill.sh pause     # park it (keeps the sync loop deferred)
#   bash utils/backfill.sh resume    # clear the pause / relaunch if stopped
#   bash utils/backfill.sh status    # pending count, paused/running, log tail
#   (hard stop: tmux kill-session -t librarian-backfill; relaunch to resume)
#
# Knobs — set persistently in librarian.conf at the repo root, or override per-run
# via an env var of the same name (the env var wins):
#   BACKFILL_BATCH=20            repos deep-mapped per cycle
#   BACKFILL_PACE_SECONDS=7200   sleep between cycles (2h)
#   BACKFILL_CONCURRENCY         workers within a batch (default min(cores,10))
#   BACKFILL_STUB_BATCH=12       repos per Claude turn in the Stage A stub pass
#   BACKFILL_STUBS=1             force the Stage A stub pass (auto-runs on cold start)
#   BACKFILL_NO_STUBS=1          skip Stage A even on a cold start (straight to maps)
#   BACKFILL_RETRIES=3           transient-failure retries per task
#
# Progress is mirrored to .logs/backfill.log — watch with: tail -f .logs/backfill.log
# Uses the machine's logged-in Claude subscription (no API key).

set -uo pipefail

UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$UTILS_DIR/.." && pwd)"
REPOS_DIR="$ROOT_DIR/.repositories"
KNOW_DIR="$ROOT_DIR/.knowledge"
LOGS_DIR="$ROOT_DIR/.logs"
LOG_FILE="$LOGS_DIR/backfill.log"
PROG_DIR="$KNOW_DIR/.backfill-progress"
LOCK="$KNOW_DIR/.backfill.lock"
PAUSE_FLAG="$KNOW_DIR/.backfill.pause"
DATE="$(date +%F)"

project_of() { printf '%s\n' "${1%%[_-]*}"; }

detect_cores() {
  if command -v nproc >/dev/null 2>&1; then nproc
  elif [ -r /proc/cpuinfo ]; then grep -c '^processor' /proc/cpuinfo
  else getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4
  fi
}

# Central settings live in librarian.conf at the repo root. Source it FIRST, so
# the values there seed the knobs below; an env var of the same name still wins
# (the conf uses :=), so per-run overrides keep working. The deep-map/aggregate
# phases shell out to digest.sh, which sources the same file, so one edit applies
# to every stage. Knobs are read at startup — change a value, then restart the
# backfill for it to take effect (it resumes safely, skipping mapped repos).
[ -f "$ROOT_DIR/librarian.conf" ] && . "$ROOT_DIR/librarian.conf"

CONC="${BACKFILL_CONCURRENCY:-$(detect_cores)}"
[ "$CONC" -gt 10 ] && CONC=10           # hard cap, regardless of conf/env, to spare usage limits
[ "$CONC" -lt 1 ] && CONC=1
BATCH="${BACKFILL_BATCH:-20}";            [ "$BATCH" -lt 1 ] && BATCH=1
PACE="${BACKFILL_PACE_SECONDS:-7200}";    [ "$PACE" -lt 0 ] && PACE=0
STUB_BATCH="${BACKFILL_STUB_BATCH:-12}";  [ "$STUB_BATCH" -lt 1 ] && STUB_BATCH=1
RETRIES="${BACKFILL_RETRIES:-3}"
AGENT="${LIBRARIAN_AGENT:-agy}"           # CLI agent
MODEL="${LIBRARIAN_MODEL:-sonnet}"        # passed to `--model`

# run_agent <allowed-tools> <prompt> — invoke the configured agent, hiding the
# flag differences. Claude takes an explicit tool allowlist (stubs need Write);
# agy has no --allowedTools flag and auto-approves tools in print mode, so it
# just gets the prompt and model.
run_agent() {
  local tools="$1"; shift
  if [ "$AGENT" = "claude" ]; then
    claude -p "$1" --model "$MODEL" --allowedTools "$tools"
  else
    # agy print mode defaults to a 5m timeout; raise it (override via librarian.conf).
    "$AGENT" --print-timeout "${LIBRARIAN_AGY_PRINT_TIMEOUT:-30m}" -p "$1" --model "$MODEL"
  fi
}

# --- needs_map: mirror digest.sh's skip rule (missing/provisional/stale) ------
needs_map() {
  local r="$1" f="$KNOW_DIR/$1/index.md" sha
  [ -f "$f" ] || return 0
  [ -f "$KNOW_DIR/$1/decisions.md" ] || return 0
  grep -q '^provisional: true$' "$f" && return 0
  # An empty repo (no commits / unborn HEAD) has no resolvable sha. digest.sh maps
  # it with `commit: unknown` and skips on that; mirror it here with the same
  # sentinel, or these repos look perpetually stale and Stage B never converges.
  sha="$(git -C "$REPOS_DIR/$r" rev-parse --short HEAD 2>/dev/null)" || sha="unknown"
  [ -z "$sha" ] && sha="unknown"
  grep -q "^commit: ${sha}\$" "$f" || return 0
  return 1
}
needs_stub() { [ ! -f "$KNOW_DIR/$1/index.md" ]; }

# Pending repos that still need a deep map, newest-commit first (priority).
pending_repos() {
  local r ct
  for r in "${repos[@]}"; do
    needs_map "$r" || continue
    ct="$(git -C "$REPOS_DIR/$r" log -1 --format=%ct 2>/dev/null || echo 0)"
    printf '%s\t%s\n' "$ct" "$r"
  done | sort -rn | cut -f2
}

# ============================================================================
# Subcommands: pause / resume / status (default = run)
# ============================================================================
cmd_pause() {
  : > "$PAUSE_FLAG"
  echo "paused — the running backfill will park after its current task."
  echo "(it keeps the sync loop deferred; resume with: bash utils/backfill.sh resume)"
}

cmd_resume() {
  rm -f "$PAUSE_FLAG"
  local pid=""; [ -f "$LOCK" ] && pid="$(cat "$LOCK" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "resumed — the parked backfill (pid $pid) will continue."
  else
    echo "no backfill running — starting one."
    exec bash "$0" run
  fi
}

cmd_status() {
  local repos=()
  for p in "$REPOS_DIR"/*/; do [ -d "${p}.git" ] && repos+=("$(basename "$p")"); done
  local total=${#repos[@]} pend=0 r
  for r in "${repos[@]}"; do needs_map "$r" && pend=$((pend + 1)); done
  echo "repos:        $total"
  echo "need mapping: $pend"
  echo "done:         $((total - pend))"
  if [ -f "$PAUSE_FLAG" ]; then echo "state:        PAUSED"; fi
  local pid=""; [ -f "$LOCK" ] && pid="$(cat "$LOCK" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "process:      running (pid $pid)"
  else
    echo "process:      not running"
  fi
  if [ -f "$LOG_FILE" ]; then echo "--- last log lines ---"; tail -n 8 "$LOG_FILE"; fi
}

case "${1:-run}" in
  pause)  cmd_pause;  exit 0 ;;
  resume) cmd_resume; exit 0 ;;
  status) cmd_status; exit 0 ;;
  run)    ;;
  *)      echo "usage: backfill.sh [run|pause|resume|status]" >&2; exit 2 ;;
esac

# ============================================================================
# run
# ============================================================================
if ! command -v "$AGENT" >/dev/null 2>&1; then
  echo "error: the '$AGENT' CLI is not on PATH." >&2
  exit 1
fi
unset ANTHROPIC_API_KEY            # force subscription auth (no metered API)
cd "$ROOT_DIR"
mkdir -p "$KNOW_DIR" "$LOGS_DIR"

# Mirror all output to the log so progress is visible without attaching tmux.
exec > >(tee -a "$LOG_FILE") 2>&1
echo "[$(date '+%F %T')] backfill starting (pid $$)"

# --- Single-instance lock (written FIRST and atomically) ---------------------
if [ -f "$LOCK" ]; then
  other="$(cat "$LOCK" 2>/dev/null || true)"
  if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
    echo "backfill already running (pid $other) — exiting."
    exit 0
  fi
  echo "stale backfill lock (pid ${other:-?}) — taking over."
fi
printf '%s\n' "$$" > "$LOCK.tmp" && mv -f "$LOCK.tmp" "$LOCK"
rm -rf "$PROG_DIR"; mkdir -p "$PROG_DIR"
trap 'rm -f "$LOCK" "$LOCK.tmp"; rm -rf "$PROG_DIR"' EXIT

# --- Progress counter (tqdm-ish across parallel workers) ---------------------
progress() {   # $1=phase  $2=total  $3=message
  local pf="$PROG_DIR/$1"
  printf '.' >> "$pf"
  local n; n="$(wc -c < "$pf" 2>/dev/null || echo '?')"
  printf '  [%s %s/%s] %s\n' "$1" "$n" "$2" "$3"
}

# --- Bounded-parallel runner -------------------------------------------------
parallel_map() {
  local max="$1" func="$2"; shift 2
  local item
  for item in "$@"; do
    "$func" "$item" &
    while [ "$(jobs -rp | wc -l)" -ge "$max" ]; do wait -n 2>/dev/null || true; done
  done
  wait
}

# Sleep in short slices so a pause takes effect promptly (and so we never block
# uninterruptibly). Returns as soon as the pause flag appears.
paced_sleep() {
  local left="$1"
  while [ "$left" -gt 0 ]; do
    [ -f "$PAUSE_FLAG" ] && return 0
    local s=30; [ "$left" -lt 30 ] && s="$left"
    sleep "$s"; left=$((left - s))
  done
}

# Park while paused (holding the lock so the sync loop keeps deferring).
park_if_paused() {
  local announced=0
  while [ -f "$PAUSE_FLAG" ]; do
    [ "$announced" -eq 0 ] && {
      echo "[$(date '+%T')] PAUSED — remove $PAUSE_FLAG (or: backfill.sh resume) to continue"
      announced=1
    }
    sleep 30
  done
  [ "$announced" -eq 1 ] && echo "[$(date '+%T')] resumed."
}

# --- Collect mirror ----------------------------------------------------------
repos=()
for repo_path in "$REPOS_DIR"/*/; do
  [ -d "${repo_path}.git" ] || continue
  repos+=("$(basename "$repo_path")")
done
if [ "${#repos[@]}" -eq 0 ]; then
  echo "no repositories in the mirror — nothing to backfill."
  exit 0
fi

declare -A PROJ_MEMBERS
for r in "${repos[@]}"; do PROJ_MEMBERS["$(project_of "$r")"]+="$r "; done
projects_total=${#PROJ_MEMBERS[@]}

pend_total=0
for r in "${repos[@]}"; do needs_map "$r" && pend_total=$((pend_total + 1)); done

echo "=============================================================="
echo " paced backfill: ${#repos[@]} repos / ${projects_total} projects"
echo " need mapping: ${pend_total}   batch: ${BATCH}   pace: $((PACE/60))min   conc: ${CONC}"
echo "=============================================================="

# ============================================================================
# (optional) Stage A — provisional stubs for breadth  (BACKFILL_STUBS=1)
# ============================================================================
agent_try() {   # retry transient failures; $@ = full agent invocation
  local i=1
  while :; do
    "$@" >/dev/null 2>&1 && return 0
    [ "$i" -ge "$RETRIES" ] && return 1
    sleep $((i * 5)); i=$((i + 1))
  done
}

stage_a_stubs() {        # $1=project  $2=comma-separated repo names
  local proj="$1" csv="$2"
  local todo=(); IFS=',' read -r -a todo <<< "$csv"
  local stub_list; stub_list="$(printf '%s, ' "${todo[@]}")"
  local multi=""; [ "$(set -- ${PROJ_MEMBERS[$proj]}; echo $#)" -ge 2 ] && multi=1
  local a_uplink=""
  [ -n "$multi" ] && a_uplink="
Then a line: Part of project **${proj}** — [project overview](../${proj}/overview.md)."
  local APROMPT="You are a code librarian doing a FAST first-pass over the '${proj}' project, writing PROVISIONAL stub maps before deep indexing. Stub these members: ${stub_list}. For EACH, look ONLY at cheap signals under .repositories/<repo>/ — the README (top), the top-level file/folder listing (Glob), and any dependency manifest. Do NOT read source deeply.

For each member <repo>, write .knowledge/<repo>/index.md beginning EXACTLY with:
---
repo: <repo>
project: ${proj}
indexed: ${DATE}
provisional: true
summary: ONE sentence (max 120 chars) best-guess from the name and README
---
Then '# <repo>' as an H1 title.${a_uplink}
Then a SHORT body:
## Purpose
1-2 sentences, best guess.
## Stack
From manifest/extensions.
## Naming
Decode the name parts (project / component / target, split on _ and -) and their implied role.
## Status
Provisional stub from first fetch — full deep map pending.

Write ONLY the .knowledge/<repo>/index.md files listed. Mark uncertainty honestly."
  agent_try run_agent "Read,Grep,Glob,Write" "$APROMPT"
}

stage_a_worker() {       # $1 = 'proj|csv'
  local task="$1" proj csv
  proj="${task%%|*}"; csv="${task#*|}"
  if stage_a_stubs "$proj" "$csv"; then progress A "$A_TOTAL" "ok   stubs ${proj}"
  else progress A "$A_TOTAL" "FAIL stubs ${proj}"; fi
}

# Stage A (provisional stubs) runs when explicitly requested (BACKFILL_STUBS=1) or
# automatically on a COLD START — when no repo has a map yet. A fresh knowledge base
# then gets instant breadth (every repo a shallow stub, many per Claude turn) while
# the slow, usage-paced Stage B fills in depth and upgrades each stub.
# BACKFILL_NO_STUBS=1 suppresses the cold-start auto-trigger (go straight to maps).
cold_start=1
for r in "${repos[@]}"; do
  [ -f "$KNOW_DIR/$r/index.md" ] && { cold_start=0; break; }
done
stub_reason=""
if [ -n "${BACKFILL_STUBS:-}" ]; then
  stub_reason="opt-in"
elif [ "$cold_start" -eq 1 ] && [ -z "${BACKFILL_NO_STUBS:-}" ]; then
  stub_reason="cold start — seeding breadth"
fi

if [ -n "$stub_reason" ]; then
  echo
  echo "### Stage A — provisional stubs (${stub_reason}) ###"
  a_tasks=()
  for proj in $(printf '%s\n' "${!PROJ_MEMBERS[@]}" | sort); do
    members=(${PROJ_MEMBERS[$proj]})
    todo=(); for m in "${members[@]}"; do needs_stub "$m" && todo+=("$m"); done
    i=0
    while [ "$i" -lt "${#todo[@]}" ]; do
      chunk=("${todo[@]:$i:$STUB_BATCH}")
      a_tasks+=("${proj}|$(IFS=','; echo "${chunk[*]}")")
      i=$((i + STUB_BATCH))
    done
  done
  if [ "${#a_tasks[@]}" -gt 0 ]; then
    A_TOTAL=${#a_tasks[@]}
    parallel_map "$CONC" stage_a_worker "${a_tasks[@]}"
  else
    echo "  (no repos need a stub)"
  fi
fi

# ============================================================================
# Stage B — deep maps, PACED in batches (the heavy, limit-sensitive work)
# ============================================================================
echo
echo "### Stage B — deep maps (batch ${BATCH}, conc ${CONC}, ${PACE}s between) ###"

stage_b_repo() {
  # No --force: digest.sh skips a repo already mapped at its current commit, so a
  # killed/paused backfill resumes. Retry rides out transient (non-limit) errors.
  local i=1
  while :; do
    if DIGEST_MAPS_ONLY=1 bash "$UTILS_DIR/digest.sh" "$1" >/dev/null 2>&1; then
      progress B "$B_TOTAL" "ok   $1"; return 0
    fi
    [ "$i" -ge "$RETRIES" ] && { progress B "$B_TOTAL" "FAIL $1"; return 1; }
    sleep $((i * 5)); i=$((i + 1))
  done
}

cycle=0
while :; do
  park_if_paused

  pending=(); while IFS= read -r r; do [ -n "$r" ] && pending+=("$r"); done < <(pending_repos)
  [ "${#pending[@]}" -eq 0 ] && break

  cycle=$((cycle + 1))
  batch=("${pending[@]:0:$BATCH}")
  B_TOTAL=${#batch[@]}
  rm -f "$PROG_DIR/B"
  echo "[$(date '+%T')] cycle ${cycle}: ${#pending[@]} pending — mapping ${#batch[@]} now"
  parallel_map "$CONC" stage_b_repo "${batch[@]}"

  remaining=0
  for r in "${repos[@]}"; do needs_map "$r" && remaining=$((remaining + 1)); done
  if [ "$remaining" -gt 0 ]; then
    echo "[$(date '+%T')] cycle ${cycle} done — ${remaining} repos remaining; pacing $((PACE/60))min"
    paced_sleep "$PACE"
  fi
done

# ============================================================================
# Stage C — aggregation (project overviews + cross-project graph), paced retry
# ============================================================================
echo
echo "### Stage C — project overviews + cross-project graph ###"
agg_try=0
while :; do
  park_if_paused
  if DIGEST_AGG_ONLY=1 bash "$UTILS_DIR/digest.sh"; then
    break
  fi
  agg_try=$((agg_try + 1))
  [ "$agg_try" -ge "$RETRIES" ] && { echo "aggregation incomplete after ${RETRIES} tries — next sync loop will finish it."; break; }
  echo "[$(date '+%T')] aggregation hit an error (possibly the usage limit); pacing $((PACE/60))min"
  paced_sleep "$PACE"
done

# --- Report ------------------------------------------------------------------
mapped=0 provisional=0 missing=0
for r in "${repos[@]}"; do
  f="$KNOW_DIR/$r/index.md"
  if [ ! -f "$f" ]; then missing=$((missing + 1))
  elif grep -q '^provisional: true$' "$f"; then provisional=$((provisional + 1))
  else mapped=$((mapped + 1)); fi
done
echo
echo "=============================================================="
echo " backfill finished: ${mapped}/${#repos[@]} deep-mapped"
[ "$provisional" -gt 0 ] && echo "   ${provisional} still provisional"
[ "$missing" -gt 0 ] && echo "   ${missing} unmapped (will retry next run / sync loop)"
echo " full log: ${LOG_FILE}"
echo "=============================================================="
