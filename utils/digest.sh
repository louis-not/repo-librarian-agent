#!/usr/bin/env bash
#
# digest.sh — build/refresh the Claude-managed knowledge base in .knowledge/.
#
# For every mirrored repo it maintains three kinds of curated knowledge:
#
#   .knowledge/<repo>/index.md      structural MAP — purpose, entry points, key
#                                   components, APIs/contracts, docs, gotchas.
#                                   Regenerated when the repo's HEAD changes.
#   .knowledge/<repo>/decisions.md  reverse-chron DECISION LOG mined from git
#                                   history. Each sync APPENDS one entry distilled
#                                   from the commits/diff since the last digest —
#                                   what changed and why.
#   .knowledge/<project>/overview.md  per-PROJECT OVERVIEW for a family of repos
#                                   sharing a name prefix (acme_*, globex-*):
#                                   roles, intra-project flow, shared contracts.
#                                   The unit a question is usually scoped to.
#   .knowledge/connections.md       cross-PROJECT INTEGRATION GRAPH (edges that
#                                   cross a project boundary, shared contracts,
#                                   data flow). Rebuilt whenever anything changed.
#
# The librarian reads these first (cheap, pre-distilled) before diving into the
# raw mirror, then confirms against source before answering.
#
# Incremental: a repo is re-digested only when its HEAD commit changed since the
# last digest (the sha is stamped in the map frontmatter), so steady-state runs
# cost ~zero Claude turns. loop.sh calls this after each sync.
#
# Usage:
#   bash utils/digest.sh                       # refresh repos whose commit changed
#   bash utils/digest.sh --force               # re-digest every repo
#   bash utils/digest.sh acme_crawler-service  # only this repo
#   bash utils/digest.sh --force <repo>        # force just one
#
# Build modes (env vars; used by the cold-start backfill, utils/backfill.sh):
#   DIGEST_MAPS_ONLY=1 bash utils/digest.sh --force <repo>   # just the repo map
#   DIGEST_AGG_ONLY=1  bash utils/digest.sh                  # just overviews+graph
#
# Uses the machine's logged-in Claude subscription (no API key, no --bare).

set -uo pipefail

# This script lives in utils/; the project root is one level up.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOS_DIR="$ROOT_DIR/.repositories"
KNOW_DIR="$ROOT_DIR/.knowledge"
DATE="$(date +%F)"

MAP_TOOLS="Read,Grep,Glob,Bash(git log:*),Bash(git show:*),Bash(git diff:*),Write"

# Model used to synthesize the maps/overviews/graph. Loaded from librarian.conf
# at the repo root (an env var of the same name still wins); edit that file to
# change it. Defaults to Sonnet if the config is missing.
[ -f "$ROOT_DIR/librarian.conf" ] && . "$ROOT_DIR/librarian.conf"
MODEL="${LIBRARIAN_MODEL:-sonnet}"

# Project code = the repo-name prefix before the first '_' or '-' delimiter.
# Repos in the org share a high-level project code (acme_crawler-service and
# acme_harvest-agent both belong to 'acme'); the delimiter is not fixed,
# so we split on whichever of '_' or '-' comes first.
project_of() { printf '%s\n' "${1%%[_-]*}"; }

FORCE=0
ONLY=""
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -*)      echo "unknown option: $arg" >&2; exit 2 ;;
    *)       ONLY="$arg" ;;
  esac
done

# Build modes — let the cold-start backfill split work across parallel workers:
#   DIGEST_MAPS_ONLY=1  only (re)build per-repo maps; skip the aggregation passes
#                       (project overviews, cross-project connections, top index).
#   DIGEST_AGG_ONLY=1   skip per-repo maps; only (re)build the aggregation passes
#                       from whatever maps exist — incrementally (missing or still
#                       -provisional overviews only), so it's cheap when complete.
# Unset (the steady-state default), it does both, incrementally.
MAPS_ONLY="${DIGEST_MAPS_ONLY:-}"
AGG_ONLY="${DIGEST_AGG_ONLY:-}"
if [ -n "$MAPS_ONLY" ] && [ -n "$AGG_ONLY" ]; then
  echo "error: DIGEST_MAPS_ONLY and DIGEST_AGG_ONLY are mutually exclusive." >&2
  exit 2
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "error: the 'claude' CLI is not on PATH." >&2
  exit 1
