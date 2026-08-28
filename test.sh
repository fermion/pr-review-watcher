#!/bin/bash
# Smoke tests for command construction -- the path that is NOT covered when you
# dry-run with PR_REVIEW_TEST_CMD. Run: ./test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }

# Stub osascript: record the command it was handed, return a plausible result.
cat > "$TMP/osascript" <<'STUB'
#!/bin/bash
cat > /dev/null
printf '%s' "$3" > "$SPY_OUT"
echo "1234,1"
STUB
chmod +x "$TMP/osascript"
sed "s|/usr/bin/osascript -|$TMP/osascript -|" "$HERE/bin/pr-review-window.sh" > "$TMP/launcher.sh"
chmod +x "$TMP/launcher.sh"

echo "-- launcher --"
URL="https://github.com/acme/api/pull/42"
run() { # run <config-file>
  export SPY_OUT="$TMP/spy.txt" PR_WATCH_CONFIG="$1" PR_WATCH_STATE_DIR="$TMP/state" NOTIFIER=none
  rm -f "$SPY_OUT"
  "$TMP/launcher.sh" "$TMP" "$URL" "title" >/dev/null 2>&1
  cat "$SPY_OUT" 2>/dev/null
}

# 1. Default REVIEW_COMMAND (config present but does not set it)
printf 'REPOS=("a/b:%s")\n' "$TMP" > "$TMP/c1.sh"
want="cd $TMP && claude \"/pr-review $URL\""
got="$(run "$TMP/c1.sh")"
[[ "$got" == "$want" ]] && ok "default REVIEW_COMMAND" || bad "default REVIEW_COMMAND" "$want" "$got"

# 2. REVIEW_COMMAND from config
printf 'REPOS=("a/b:%s")\nREVIEW_COMMAND=%s\n' "$TMP" "'claude \"/pr-review {url}\"'" > "$TMP/c2.sh"
got="$(run "$TMP/c2.sh")"
[[ "$got" == "$want" ]] && ok "REVIEW_COMMAND from config" || bad "REVIEW_COMMAND from config" "$want" "$got"

# 3. Custom REVIEW_COMMAND with the placeholder used twice
printf 'REPOS=("a/b:%s")\nREVIEW_COMMAND=%s\n' "$TMP" "'echo {url} && review {url}'" > "$TMP/c3.sh"
want3="cd $TMP && echo $URL && review $URL"
got="$(run "$TMP/c3.sh")"
[[ "$got" == "$want3" ]] && ok "placeholder substituted repeatedly" || bad "placeholder substituted repeatedly" "$want3" "$got"

# 4. No trailing junk (the {url} brace-parsing regression)
got="$(run "$TMP/c2.sh")"
[[ "$got" != *'"}'* ]] && ok "no literal \"} leaked into command" || bad "no literal \"} leaked" "no trailing \"}" "$got"

# 5. Non-GitHub URLs are refused
if PR_WATCH_CONFIG="$TMP/c2.sh" PR_WATCH_STATE_DIR="$TMP/state" \
     "$TMP/launcher.sh" "$TMP" "https://evil.example.com/x; rm -rf /" t >/dev/null 2>&1; then
  bad "rejects non-GitHub url" "non-zero exit" "exit 0"
else
  ok "rejects non-GitHub url"
fi


# ---------------------------------------------------------------------------
# pr-watch.sh: which PRs get reviewed at all
# ---------------------------------------------------------------------------
echo
echo "-- poller --"

# Stub gh: emits the fixture in $GH_FIXTURE, or fails if $GH_FAIL is set.
cat > "$TMP/gh" <<'STUB'
#!/bin/bash
case "$1" in
  auth) exit 0 ;;
esac
if [[ -n "${GH_FAIL:-}" ]]; then echo "simulated gh failure" >&2; exit 1; fi
cat "$GH_FIXTURE"
STUB
chmod +x "$TMP/gh"

# Stub launcher: records one line per invocation.
cat > "$TMP/launcher-spy.sh" <<'STUB'
#!/bin/bash
printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$LAUNCH_LOG"
STUB
chmod +x "$TMP/launcher-spy.sh"

pr_json() { # pr_json <number> <login> <draft:true|false>
  printf '{"number":%s,"url":"https://github.com/acme/api/pull/%s","title":"PR %s","isDraft":%s,"author":{"login":"%s"}}' \
    "$1" "$1" "$1" "$3" "$2"
}
fixture() { printf '[%s]\n' "$(local IFS=,; echo "$*")" > "$TMP/prs.json"; }

CHECKOUT="$TMP/checkout"; mkdir -p "$CHECKOUT"
watch_cfg() { # watch_cfg [extra config lines...]
  { printf 'REPOS=("acme/api:%s")\n' "$CHECKOUT"; printf '%s\n' "$@"; } > "$TMP/w.sh"
}
poll() { # poll -> runs pr-watch.sh against the stubs
  env PR_WATCH_EXTRA_PATH="$TMP" PR_WATCH_CONFIG="$TMP/w.sh" \
      PR_WATCH_STATE_DIR="$TMP/wstate" PR_WATCH_LAUNCHER="$TMP/launcher-spy.sh" \
      GH_FIXTURE="$TMP/prs.json" LAUNCH_LOG="$TMP/launched.txt" \
      ${GH_FAIL:+GH_FAIL=1} \
      /bin/bash "$HERE/bin/pr-watch.sh"
}
reset_poller() { rm -rf "$TMP/wstate" "$TMP/launched.txt"; }
launches() { [[ -f "$TMP/launched.txt" ]] && wc -l < "$TMP/launched.txt" | tr -d ' ' || echo 0; }

