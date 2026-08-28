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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
