#!/bin/bash
# termi-fake.sh <state> [label] [id]
#
# Development helper: writes a synthetic session file so every mascot state can be
# driven without running real Claude Code sessions.
#
#   ./termi-fake.sh working portfolio       # one fake session, "working"
#   ./termi-fake.sh asking mascot-app  b    # a second one, "asking"
#   ./termi-fake.sh clear                   # remove all fakes
#
# Fakes use ppid=$$ of this script, which dies immediately — so the app's liveness
# prune would remove them. They're written with the current shell's ppid instead
# (the terminal), which stays alive as long as your terminal window is open.

DIR="$HOME/.claude/termi/sessions"
mkdir -p "$DIR"

if [ "$1" = "clear" ]; then
  rm -f "$DIR"/fake-*.json
  echo "cleared fake sessions"
  exit 0
fi

state="${1:-working}"
label="${2:-fake-project}"
id="${3:-a}"

jq -n \
  --arg sid "fake-$id" \
  --arg cwd "$HOME/Documents/$label" \
  --arg state "$state" \
  --argjson ppid "$PPID" \
  --argjson ts "$(date +%s)" \
  '{session_id:$sid, cwd:$cwd, state:$state, ppid:$ppid, ts:$ts}' \
  > "$DIR/fake-$id.json"

echo "fake-$id -> $state ($label)"