fi

# Force subscription auth (an API key would switch to metered billing).
unset ANTHROPIC_API_KEY
cd "$ROOT_DIR"
mkdir -p "$KNOW_DIR"

digested=0 skipped=0 failed=0
failed_names=()
digested_names=()

# --- Per-repo maps (skipped entirely in aggregation-only mode) --------------
if [ -z "$AGG_ONLY" ]; then
for repo_path in "$REPOS_DIR"/*/; do
  [ -d "${repo_path}.git" ] || continue
  name="$(basename "$repo_path")"
  [ -n "$ONLY" ] && [ "$name" != "$ONLY" ] && continue

  proj="$(project_of "$name")"
  # How many mirrored repos share this project? Only multi-repo projects get an
  # overview, so only then do we ask the map to link up to it.
  proj_members=0
  for _rp in "$REPOS_DIR"/*/; do
    [ -d "${_rp}.git" ] || continue
    [ "$(project_of "$(basename "$_rp")")" = "$proj" ] && proj_members=$((proj_members + 1))
  done
  if [ "$proj_members" -ge 2 ]; then
    uplink="
Then a single line linking up to the family: Part of project **${proj}** — [project overview](../${proj}/overview.md)."
  else
    uplink=""
  fi

  sha="$(git -C "$repo_path" rev-parse --short HEAD 2>/dev/null)" || sha="unknown"
  kdir="$KNOW_DIR/$name"
  kfile="$kdir/index.md"
  decisions="$kdir/decisions.md"
  pending="$kdir/.pending-entry.md"

  # Skip only when the map is current AND a decision log already exists. (A repo
  # mapped before this feature lands has no log yet, so it re-runs once to seed.)
  if [ "$FORCE" -eq 0 ] && [ -f "$kfile" ] && grep -q "^commit: $sha$" "$kfile" \
       && [ -f "$decisions" ]; then
    echo "skip    $name (up to date @ $sha)"
    skipped=$((skipped + 1))
    continue
  fi

  echo "digest  $name @ $sha ..."
  mkdir -p "$kdir"

  # Previously indexed sha (if any) drives the decision-log delta.
  old_sha=""
  [ -f "$kfile" ] && old_sha="$(sed -n 's/^commit: //p' "$kfile" | head -n1)"

  if [ -n "$old_sha" ] && [ "$old_sha" != "$sha" ] \
       && git -C "$repo_path" cat-file -e "${old_sha}^{commit}" 2>/dev/null; then
    # Incremental update: log the commits/diff since the last digest.
    commits="$(git -C "$repo_path" log --no-merges --date=short \
                 --pretty='- %h %s (%an, %ad)' "${old_sha}..HEAD" 2>/dev/null | head -n 80)"
    diffstat="$(git -C "$repo_path" diff --stat "${old_sha}" HEAD 2>/dev/null | tail -n 50)"
    decision_block="These commits landed since the previously indexed commit ${old_sha} (range ${old_sha}..${sha}):
${commits}

Files changed (git diff --stat):
${diffstat}

You may run git show/git diff on specific hashes to understand a change before writing."
    entry_head="## ${DATE} — ${sha} (updated from ${old_sha})"
  else
    # First-time seed: distil the repo's history into an initial entry.
    commits="$(git -C "$repo_path" log --no-merges --date=short \
                 --pretty='- %h %s (%ad)' 2>/dev/null | head -n 50)"
    decision_block="This is the FIRST time this repo is indexed. Summarize its history as initial context — the major milestones and turning points, NOT every commit. Recent/representative commits (newest first):
${commits}"
    entry_head="## ${DATE} — ${sha} (initial history)"
  fi

  PROMPT="You are maintaining a knowledge base for a code librarian, indexing the repository at .repositories/${name} (READ-ONLY: never modify, commit, or run it).

