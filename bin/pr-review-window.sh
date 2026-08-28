#!/bin/bash
# Open a Claude review session as a new TAB in one persistent iTerm2 window,
# without stealing focus, and post a desktop notification instead.
#
# Usage: pr-review-window.sh <checkout-dir> <pr-url> [pr-title]
#
# Three non-obvious constraints drove this design, all verified by measurement:
#
# 1. Focus. iTerm2 raises itself when a window OR a tab is created -- omitting
#    `activate` is NOT enough. So we record the frontmost app first (lsappinfo,
#    which needs no permission) and restore it from *inside* the AppleScript,
#    before the tab-naming delay. iTerm2's raise is asynchronous and under
#    launchd can land AFTER that restore, so reclaim_focus() re-checks for ~1s.
#    If iTerm2 was already frontmost we instead re-select the exact window you
#    were in, so a new tab cannot yank you out of the one you are working in.
#
# 2. Window identity. iTerm2's window `name` is READ-ONLY and OSC-2 window-title
#    escapes are ignored, so a window cannot be found by name. We remember its id
#    and re-verify with `exists window id N`, which correctly reports false once
#    the window is closed.
#
# 3. TCC. Apple Events from a launchd agent require Automation permission. Absent
#    it, osascript HANGS FOREVER with no prompt and no error, which would wedge
#    the poller. So osascript runs under a watchdog and falls back to `open -a`
#    (LaunchServices, no permission; opens a window rather than a tab).
set -euo pipefail

workdir="$1"
prurl="$2"
prtitle="${3:-}"

CONFIG="${PR_WATCH_CONFIG:-$HOME/.config/pr-review-watcher/config.sh}"
STATE_DIR="${PR_WATCH_STATE_DIR:-$HOME/.local/state/pr-review-watcher}"
# shellcheck disable=SC1090
[[ -f "$CONFIG" ]] && source "$CONFIG"

# NOT ${REVIEW_COMMAND:-...}: bash ends a ${...} at the first unescaped `}`,
# which inside a default containing "{url}" is the brace of {url} itself -- the
# rest of the default then leaks out as literal text appended to the command.
if [[ -z "${REVIEW_COMMAND:-}" ]]; then
  REVIEW_COMMAND='claude "/pr-review {url}"'
fi
NOTIFIER="${NOTIFIER:-auto}"
ALERTER="${ALERTER:-$HOME/bin/alerter}"
NOTIFIER_SENDER="${NOTIFIER_SENDER:-com.apple.Terminal}"
ITERM_APP="${ITERM_APP:-/Applications/iTerm.app}"

WIN_ID_FILE="$STATE_DIR/window-id"
OSA_TIMEOUT=20
NOTIFY_TIMEOUT=30
ITERM_BID="com.googlecode.iterm2"
mkdir -p "$STATE_DIR"

# Refuse anything that is not a real GitHub PR URL before interpolating it.
if ! [[ "$prurl" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+$ ]]; then
  echo "pr-review-window: refusing suspicious PR url: $prurl" >&2
  exit 1
fi
prnum="${prurl##*/}"

# PR_REVIEW_TEST_CMD dry-runs the window/tab logic without starting a review.
if [[ -n "${PR_REVIEW_TEST_CMD:-}" ]]; then
  cmd="$PR_REVIEW_TEST_CMD"
else
  cmd="cd $(printf '%q' "$workdir") && ${REVIEW_COMMAND//\{url\}/$prurl}"
fi

# --- focus bookkeeping -------------------------------------------------------
current_front_bid() {
  lsappinfo info -only bundleid "$(lsappinfo front 2>/dev/null)" 2>/dev/null \
    | sed 's/.*"CFBundleIdentifier"="//; s/"$//'
}

front_bid="$(current_front_bid || true)"
case "$front_bid" in *[!A-Za-z0-9.-]*|"") front_bid="" ;; esac
if [[ "$front_bid" == "$ITERM_BID" ]]; then restore_arg=""; else restore_arg="$front_bid"; fi

reclaim_focus() {
  [[ -n "$restore_arg" ]] || return 0
  local t
  for t in 0.25 0.35 0.4; do
    perl -e "select(undef,undef,undef,$t)" 2>/dev/null || sleep 1
    [[ "$(current_front_bid)" == "$ITERM_BID" ]] || return 0
    open -b "$restore_arg" 2>/dev/null || true
  done
}

fallback_open_window() {
  local launch_dir="$STATE_DIR/launchers"
  mkdir -p "$launch_dir"
  find "$launch_dir" -name '*.command' -mtime +1 -delete 2>/dev/null || true
  local script="$launch_dir/pr-review-$(date +%s)-$$.command"
  printf '#!/bin/bash\n%s\n' "$cmd" > "$script"
  chmod +x "$script"
  open -g -a "$ITERM_APP" "$script" 2>/dev/null || open -a "$ITERM_APP" "$script"
}

