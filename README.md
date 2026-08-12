# Termi

A little terminal-window mascot that lives on your menu bar and shows what your
Claude Code sessions are doing — idle, working, waiting on you, or finished —
without you having to check every terminal tab yourself.

Built for people who already run Claude Code from Terminal.app and want an
ambient, at-a-glance signal instead of alt-tabbing between windows.

![Termi mascot cycling through its states](docs/images/hero.gif)

## Features

- **Five states**: idle (breathes, blinks), working (bobs, "types", eyes scan),
  needs you (jumps with a `?` while it's the top-priority session), finished (a
  few hops with a `✓`, then settles after ~4s — the badge is the persistent
  signal, not this pose), and no-sessions (disappears entirely).
- **Three badges**, independent of whatever the big pose is showing:
  - top-right, blue — total open sessions (2+)
  - top-left, orange — how many sessions are `asking`; clears only when the
    question is actually answered
  - top-left, green — how many sessions have `finished` and you haven't looked
    yet; clears only by switching to the terminal window that finished

  | Idle | Working | Needs you | Finished |
  |---|---|---|---|
  | ![idle](docs/images/state-idle.png) | ![working](docs/images/state-working.png) | ![asking](docs/images/state-asking.png) | ![done](docs/images/state-done.png) |

- **Session list popover** — click the mascot for every open session and its
  real state. Optional live "elapsed time" column and usage-limit footer.
  Fully keyboard-navigable: `⌘↓`/`⌘↑` to highlight, `⌘↩` to jump straight to
  that session's terminal.

  ![Session list popover](docs/images/popover.png)

- **Preferences window** — sort order (including custom drag-to-reorder),
  which columns show, alert volume with real amplification above the normal
  range, and a sound picker grouped by character with per-sound preview.

## Requirements

