#!/bin/bash
# Unload and remove the LaunchAgent. Config and state are left alone unless --purge.
set -euo pipefail
LABEL="com.pr-review-watcher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_DIR="$HOME/.local/state/pr-review-watcher"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "unloaded $LABEL" || echo "$LABEL was not loaded"
[[ -f "$PLIST" ]] && rm -f "$PLIST" && echo "removed $PLIST"

if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "$STATE_DIR" "$HOME/.config/pr-review-watcher"
  echo "purged config and state"
else
  echo "kept config and state (re-run with --purge to delete)"
fi