TASK 1 — Repository map. Write .knowledge/${name}/index.md. It MUST begin with this exact YAML frontmatter, filling in the summary:
---
repo: ${name}
project: ${proj}
commit: ${sha}
indexed: ${DATE}
summary: ONE sentence (max 120 chars) describing what this repo is and does
---
Then '# ${name}' as the H1 title, so the note reads cleanly in a markdown/Obsidian viewer.${uplink}
Then a markdown body with these sections, in order:
## Purpose - one short paragraph.
## Stack - languages, frameworks, notable dependencies.
## Entry points - the files you would open first, each cited as ${name}/path/to/file.ext:line.
## Key components - 5 to 12 bullets; each names a component, cites its location as ${name}/path:line, one line on what it does.
## APIs and contracts - endpoints, message schemas, public interfaces, env/config that OTHER repos would call or depend on, each cited.
## Where docs live - READMEs, docs/, notable comments or config, cited.
## Gotchas - non-obvious behavior, footguns, surprising defaults.
Every concrete claim cites a real ${name}/path:line. Be dense - a map, not a transcript.

TASK 2 — Decision-log entry. Write .knowledge/${name}/.pending-entry.md with ONE new entry (it will be prepended to the existing log; do NOT include older entries). ${decision_block}
Format the entry exactly as:
${entry_head}
Then 2-6 bullets capturing the MEANINGFUL changes and the decision/rationale behind them — new features, refactors, migrations, breaking API/schema changes, notable dependency or infra changes — explaining the *why* where the commits or diff reveal it. Cite commit hashes as ${name}@<hash> and source as ${name}/path:line. Skip pure trivia (formatting, typos, lockfile noise); if everything is trivial, write a single bullet saying so. Terse and high-signal.

Write ONLY these two files (.knowledge/${name}/index.md and .knowledge/${name}/.pending-entry.md)."

  if claude -p "$PROMPT" --model "$MODEL" --allowedTools "$MAP_TOOLS" >/dev/null 2>&1 && [ -f "$kfile" ]; then
    # Prepend the new entry to the decision log (newest first), then clean up.
    if [ -s "$pending" ]; then
      if [ -f "$decisions" ]; then
        { cat "$pending"; printf '\n'; cat "$decisions"; } > "${decisions}.tmp" \
          && mv "${decisions}.tmp" "$decisions"
      else
        cp "$pending" "$decisions"
      fi
    fi
    rm -f "$pending"
    echo "  ok    $name"
    digested=$((digested + 1)); digested_names+=("$name")
  else
    rm -f "$pending"
    echo "  FAIL  $name (no map written)"
    failed=$((failed + 1)); failed_names+=("$name")
  fi
done
fi  # end per-repo maps

# maps-only mode: stop here, leaving the aggregation passes to a later call.
if [ -n "$MAPS_ONLY" ]; then
  echo "----"
  echo "(maps-only) digested: $digested  skipped: $skipped  failed: $failed"
  if [ "$failed" -gt 0 ]; then echo "failed: ${failed_names[*]}"; exit 1; fi
  exit 0
fi

