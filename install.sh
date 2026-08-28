#!/bin/bash
# Install pr-review-watcher: write a config, generate a LaunchAgent, load it.
# Safe to re-run; an existing config is never overwritten.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.pr-review-watcher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG_DIR="$HOME/.config/pr-review-watcher"
CONFIG="$CONFIG_DIR/config.sh"
STATE_DIR="$HOME/.local/state/pr-review-watcher"

say() { printf '  %s\n' "$*"; }

echo "==> Checking dependencies"
missing=0
for tool in gh jq osascript lsappinfo; do
  if command -v "$tool" >/dev/null 2>&1; then say "ok       $tool"
  else say "MISSING  $tool"; missing=1; fi
done
if [[ -d /Applications/iTerm.app ]]; then say "ok       iTerm2"
else say "MISSING  iTerm2 (required - the tab logic is iTerm2-specific)"; missing=1; fi
command -v claude >/dev/null 2>&1 && say "ok       claude" || say "warning  claude not on PATH (needed unless you change REVIEW_COMMAND)"
(( missing )) && { echo "Install the missing tools and re-run."; exit 1; }

if ! gh auth status >/dev/null 2>&1; then
  echo "==> gh is not authenticated. Run: gh auth login"
  exit 1
fi
say "ok       gh authenticated"

echo "==> Config"
mkdir -p "$CONFIG_DIR" "$STATE_DIR"
if [[ -f "$CONFIG" ]]; then
  say "keeping existing $CONFIG"
else
  cp "$HERE/config.example.sh" "$CONFIG"
  say "created $CONFIG"
  say "EDIT IT before the first poll: set REPOS and GITHUB_LOGIN."
fi
# shellcheck disable=SC1090
source "$CONFIG"
POLL_INTERVAL="${POLL_INTERVAL:-300}"

echo "==> LaunchAgent"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$HERE/bin/pr-watch.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>$POLL_INTERVAL</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>$HOME</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$STATE_DIR/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$STATE_DIR/launchd.err.log</string>
</dict>
</plist>
PLIST_EOF
plutil -lint "$PLIST" >/dev/null && say "wrote $PLIST (every ${POLL_INTERVAL}s)"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
say "loaded"

cat <<NOTE

==> Done.

    The first poll SEEDS every currently-open PR without reviewing it, so you
    do not get a tab per existing PR. Only PRs opened after that trigger a review.

    Logs      tail -f $STATE_DIR/pr-watch.log
    Run now   bash $HERE/bin/pr-watch.sh
    Disable   bash $HERE/uninstall.sh

    First time only: macOS will ask to let the job control iTerm2 ("Automation").
    You must allow it, or tabs cannot be created. If the prompt is missed the
    watcher falls back to opening a plain window instead of a tab.
NOTE