# --- create the tab ----------------------------------------------------------
saved_id="$(cat "$WIN_ID_FILE" 2>/dev/null || true)"
osa_out="$STATE_DIR/.osa-out.$$"

/usr/bin/osascript - "$saved_id" "$cmd" "PR #$prnum" "$restore_arg" > "$osa_out" 2>&1 <<'APPLESCRIPT' &
on run argv
  set savedID to item 1 of argv
  set theCmd to item 2 of argv
  set tabName to item 3 of argv
  set restoreBid to item 4 of argv

  tell application id "com.googlecode.iterm2"
    -- No `activate`: never pull iTerm forward.

    -- If iTerm was already the front app, remember the window you were in.
    set priorWin to missing value
    if restoreBid is "" then
      try
        set priorWin to id of current window
      end try
    end if

    set targetWindow to missing value
    if savedID is not "" then
      try
        set wid to savedID as integer
        if (exists window id wid) then set targetWindow to window id wid
      end try
    end if

    if targetWindow is missing value then
      set targetWindow to (create window with default profile)
      set theSession to current session of targetWindow
    else
      set newTab to (create tab with default profile) of targetWindow
      set theSession to current session of newTab
    end if

    tell theSession to write text theCmd

    -- Give focus back IMMEDIATELY, before the tab-naming delay below.
    if restoreBid is not "" then
      try
        do shell script "open -b " & quoted form of restoreBid
      end try
    else if priorWin is not missing value then
      try
        tell window id priorWin to select
      end try
    end if

    -- Order matters: iTerm2 recomputes the title when the command starts, which
    -- wipes a name set beforehand. Write first, settle, then name the tab.
    delay 0.6
    try
      tell theSession to set name to tabName
    end try

    return ((id of targetWindow) as text) & "," & ((count of tabs of targetWindow) as text)
  end tell
end run
APPLESCRIPT
osa_pid=$!

# Watchdog. Exits on its own once osascript is reaped; killing it would emit a
# stray job-control notice into the log.
( while kill -0 "$osa_pid" 2>/dev/null; do
    sleep 1
    waited=$(( ${waited:-0} + 1 ))
    if (( waited >= OSA_TIMEOUT )); then kill -9 "$osa_pid" 2>/dev/null; exit 0; fi
  done ) >/dev/null 2>&1 &

# stderr muted only to swallow bash's job-control notice if the watchdog fires.
osa_status=0
{ wait "$osa_pid" || osa_status=$?; } 2>/dev/null

result="$(tr -d '[:space:]' < "$osa_out" 2>/dev/null || true)"
rm -f "$osa_out"

if (( osa_status != 0 )) || ! [[ "$result" =~ ^[0-9]+,[0-9]+$ ]]; then
  echo "pr-review-window: osascript failed (status=$osa_status output='$result') -> fallback window" >&2
  fallback_open_window
  exit 0
fi

new_id="${result%%,*}"
tab_idx="${result##*,}"
reclaim_focus
printf '%s\n' "$new_id" > "$WIN_ID_FILE"
echo "pr-review-window: PR #$prnum -> tab $tab_idx of window $new_id (focus kept on ${front_bid:-unknown})"

# --- notify ------------------------------------------------------------------
notifier="$NOTIFIER"
if [[ "$notifier" == "auto" ]]; then
  if [[ -x "$ALERTER" ]]; then notifier="alerter"; else notifier="osascript"; fi
fi

n_title="Claude PR review started"
n_msg="PR #$prnum"
[[ -n "$prtitle" ]] && n_msg="$n_msg — $prtitle"

case "$notifier" in
  alerter)
    # alerter BLOCKS until dismissed, so it must never run in the foreground of
    # the poller. Detached, with a timeout.
    (
      res="$("$ALERTER" -title "$n_title" -message "$n_msg" \
               -sender "$NOTIFIER_SENDER" -group "pr-review-$prnum" \
               -timeout "$NOTIFY_TIMEOUT" 2>/dev/null || true)"
      if [[ "$res" == "@CONTENTCLICKED" ]]; then
        /usr/bin/osascript -e "tell application id \"$ITERM_BID\"
          activate
          try
            tell tab $tab_idx of window id $new_id to select
          end try
        end tell" >/dev/null 2>&1
      fi
    ) >/dev/null 2>&1 &
    disown 2>/dev/null || true
    ;;
  osascript)
    esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
    ( /usr/bin/osascript -e "display notification \"$(esc "$n_msg")\" with title \"$(esc "$n_title")\"" \
        >/dev/null 2>&1 ) &
    disown 2>/dev/null || true
    ;;
  none) : ;;
esac
