#!/bin/bash
# A stand-in for the `claude` binary in tests. Reads one stream-json user line
# from stdin, then prints the lines of $FAKE_CLAUDE_SCRIPT (a jsonl file) with
# SESSION_ID replaced by the id from --session-id / --resume.
#
#   FAKE_CLAUDE_SCRIPT  jsonl to print (optional)
#   FAKE_CLAUDE_STDERR  text to print on stderr before exiting (optional)
#   FAKE_CLAUDE_EXIT    exit status (default 0)
#   FAKE_CLAUDE_SLEEP   seconds to sleep after printing (optional)
#   FAKE_CLAUDE_LOG     append the argv and the stdin line here (optional)
case "$1" in
  --version) echo "9.9.9 (Fake Claude)"; exit 0 ;;
  auth) echo '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max","email":"fake@example.com"}'; exit 0 ;;
esac
sid=""
prev=""
for a in "$@"; do
  case "$prev" in
    --session-id|--resume) sid="$a" ;;
  esac
  prev="$a"
done
IFS= read -r line
if [ -n "$FAKE_CLAUDE_LOG" ]; then
  printf 'ARGV %s\nSTDIN %s\n' "$*" "$line" >> "$FAKE_CLAUDE_LOG"
fi
if [ -n "$FAKE_CLAUDE_STDERR" ]; then
  echo "$FAKE_CLAUDE_STDERR" >&2
fi
if [ -n "$FAKE_CLAUDE_SCRIPT" ] && [ -f "$FAKE_CLAUDE_SCRIPT" ]; then
  sed "s/SESSION_ID/$sid/g" "$FAKE_CLAUDE_SCRIPT"
fi
if [ -n "$FAKE_CLAUDE_SLEEP" ]; then
  # SIGINT (an abort) ends the turn the way Claude Code does: an error result, exit 0
  trap 'kill "$sleeper" 2>/dev/null; printf "{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true,\"num_turns\":1,\"result\":\"\",\"session_id\":\"%s\",\"total_cost_usd\":0.001,\"usage\":{}}\n" "$sid"; exit 0' INT
  sleep "$FAKE_CLAUDE_SLEEP" &
  sleeper=$!
  wait "$sleeper"
fi
exit "${FAKE_CLAUDE_EXIT:-0}"
