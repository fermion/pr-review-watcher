#!/bin/bash
# Poll GitHub for newly-opened pull requests and start a Claude review for each.
# Normally run by the LaunchAgent installed by install.sh; safe to run by hand.
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

CONFIG="${PR_WATCH_CONFIG:-$HOME/.config/pr-review-watcher/config.sh}"
STATE_DIR="${PR_WATCH_STATE_DIR:-$HOME/.local/state/pr-review-watcher}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER="${PR_WATCH_LAUNCHER:-$HERE/pr-review-window.sh}"
LOG="$STATE_DIR/pr-watch.log"

mkdir -p "$STATE_DIR"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

if [[ ! -f "$CONFIG" ]]; then
  log "no config at $CONFIG - run install.sh"
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG"

: "${REPOS:?config must define REPOS}"
GITHUB_LOGIN="${GITHUB_LOGIN:-}"
SKIP_DRAFTS="${SKIP_DRAFTS:-true}"
MAX_LAUNCH="${MAX_LAUNCH:-0}"

for tool in gh jq; do
  command -v "$tool" >/dev/null 2>&1 || { log "missing dependency: $tool"; exit 1; }
done

# Build the jq selector from config.
filter='.[]'
[[ "$SKIP_DRAFTS" == "true" ]] && filter="$filter | select(.isDraft | not)"
[[ -n "$GITHUB_LOGIN" ]]      && filter="$filter | select(.author.login != \$me)"
filter="$filter | [.number, .url, .title] | @tsv"

for entry in "${REPOS[@]}"; do
  repo="${entry%%:*}"
  workdir="${entry#*:}"
  slug="${repo//\//_}"
  seen="$STATE_DIR/$slug.seen"
  touch "$seen"

  if [[ ! -d "$workdir" ]]; then
    log "[$repo] checkout not found at $workdir - skipping"
    continue
  fi

  if ! prs=$(gh pr list --repo "$repo" --state open --limit 100 \
        --json number,url,title,isDraft,author 2>>"$LOG"); then
    log "[$repo] gh pr list failed - skipping this run"
    continue
  fi

  rows=$(printf '%s' "$prs" | jq -r --arg me "$GITHUB_LOGIN" "$filter")

  # First run for a repo: record what is already open WITHOUT launching, so you
  # do not get a review tab for every pre-existing PR.
  if [[ ! -f "$STATE_DIR/$slug.seeded" ]]; then
    printf '%s' "$rows" | cut -f1 >> "$seen"
    touch "$STATE_DIR/$slug.seeded"
    log "[$repo] seeded $(printf '%s' "$rows" | grep -c . || true) existing PRs; watching from now on"
    continue
  fi

  launched=0
  while IFS=$'\t' read -r num url title; do
    [[ -z "${num:-}" ]] && continue
    grep -qx "$num" "$seen" && continue

    echo "$num" >> "$seen"

    if (( MAX_LAUNCH > 0 && launched >= MAX_LAUNCH )); then
      log "[$repo] #$num marked seen but not launched (MAX_LAUNCH=$MAX_LAUNCH)"
      continue
    fi

    log "[$repo] new PR #$num: $title"
    if "$LAUNCHER" "$workdir" "$url" "$title" >>"$LOG" 2>&1; then
      launched=$(( launched + 1 ))
    else
      log "[$repo] #$num FAILED to open review tab"
    fi
  done <<< "$rows"
done