- macOS 14+
- Xcode Command Line Tools (`xcode-select --install`)
- [jq](https://jqlang.org)
- Terminal.app — sessions in other terminal apps are still tracked and
  alerted, but two conveniences are Terminal.app-specific: dismissing the
  green badge by reopening that window, and `⌘↩` jumping to a session

## Install

```sh
git clone https://github.com/Maxing5/termi-app.git
cd termi-app
./install.sh
open -a ~/Applications/Termi.app
```

`install.sh` merges Termi's hooks into `~/.claude/settings.json` — it only
touches entries that are already Termi's own, so any other hooks you have
registered are left alone — installs the hook script to `~/.claude/termi/`,
then builds, ad-hoc signs, and installs the app to `~/Applications`. Safe to
re-run any time, including after `git pull`.

Hooks apply to new sessions; ones already running when you install won't be
tracked until restarted.

Since the app is ad-hoc signed (built locally, not notarized by Apple), macOS
may still show a Gatekeeper warning the first time you open it. If so,
right-click `Termi.app` → **Open** once.

### Updates

There's no auto-install — Termi checks GitHub for a newer release about
once a day, and if one exists, an **"Update available"** item appears in the
menu bar (see below); clicking it opens the release page. Applying it is
still manual:

```sh
git pull
./install.sh
```

(Ad-hoc signing means a real Sparkle-style silent update would still hit
Gatekeeper the same way a fresh download does, so this stops short of that.)

Optionally, run `./install-statusline.sh` once to enable the usage-limit %
shown in the session list — Claude Code only exposes that number to
statusline commands, so this wraps your existing statusline script to also
cache it for Termi. It doesn't edit your script; your statusline's actual
output is completely unchanged.

## Using it

The menu bar icon (a terminal glyph) has:

| Item | What it does |
|---|---|
| Show / Hide Mascot | Manual override, independent of session state |
| Reset Position | Snaps back to the default corner |
| Lock Position | Disables dragging; clicking still works |
| Mascot Size | Slider + buttons, 50–250%, snaps in 10% steps, resizes around its own centre |
| Update available *(only when one exists)* | Opens the GitHub release page — see [Updates](#updates) |
| Preferences… | Opens the settings window (see below) |
| Play Sounds | Toggle alert sounds on/off |
| Desktop Notifications | Off by default — banner notification alongside the sound |
| Start at Login | Writes a LaunchAgent |
| Quit Termi | — |
| Termi vX.Y.Z | Not clickable — just shows the installed version |

![Menu bar dropdown](docs/images/menu.png)

The first time a session finishes or asks a question, macOS will ask you to
approve Termi controlling Terminal.app — that's a read-only query for which
tab is frontmost, used for the badge-dismiss and `⌘↩` features.

### Preferences

**Popup tab** — show/hide the elapsed-time column (working sessions only),
show/hide the usage-limit footer, and sort mode: state priority (default),
folder name, most recently active, longest running, or a custom order you
drag into place.

![Preferences — Popup tab](docs/images/preferences-popup.png)

**Alerts tab** — volume (0–100%; 80% is today's normal full volume, 80–100%
applies real digital amplification above that, not just a louder-sounding
label), and a sound picker grouped by character (Gentle / Bright / Attention
/ Low) with a ▶ next to each sound to preview it without selecting it.

![Preferences — Alerts tab](docs/images/preferences-alerts.png)

## How it works

Claude Code hooks write one small JSON file per session into
`~/.claude/termi/sessions/`. The app watches that directory and renders the
highest-priority state (`needs you` > `finished` > `working` > `idle`).

```
claude session ──hook──▶ hooks/termi-state.sh ──▶ ~/.claude/termi/sessions/<id>.json
                                                            │ FSEvents
                                                            ▼
                                                        Termi.app
```

Nothing talks over a socket or a port. The two halves only share a directory,
so either can restart independently and state is rebuilt from disk.

## Hook contract

Verified empirically, not assumed:

| Hook | Matcher | State |
|---|---|---|
| `SessionStart` | — | `idle` |
| `UserPromptSubmit` | — | `working` |
| `PreToolUse` | `AskUserQuestion` | `asking` |
| `PostToolUse` | `*` | `working` (also a heartbeat) |
| `Notification` | — | `asking`, **only** if `notification_type == "permission_prompt"` |
| `Stop` | — | `done` |
| `SessionEnd` | — | file deleted |

Two details worth knowing:

- `Notification` also fires for plain "you've been idle" nudges. The payload
  carries `notification_type`, so the script keys off that rather than
  guessing — otherwise the mascot would beg for attention every time you
  walked away from an idle session.
- There is deliberately **no** generic `PreToolUse` hook. Registering both `*`
  and `AskUserQuestion` on the same event races, and `asking` would sometimes
  lose to `working`. `UserPromptSubmit` covers turn start instead.

## Session cleanup

`SessionEnd` removes the file on a clean exit. A `kill -9`'d terminal never
fires it, so the app also prunes any session whose recorded `ppid` is no
longer alive — checked by liveness alone, never by age. A session can go idle
for days (a laptop closed overnight, for instance) without ever being pruned,
as long as the process behind it is genuinely still running.

Sessions already running before Termi's hooks were installed are picked up
automatically by scanning for `claude` processes with no tracked file. Their
folder name is resolved from an orphaned transcript in
`~/.claude/projects/` when the match is unambiguous (exactly one untracked
process, exactly one candidate transcript); otherwise it falls back to a
less precise guess from the process's own working directory.

## Uninstall

```sh
# Quit the app and remove it
osascript -e 'tell application "Termi" to quit' 2>/dev/null
rm -rf ~/Applications/Termi.app

# Remove the hooks (restores your settings.json from before Termi installed them)
cp ~/.claude/settings.json.termi-backup ~/.claude/settings.json

# Remove Termi's own files (hook script, session state, cached usage limits)
rm -rf ~/.claude/termi

# Remove all Termi settings
rm -f ~/Library/Preferences/com.termi.app.plist

# If you ever enabled Start at Login
launchctl unload -w ~/Library/LaunchAgents/com.termi.app.plist 2>/dev/null
rm -f ~/Library/LaunchAgents/com.termi.app.plist

# If you ran install-statusline.sh
rm -f ~/.claude/statusline-command.sh
mv ~/.claude/statusline-command.termi-original.sh ~/.claude/statusline-command.sh
```

## Development

```sh
swift build && ./.build/debug/Termi     # run unbundled
./demo.sh                               # ~40s tour of every state
./demo.sh asking                        # hold one state until Ctrl-C
./hooks/termi-fake.sh working portfolio # inject a fake session
./hooks/termi-fake.sh clear
```

`TERMI_DIR=/some/dir` points the app at a scratch session directory instead
of the real one — that's how `demo.sh` avoids interfering with live
sessions.

All character geometry is in `Rig` and all motion is in `Pose.make` — both in
`Sources/Termi/MascotView.swift`. Motion is a pure function of `(state,
time)`, so changing a number and rebuilding (~3s) is the whole iteration
loop, and a state change can never leave a stuck half-finished animation
behind.

### Cutting a release

`VERSION` is the single source of truth `make-app.sh` reads into
`CFBundleShortVersionString`, and what running copies compare themselves
against (see [Updates](#updates)):

```sh
echo "1.2.0" > VERSION
git add VERSION && git commit -m "Bump version to 1.2.0"
git tag v1.2.0
git push && git push --tags
gh release create v1.2.0 --title v1.2.0 --notes "..."
```

## Project structure

```
VERSION                   current release version — read by make-app.sh, checked against GitHub
install.sh                install hooks + build + install the app (start here)
install-statusline.sh     optional: enables the usage-limit % column
make-app.sh                build + bundle + ad-hoc sign (called by install.sh)
demo.sh                    scripted tour of every state, for development
hooks/
  termi-state.sh            hook → state file (bash + jq, always exits 0)
  termi-fake.sh              inject synthetic sessions for testing
Sources/Termi/
  main.swift                  entry point, single-instance guard
  AppDelegate.swift            menu bar, popover, keyboard nav, app lifecycle
  MascotPanel.swift            borderless always-on-top window, drag vs click, resize
  MascotView.swift             the character: Rig (geometry) + Pose (motion)
  MascotSizeControl.swift      the menu bar size slider
  MascotState.swift            state enum, priorities, tuning constants
  MascotSettings.swift         all persisted settings
  SessionStore.swift           directory watch, pruning, aggregate state, alerts
  SessionListView.swift        the popover UI
  SessionMetrics.swift         usage-limit reading, elapsed-time formatting
  ProcessDiscovery.swift       finds untracked claude processes + resolves their cwd
  TerminalFocusWatcher.swift   badge-dismiss and ⌘↩ jump-to-terminal
  SoundLibrary.swift           sound playback, including the volume-boost path
  SoundPickerRow.swift         the sound picker UI
  Notifier.swift                sound + optional desktop notification dispatch
  PreferencesView.swift         the Preferences window
  LoginItem.swift               LaunchAgent start-at-login
  UpdateChecker.swift           once-a-day GitHub release check, no auto-install
```

## Known limitations

- Terminal.app-specific features (badge dismiss by reopening, `⌘↩`) don't
  work in other terminal apps — sessions there are still fully tracked and
  alerted otherwise.
- Ad-hoc signed, not notarized — a locally built binary, so this is ordinary
  Gatekeeper behavior, not a sign of anything wrong with the build.
- macOS only.

## License

MIT — see [LICENSE](LICENSE).