# 6. First run seeds without reviewing anything
reset_poller; watch_cfg
fixture "$(pr_json 1 alice false)" "$(pr_json 2 bob false)" "$(pr_json 3 carol false)"
poll >/dev/null 2>&1
n="$(launches)"
[[ "$n" == "0" ]] && ok "first run seeds, launches nothing" || bad "first run seeds" "0 launches" "$n"
seen="$(wc -l < "$TMP/wstate/acme_api.seen" | tr -d ' ')"
[[ "$seen" == "3" ]] && ok "first run records all open PRs as seen" || bad "seeding records PRs" "3" "$seen"

# 7. Re-polling the same PRs launches nothing
poll >/dev/null 2>&1
n="$(launches)"
[[ "$n" == "0" ]] && ok "already-seen PRs are not re-reviewed" || bad "no re-review" "0" "$n"

# 8. A genuinely new PR launches exactly once, with the right arguments
fixture "$(pr_json 1 alice false)" "$(pr_json 2 bob false)" "$(pr_json 3 carol false)" "$(pr_json 4 dave false)"
poll >/dev/null 2>&1
n="$(launches)"
[[ "$n" == "1" ]] && ok "new PR launches exactly once" || bad "new PR launches once" "1" "$n"
want="$CHECKOUT|https://github.com/acme/api/pull/4|PR 4"
got="$(cat "$TMP/launched.txt" 2>/dev/null)"
[[ "$got" == "$want" ]] && ok "launcher gets checkout, url, title" || bad "launcher args" "$want" "$got"

# 9. Drafts skipped
reset_poller; watch_cfg 'SKIP_DRAFTS=true'
fixture "$(pr_json 1 alice false)"
poll >/dev/null 2>&1                                   # seed
fixture "$(pr_json 1 alice false)" "$(pr_json 9 eve true)"
poll >/dev/null 2>&1
n="$(launches)"
[[ "$n" == "0" ]] && ok "draft PRs are skipped" || bad "drafts skipped" "0" "$n"

# 10. Your own PRs skipped
reset_poller; watch_cfg 'GITHUB_LOGIN="alice"'
fixture "$(pr_json 1 bob false)"
poll >/dev/null 2>&1                                   # seed
fixture "$(pr_json 1 bob false)" "$(pr_json 7 alice false)" "$(pr_json 8 bob false)"
poll >/dev/null 2>&1
got="$(cat "$TMP/launched.txt" 2>/dev/null)"
[[ "$got" == *"/pull/8"* && "$got" != *"/pull/7"* ]] \
  && ok "own PRs skipped, others reviewed" || bad "own PRs skipped" "only /pull/8" "$got"

# 11. MAX_LAUNCH caps launches but still marks the rest seen (they are not deferred)
reset_poller; watch_cfg 'MAX_LAUNCH=1'
fixture "$(pr_json 1 bob false)"
poll >/dev/null 2>&1                                   # seed
fixture "$(pr_json 1 bob false)" "$(pr_json 2 bob false)" "$(pr_json 3 bob false)"
poll >/dev/null 2>&1
n="$(launches)"
[[ "$n" == "1" ]] && ok "MAX_LAUNCH caps launches per poll" || bad "MAX_LAUNCH cap" "1" "$n"
poll >/dev/null 2>&1
n="$(launches)"
[[ "$n" == "1" ]] && ok "capped PRs are marked seen, not deferred" || bad "capped PRs marked seen" "1" "$n"

# 12. gh failure: no launches, no crash, and the PR is NOT marked seen
reset_poller; watch_cfg
fixture "$(pr_json 1 bob false)"
poll >/dev/null 2>&1                                   # seed
fixture "$(pr_json 1 bob false)" "$(pr_json 5 bob false)"
GH_FAIL=1 poll >/dev/null 2>&1; rc=$?
unset GH_FAIL
[[ $rc -eq 0 ]] && ok "gh failure exits cleanly" || bad "gh failure exit" "0" "$rc"
grep -qx 5 "$TMP/wstate/acme_api.seen" \
  && bad "gh failure must not mark PRs seen" "5 absent" "5 present" \
  || ok "gh failure does not swallow the PR"
poll >/dev/null 2>&1
n="$(launches)"
[[ "$n" == "1" ]] && ok "PR is picked up on the next successful poll" || bad "recovery after gh failure" "1" "$n"

# 13. Missing checkout directory is skipped, not fatal
reset_poller
{ printf 'REPOS=("acme/api:%s/definitely-not-here")\n' "$TMP"; } > "$TMP/w.sh"
fixture "$(pr_json 1 bob false)"
poll >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 && "$(launches)" == "0" ]] \
  && ok "missing checkout is skipped, not fatal" || bad "missing checkout" "exit 0, 0 launches" "exit $rc, $(launches) launches"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