# --- Group mapped repos by project code -------------------------------------
# The repo-name prefix (before the first '_' or '-') is the high-level project a
# family of repos belongs to. We synthesize one overview per multi-repo project
# (the unit a question is usually scoped to) and a cross-PROJECT graph on top.
declare -A PROJ_MEMBERS
for f in "$KNOW_DIR"/*/index.md; do
  [ -f "$f" ] || continue
  rname="$(basename "$(dirname "$f")")"
  PROJ_MEMBERS["$(project_of "$rname")"]+="$rname "
done
projects_total=${#PROJ_MEMBERS[@]}

was_digested() {  # true if repo $1 was (re)digested this run
  local q="$1" d
  [ "${#digested_names[@]}" -eq 0 ] && return 1
  for d in "${digested_names[@]}"; do [ "$d" = "$q" ] && return 0; done
  return 1
}

# --- Per-project overview (one synthesis per multi-repo family) --------------
# A project's overview is rebuilt only when a member changed (or it's missing),
# so a quiet project costs nothing. Single-repo projects need no overview — that
# repo's own map already serves; read_project_map falls back to it.
agg_changed=0   # set when any overview is (re)built, so connections can refresh
for proj in $(printf '%s\n' "${!PROJ_MEMBERS[@]}" | sort); do
  members=(${PROJ_MEMBERS[$proj]})
  [ "${#members[@]}" -ge 2 ] || continue
  overview="$KNOW_DIR/$proj/overview.md"
  dirty=0
  [ "$FORCE" -eq 1 ] && dirty=1
  [ -f "$overview" ] || dirty=1
  # A provisional overview (a cold-start stub) must be rebuilt into the real one;
  # a finished overview is left alone, so steady/agg-only runs stay cheap.
  [ -f "$overview" ] && grep -q '^provisional: true$' "$overview" && dirty=1
  for m in "${members[@]}"; do was_digested "$m" && dirty=1; done
  if [ "$dirty" -eq 0 ]; then
    echo "skip    project $proj (overview current)"
    continue
  fi
  echo "project  $proj — synthesizing overview from ${#members[@]} member maps ..."
  mkdir -p "$KNOW_DIR/$proj"
  OPROMPT="You are a code librarian writing the OVERVIEW for the '${proj}' project — a family of repositories sharing the '${proj}' name prefix. Its member repos and their curated maps are: $(for m in "${members[@]}"; do printf '%s (.knowledge/%s/index.md), ' "$m" "$m"; done). Read those maps (rely on them and their cited repo/path:line pointers; you need not open .repositories). Write .knowledge/${proj}/overview.md, the whiteboard view a senior dev draws to explain the whole '${proj}' system. Begin with this exact frontmatter:
---
project: ${proj}
built: ${DATE}
summary: ONE sentence (max 120 chars) on what the ${proj} project does as a whole
---
Then '# ${proj} — project overview' as the H1 title, so the note reads cleanly in a markdown/Obsidian viewer.
Then these sections, in order:
## Purpose - one paragraph: what this family of repos does together.
## Repos and roles - one bullet per member: '**<repo>** - its role in the project', linking its map with a relative path as [map](../<repo>/index.md) (the overview sits one directory deeper than the repo maps, so the '../' prefix is required for the link to resolve).
## End-to-end flow - how data/control moves THROUGH the project, member to member, start to finish. Short bullets with arrows like '<repoA> -> <repoB>: mechanism (HTTP endpoint / shared DB / queue / model artifact / file contract)'. Cite repo/path:line from the maps.
## Shared contracts - the schemas, endpoints, queues, env/config that members share with each other, each cited repo/path:line, naming which member produces and which consumes.
## Gotchas - cross-cutting footguns spanning the project.
Cite real repo/path:line. Mark any link you infer rather than see stated as (inferred). Dense, a map not a transcript. Write ONLY .knowledge/${proj}/overview.md."
  if claude -p "$OPROMPT" --model "$MODEL" --allowedTools "Read,Grep,Glob,Write" >/dev/null 2>&1 \
       && [ -f "$overview" ]; then
    echo "  ok    $proj/overview.md"
    agg_changed=1
  else
    echo "  FAIL  $proj/overview.md"
  fi
done

# --- Cross-PROJECT connections graph ----------------------------------------
# Edges BETWEEN project families (the architecturally significant ones). Built
# only when >=2 projects exist and something changed (or it's missing).
conn="$KNOW_DIR/connections.md"
# Also rebuild when a map is newer than the graph — covers agg-only runs where no
# overview changed (e.g. all single-repo projects) but deep maps did move.
maps_newer=""
[ -f "$conn" ] && maps_newer="$(find "$KNOW_DIR" -mindepth 2 -name index.md -newer "$conn" -print -quit 2>/dev/null)"
if [ "$projects_total" -ge 2 ] \
     && { [ "$digested" -gt 0 ] || [ ! -f "$conn" ] || [ "$FORCE" -eq 1 ] \
          || [ "$agg_changed" -eq 1 ] || [ -n "$maps_newer" ]; }; then
  echo "connect  synthesizing cross-project graph across $projects_total projects ..."
  # Read the already-distilled project OVERVIEWS, not the raw per-repo maps. This
  # keeps the input O(projects), not O(repos), so it stays tractable at ~100 repos.
  CPROMPT="You are mapping how an organization's PROJECTS connect, for a code librarian. The projects (each a family of repos sharing a name prefix) are: $(for p in $(printf '%s\n' "${!PROJ_MEMBERS[@]}" | sort); do printf '%s [%s], ' "$p" "${PROJ_MEMBERS[$p]}"; done). Read each project's distilled overview at .knowledge/<project>/overview.md; for a single-repo project that has no overview, read that one repo's map .knowledge/<repo>/index.md instead. Rely on these distilled docs and their cited pointers — do NOT crawl every per-repo map or open .repositories; the overviews already name each project's shared contracts. Write .knowledge/connections.md, focused on edges that CROSS a project boundary (e.g. an acme repo calling a globex repo) — these matter most precisely because they cross families. Cover: (1) a one-line roster of the projects and what each does; (2) every cross-project edge, with direction and mechanism (HTTP endpoint, shared DB/schema, queue, model artifact, file/wire contract), cited repo/path:line as surfaced by the overviews; (3) the end-to-end data flow where it spans projects. Use short bullets and arrows like 'projectA/repo -> projectB/repo: mechanism'. If no cross-project edges exist, say so plainly and just give the roster. Mark inferred links (inferred). Begin with '# Cross-project connections', a blank line, then '_Last built: ${DATE}_'. Write ONLY .knowledge/connections.md."
  if claude -p "$CPROMPT" --model "$MODEL" --allowedTools "Read,Grep,Glob,Write" >/dev/null 2>&1 \
       && [ -f "$conn" ]; then
    echo "  ok    connections.md"
  else
    echo "  FAIL  connections.md"
  fi
fi

# --- Rebuild the top-level index, grouped by project ------------------------
# Mechanical (grep), so it never costs a Claude turn and can't drift from facts.
index="$KNOW_DIR/index.md"
{
  echo "# Knowledge Base"
  echo
  echo "Curated, Claude-generated knowledge for the mirrored repos, grouped by"
  echo "project. Start at a project overview to orient across a family, open a"
  echo "per-repo map or decision log to drill in, then CONFIRM in .repositories/"
  echo "and cite the real source line. These are derived, not truth."
  echo
  echo "_Last built: ${DATE}_"
  echo
  [ -f "$conn" ] && echo "**Cross-project integration graph:** [connections.md](connections.md)" && echo
  for proj in $(printf '%s\n' "${!PROJ_MEMBERS[@]}" | sort); do
    members=(${PROJ_MEMBERS[$proj]})
    ov="$KNOW_DIR/$proj/overview.md"
    if [ -f "$ov" ]; then
      echo "## Project: $proj — [overview]($proj/overview.md)"
    else
      echo "## Project: $proj"
    fi
    echo
    echo "| Repo | Summary | Map | History |"
    echo "|---|---|---|---|"
    for rname in $(printf '%s\n' "${members[@]}" | sort); do
      f="$KNOW_DIR/$rname/index.md"
      [ -f "$f" ] || continue
      rsum="$(sed -n 's/^summary: //p' "$f" | head -n1)"
      [ -z "$rsum" ] && rsum="(no summary)"
      if [ -f "$KNOW_DIR/$rname/decisions.md" ]; then
        hist="[history]($rname/decisions.md)"
      else
        hist="—"
      fi
      echo "| $rname | $rsum | [map]($rname/index.md) | $hist |"
    done
    echo
  done
} > "$index"

echo "----"
echo "digested: $digested  skipped: $skipped  failed: $failed"
echo "index: $index"
if [ "$failed" -gt 0 ]; then
  echo "failed: ${failed_names[*]}"
  exit 1
fi
