#!/bin/bash
# termi-state.sh <state>
#
# Claude Code hook -> mascot state. Writes one small JSON file per session into
# ~/.claude/termi/sessions/, which Termi.app watches with FSEvents.
#
# Invariants:
#   - always exit 0; a bug here must never block or slow a session
#   - write atomically, so the watcher never reads a half-written file
#   - bash + jq only, no interpreter startup cost in the session's critical path
#
# States: idle | working | asking | done   (plus the pseudo-state "end" = remove)

STATE="$1"
DIR="$HOME/.claude/termi/sessions"
mkdir -p "$DIR" 2>/dev/null

payload=$(cat)
sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$sid" ] && exit 0

f="$DIR/$sid.json"

# Session ended: drop the file entirely. Absence == no session.
if [ "$STATE" = "end" ]; then
  rm -f "$f"
  exit 0
fi

# The Notification hook fires both for permission prompts and for plain
# "input has been idle" nudges. Verified in Phase 0: the payload carries
# notification_type, so we key off that instead of guessing from prior state.
# Only a permission prompt genuinely means "this session needs you".
if [ "$STATE" = "notify" ]; then
  ntype=$(printf '%s' "$payload" | jq -r '.notification_type // empty' 2>/dev/null)
  [ "$ntype" = "permission_prompt" ] || exit 0
  STATE="asking"
fi

cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)

tmp="$f.tmp.$$"
if jq -n \
    --arg sid "$sid" \
    --arg cwd "$cwd" \
    --arg state "$STATE" \
    --argjson ppid "$PPID" \
    --argjson ts "$(date +%s)" \
    '{session_id:$sid, cwd:$cwd, state:$state, ppid:$ppid, ts:$ts}' \
    > "$tmp" 2>/dev/null; then
  mv -f "$tmp" "$f" 2>/dev/null
else
  rm -f "$tmp" 2>/dev/null
fi

exit 0
