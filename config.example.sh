# shellcheck shell=bash
# pr-review-watcher configuration.
# Copied to ~/.config/pr-review-watcher/config.sh by install.sh. Edit that copy.

# Repos to watch, as "owner/repo:/absolute/path/to/local/checkout".
# The checkout is the directory the review session starts in, so repo-local
# Claude skills (e.g. .claude/skills/pr-review) resolve.
REPOS=(
  "owner/repo:$HOME/code/repo"
)

# Your GitHub login. PRs you authored are skipped. Leave empty to review your own too.
GITHUB_LOGIN=""

# Skip PRs still marked draft.
SKIP_DRAFTS=true

# Command run in the new tab. {url} is replaced with the pull request URL.
#
# The default assumes you have a Claude Code skill called `pr-review` that takes
# a PR URL -- say, .claude/skills/pr-review/SKILL.md inside the repo you are
# watching, so the review follows that project's own conventions. The session
# starts in the checkout directory named in REPOS, so a repo-local skill (or
# slash command) resolves without any extra setup.
#
# If you do not have such a skill, either write one, or just ask for the review
# in plain language:
#
#   REVIEW_COMMAND='claude "Review this pull request and report findings: {url}"'
#
# Anything runnable works here -- it does not have to be Claude:
#
#   REVIEW_COMMAND='gh pr checkout {url} && my-review-tool'
REVIEW_COMMAND='claude "/pr-review {url}"'

# Max review tabs to open per poll. 0 = unlimited.
# A cap only matters if you are worried about a burst of PRs opening many tabs;
# PRs above the cap are still marked seen, so they are not reviewed later.
MAX_LAUNCH=0

# Seconds between polls. Read by install.sh when generating the LaunchAgent;
# re-run install.sh after changing it.
POLL_INTERVAL=300

# Desktop notification backend: auto | alerter | osascript | none
#   auto     - use alerter if present, else osascript
#   alerter  - https://github.com/vjeantet/alerter (supports click-to-focus)
#   osascript- built in, no click-to-focus
NOTIFIER="auto"

# Where iTerm2 lives, if not in the default location.
ITERM_APP="/Applications/iTerm.app"

# Path to alerter, if you use it.
ALERTER="$HOME/bin/alerter"

# Bundle id used as the notification's sender. It must be an app already allowed
# to post notifications, or nothing appears. Terminal is a safe default.
NOTIFIER_SENDER="com.apple.Terminal"
