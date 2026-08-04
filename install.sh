#!/bin/bash
# install.sh — one-shot setup: registers Termi's hooks with Claude Code, then
# builds and installs the app.
#
# Safe to re-run any time (e.g. after `git pull`) — every step here is idempotent.

set -euo pipefail
cd "$(dirname "$0")"
REPO_DIR="$(pwd)"

echo "==> checking dependencies"
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not found." >&2
  echo "Install it with: brew install jq" >&2
  echo "(if you don't have Homebrew: https://brew.sh)" >&2
  exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
  echo "Swift is required but not found." >&2
  echo "Install the Xcode Command Line Tools with: xcode-select --install" >&2
  exit 1
fi

# --- 1. Install the hook script somewhere stable -----------------------------
#
# Deliberately NOT the repo's own hooks/ directory: settings.json will point at
# this path, so if it pointed at the repo directly, moving or deleting the repo
# after install would silently break every hook. Copying it into ~/.claude/termi
# decouples the two — the repo can move or be deleted once this step is done.

HOOK_DIR="$HOME/.claude/termi/hooks"
HOOK_SCRIPT="$HOOK_DIR/termi-state.sh"

echo "==> installing hook script"
mkdir -p "$HOOK_DIR"
cp "$REPO_DIR/hooks/termi-state.sh" "$HOOK_SCRIPT"
chmod +x "$HOOK_SCRIPT"

# --- 2. Register hooks in ~/.claude/settings.json -----------------------------
#
# Merged in, not overwritten: your settings.json may already have other hooks
# (yours or another tool's) registered on these same events, especially
# PostToolUse/PreToolUse which are common. Each event below keeps every existing
# entry that isn't one of Termi's own (matched by the hook script's path), then
# adds Termi's fresh entry — so this is safe to run once, twice, or after an
# upgrade, and never touches anything that isn't Termi's.

SETTINGS="$HOME/.claude/settings.json"
echo "==> registering hooks in $SETTINGS"

mkdir -p "$(dirname "$SETTINGS")"
if [ ! -f "$SETTINGS" ]; then
  echo '{}' > "$SETTINGS"
fi
cp "$SETTINGS" "$SETTINGS.termi-backup"

TMP="$(mktemp)"
jq \
  --arg hook "$HOOK_SCRIPT" \
  '
  def entry(state): {"hooks": [{"type": "command", "command": ($hook + " " + state)}]};
  def entryMatcher(matcher; state): {"matcher": matcher, "hooks": [{"type": "command", "command": ($hook + " " + state)}]};
  # Match on the script basename, not the full path: an install from before
  # this script existed (or a previous checkout at a different location) would
  # have registered termi-state.sh under a different path, and a full-path match
  # would fail to recognize it as "ours" -- leaving a stale duplicate hook running
  # alongside the fresh one instead of replacing it.
  def isOurs: (.hooks[0].command // "") | contains("termi-state.sh");
  def replaceEvent(name; newEntry):
    (.hooks[name] // []) as $existing
    | ($existing | map(select(isOurs | not))) as $kept
    | .hooks[name] = ($kept + [newEntry]);

  .hooks = (.hooks // {})
  | replaceEvent("SessionStart"; entry("idle"))
  | replaceEvent("UserPromptSubmit"; entry("working"))
  | replaceEvent("PreToolUse"; entryMatcher("AskUserQuestion"; "asking"))
  | replaceEvent("PostToolUse"; entryMatcher("*"; "working"))
  | replaceEvent("Notification"; entry("notify"))
  | replaceEvent("Stop"; entry("done"))
  | replaceEvent("SessionEnd"; entry("end"))
  ' \
  "$SETTINGS" > "$TMP"

if jq empty "$TMP" 2>/dev/null; then
  mv "$TMP" "$SETTINGS"
  echo "    done (backup at $SETTINGS.termi-backup)"
else
  echo "    FAILED to produce valid JSON — leaving $SETTINGS untouched." >&2
  echo "    See $TMP for what went wrong." >&2
  exit 1
fi

# --- 3. Build and install the app --------------------------------------------

echo "==> building and installing Termi.app"
"$REPO_DIR/make-app.sh"

echo
echo "Setup complete."
echo "  - New Claude Code sessions will be tracked automatically."
echo "  - Sessions already running won't be tracked until restarted."
echo "  - Open Termi from ~/Applications, or: open -a ~/Applications/Termi.app"
