#!/bin/bash
# demo.sh — drive the mascot through every state in an isolated scratch directory,
# so real sessions don't interfere with what you're looking at.
#
#   ./demo.sh          full tour
#   ./demo.sh asking   hold a single state until you Ctrl-C

DIR=/tmp/termi-demo
rm -rf "$DIR"; mkdir -p "$DIR"
export TERMI_DIR="$DIR"

write() { # write <id> <state> <folder>
  jq -n --arg sid "$1" --arg state "$2" --arg cwd "$HOME/Documents/$3" \
        --argjson ppid "$$" --argjson ts "$(date +%s)" \
    '{session_id:$sid, cwd:$cwd, state:$state, ppid:$ppid, ts:$ts}' > "$DIR/$1.json"
}

pkill -x Termi 2>/dev/null; sleep 0.3
"$(dirname "$0")/.build/debug/Termi" &
APP=$!
trap 'kill $APP 2>/dev/null; rm -rf "$DIR"' EXIT
sleep 1

if [ -n "$1" ]; then
  echo "holding state: $1  (Ctrl-C to stop)"
  write demo-a "$1" portfolio
  wait $APP
  exit 0
fi

echo "1/6  no sessions -> mascot hidden"
sleep 3

echo "2/6  idle"
write demo-a idle portfolio
sleep 5

echo "3/6  working"
write demo-a working portfolio
sleep 6

echo "4/6  three sessions, badge shows 3, top state is working"
write demo-b working termi
write demo-c idle notes
sleep 5

echo "5/6  one session asks a question -> jumps until answered"
write demo-b asking termi
sleep 7

echo "6/6  finished -> three hops, then settles to idle"
write demo-b done termi
sleep 8

echo "back to nothing -> hides"
rm -f "$DIR"/*.json
sleep 4
echo "demo over"
