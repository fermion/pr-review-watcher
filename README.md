# pr-review-watcher

Watches GitHub repos for newly-opened pull requests and starts a Claude Code
review for each one — in a new tab of a single iTerm2 window, **without stealing
focus**, with a desktop notification instead.

You keep working. A notification tells you a review has started. The tab is
waiting whenever you want it.

## Requirements

- macOS (uses `launchd`, `lsappinfo`, AppleScript)
- **iTerm2** — the tab logic is iTerm2-specific
- [`gh`](https://cli.github.com) authenticated (`gh auth login`)
- `jq`
- [Claude Code](https://claude.com/claude-code) (`claude`) — or set `REVIEW_COMMAND` to anything else
- Optional: [`alerter`](https://github.com/vjeantet/alerter) for click-to-focus notifications

## Install

```sh
git clone https://github.com/<you>/pr-review-watcher.git
cd pr-review-watcher
./install.sh
$EDITOR ~/.config/pr-review-watcher/config.sh   # set REPOS and GITHUB_LOGIN
```

The repo is the install location — `install.sh` points the LaunchAgent at
`bin/pr-watch.sh` where it sits, so don't move the directory afterward (or just
re-run `install.sh` if you do).

**The first poll seeds.** Every PR already open is recorded as seen and *not*
reviewed, so you don't get a tab per existing PR. Only PRs opened afterwards
trigger a review.

macOS will ask once to let the job control iTerm2 ("Automation"). You must
allow it — see [Troubleshooting](#troubleshooting).

## Configuration

`~/.config/pr-review-watcher/config.sh`:

| Setting | Meaning |
| --- | --- |
| `REPOS` | Array of `"owner/repo:/path/to/local/checkout"`. The checkout is where the review session starts, so repo-local Claude skills resolve. |
| `GITHUB_LOGIN` | Your login; your own PRs are skipped. Empty reviews your own too. |
| `SKIP_DRAFTS` | Skip draft PRs. |
| `REVIEW_COMMAND` | Command run in the tab; `{url}` is replaced with the PR URL. The default assumes a Claude Code skill named `pr-review` that takes a PR URL — see below. |
| `MAX_LAUNCH` | Tabs per poll; `0` = unlimited. PRs over the cap are marked seen, not deferred. |
| `POLL_INTERVAL` | Seconds between polls. Re-run `install.sh` after changing. |
| `NOTIFIER` | `auto` \| `alerter` \| `osascript` \| `none`. |

### The `pr-review` skill

The default `REVIEW_COMMAND` is:

```sh
claude "/pr-review {url}"
```

which assumes you have a Claude Code skill called `pr-review` that accepts a PR
URL — for example `.claude/skills/pr-review/SKILL.md` committed in the repo
you're watching, so reviews follow that project's own conventions. The session
starts in the checkout directory named in `REPOS`, so a repo-local skill or
slash command resolves with no extra setup.

Don't have one? Either write it, or just ask in plain language:

```sh
REVIEW_COMMAND='claude "Review this pull request and report findings: {url}"'
```

Nothing here is Claude-specific — any runnable command works:

```sh
REVIEW_COMMAND='gh pr checkout {url} && my-review-tool'
```

Watch several repos at once:

```sh
REPOS=(
  "acme/api:$HOME/code/api"
  "acme/web:$HOME/code/web"
)
```

## Everyday use

```sh
tail -f ~/.local/state/pr-review-watcher/pr-watch.log   # what it's doing
bash bin/pr-watch.sh                                     # force a poll now
./uninstall.sh                                           # stop it
```

### Tests

```sh
./test.sh
```

18 checks, no network and no GUI — `gh` and the window launcher are stubbed, so
the suite runs anywhere.

**Covered:** review-command construction (default, from config, repeated
`{url}`, no leaked literals), rejection of non-GitHub URLs, first-run seeding,
already-seen dedupe, draft and own-PR filtering, `MAX_LAUNCH`, launcher
arguments, missing checkout, and `gh` failure — including that a failed poll
does *not* mark the PR seen, so it is picked up next time rather than silently
lost.

The suite is mutation-tested: deliberately removing the seeding guard, the
dedupe check, either filter, or swapping the launcher's arguments each makes it
fail.

**Not covered**, because it needs a real GUI session: iTerm2 tab creation, focus
behavior, TCC/Automation permission, and notification delivery. Those were
verified by measurement instead — see the design notes above.

Dry-run the window logic without starting a real review:

```sh
PR_REVIEW_TEST_CMD="echo hello" bin/pr-review-window.sh \
  ~/code/repo https://github.com/acme/api/pull/1 "test"
```

Note that `PR_REVIEW_TEST_CMD` *replaces* the whole command, so it bypasses
`REVIEW_COMMAND` substitution entirely. Use `./test.sh` to check that.

## How it works

`launchd` runs `bin/pr-watch.sh` on an interval. It asks `gh` for open PRs,
diffs them against a per-repo seen-list, and for each new one calls
`bin/pr-review-window.sh`, which drives iTerm2 via AppleScript.

### Design notes

Four things about macOS and iTerm2 shaped this, each found by measurement rather
than documentation:

**iTerm2 raises itself on window *and* tab creation.** Omitting `activate` is not
enough. The launcher records the frontmost app (`lsappinfo`, which needs no
permission) and restores it from *inside* the AppleScript, before the tab-naming
delay. iTerm2's raise is asynchronous and under `launchd` can land *after* that
restore, so focus is reclaimed again over the following second — but only while
iTerm2 is the one holding it, so it won't fight you if you switch there
deliberately. If iTerm2 was already frontmost, the window you were in is
re-selected instead, so a new tab can't yank you out of your work.

Measured: no detectable focus loss when adding a tab; ~100 ms when a window has
to be created.

**An iTerm2 window can't be found by name.** Its AppleScript `name` is read-only
and OSC-2 window-title escapes are ignored under the default profile. The window
is tracked by **id** and re-verified with `exists window id N`, which correctly
reports false once closed, so a stale id just means a fresh window. Tabs *are*
named (`PR #1234`) — session names are settable, but only *after* the command
starts, since iTerm2 recomputes the title then and wipes a name set earlier.

**Apple Events from `launchd` are gated by TCC.** Without Automation permission
`osascript` hangs forever — no prompt, no error, no timeout. That would silently
wedge the poller. So `osascript` runs under a watchdog and falls back to
`open -a` (LaunchServices, no permission required), which opens a window instead
of a tab.

**`alerter` blocks until the notification is dismissed.** It runs fully detached
and time-limited; in the foreground it would stall every poll.

## Troubleshooting

**No tab appears, and the log says "fallback window".** The Automation
permission is missing. Grant it in System Settings → Privacy & Security →
Automation, then `./uninstall.sh && ./install.sh`.

**No notifications.** `NOTIFIER_SENDER` must be a bundle id already allowed to
post notifications (default `com.apple.Terminal`). Check System Settings →
Notifications. With `NOTIFIER=osascript` the alert is attributed to Script Editor.

**Nothing happens at all.** `launchd` only runs while you're logged in. A
`StartInterval` due during sleep fires once on wake rather than catching up —
the seen-list means nothing is missed, just delayed. Check
`~/.local/state/pr-review-watcher/launchd.err.log`.

**It reviewed a PR I'd already seen / missed one.** State lives in
`~/.local/state/pr-review-watcher/<owner>_<repo>.seen`, one PR number per line.
Delete the matching `.seeded` marker to re-seed from scratch.

## License

MIT — see [LICENSE](LICENSE).
