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

# Stop fires the instant the assistant's turn ends, even if the last thing it
# did was kick off a background shell (run_in_background) that's still doing
# real work — e.g. a multi-minute transcription. Without this check that reads
# as "done" for however long the background job takes, then flips back to
# "working" once its completion is surfaced as a fresh turn. Resolved by
# looking at the last *inbound* (role "user") transcript entry, whatever form
# it took:
#   - still the "Command running in background with ID: ..." acknowledgment
#     -> nothing has checked on it since, the job hasn't resolved -> "working"
#   - a <task-notification>...</task-notification> message -> the background
#     job already finished (or failed) and got surfaced as its own turn, so
#     the pending state is resolved -> leave STATE alone
# A completed background job resolves as a synthetic <task-notification> user
# turn, not a new tool_result, so checking tool_result alone (as an earlier
# version of this check did) would find the stale acknowledgment forever and
# get stuck showing "working" even after the job was long done.
pending_background=false
if [ "$STATE" = "done" ]; then
  transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)
  if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    last_inbound=$(tail -n 80 "$transcript" 2>/dev/null | jq -rs '
        [ .[] | select(.message.role? == "user") ] as $users
        | ($users | last) as $lu
        | if $lu == null then ""
          else
            ($lu.message.content) as $c
            | if ($c | type) == "array" then
                ($c | map(
                    if .type == "tool_result" then
                      (.content | if type == "array" then (map(.text? // "") | join(" ")) else (. // "" | tostring) end)
                    else empty end
                  ) | join(" "))
              else ($c // "" | tostring)
              end
          end
      ' 2>/dev/null)
    case "$last_inbound" in
      *"<task-notification>"*) : ;;
      *"running in background with ID"*) STATE="working"; pending_background=true ;;
    esac
  fi
fi

# Claude Code fires no hook at all on a manual interrupt (Escape) — Termi falls
# back to a staleness timeout on the *app* side for that (a `working` session
# with no heartbeat in Tuning.staleWorkingTimeout is presumed interrupted). That
# heuristic would misfire here: a backgrounded shell can legitimately run far
# longer than that timeout with no further hook activity at all until it
# resolves. pendingBackground tells the app "this working state is a known,
# deliberate wait, not silence to be suspicious of" — cleared automatically the
# moment any other hook writes this file normally again.
tmp="$f.tmp.$$"
if jq -n \
    --arg sid "$sid" \
    --arg cwd "$cwd" \
    --arg state "$STATE" \
    --argjson ppid "$PPID" \
    --argjson ts "$(date +%s)" \
    --argjson pendingBackground "$pending_background" \
    '{session_id:$sid, cwd:$cwd, state:$state, ppid:$ppid, ts:$ts, pendingBackground:$pendingBackground}' \
    > "$tmp" 2>/dev/null; then
  mv -f "$tmp" "$f" 2>/dev/null
else
  rm -f "$tmp" 2>/dev/null
fi

exit 0
