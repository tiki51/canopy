#!/bin/bash
# A stand-in for the `gh` binary in tests (Canopy.GitHub.CLI). It never talks
# to GitHub: it prints a fixture and exits.
#
#   FAKE_GH_FIXTURE       file to print (optional)
#   FAKE_GH_FIXTURE_<cmd> file to print for one subcommand instead: api, repo,
#                         auth, or version (for --version)
#   FAKE_GH_SEQUENCE      a directory: the nth `gh api` call prints <dir>/<n>.txt
#                         (counted in <dir>/.count) and exits with <dir>/<n>.exit
#                         if there is one; beats the fixture variables for api
#   FAKE_GH_EXIT          exit status (default 0); FAKE_GH_EXIT_<cmd> per subcommand
#   FAKE_GH_LOG           append each argument on its own line, then "--", here;
#                         an --input file's content follows as "input: <json>"
#   FAKE_GH_SLEEP         seconds to sleep before printing (optional)
cmd="${1#--}"
if [ -n "$FAKE_GH_LOG" ]; then
  input=""
  prev=""
  for a in "$@"; do
    printf '%s\n' "$a" >> "$FAKE_GH_LOG"
    if [ "$prev" = "--input" ]; then input="$a"; fi
    prev="$a"
  done
  if [ -n "$input" ] && [ -f "$input" ]; then
    printf 'input: %s\n' "$(cat "$input")" >> "$FAKE_GH_LOG"
  fi
  printf -- '--\n' >> "$FAKE_GH_LOG"
fi
if [ -n "$FAKE_GH_SLEEP" ]; then sleep "$FAKE_GH_SLEEP"; fi
if [ "$cmd" = "api" ] && [ -n "$FAKE_GH_SEQUENCE" ]; then
  n=$(( $(cat "$FAKE_GH_SEQUENCE/.count" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$FAKE_GH_SEQUENCE/.count"
  if [ -f "$FAKE_GH_SEQUENCE/$n.txt" ]; then cat "$FAKE_GH_SEQUENCE/$n.txt"; fi
  if [ -f "$FAKE_GH_SEQUENCE/$n.exit" ]; then exit "$(cat "$FAKE_GH_SEQUENCE/$n.exit")"; fi
  exit 0
fi
fixture_var="FAKE_GH_FIXTURE_$cmd"
exit_var="FAKE_GH_EXIT_$cmd"
fixture="${!fixture_var:-$FAKE_GH_FIXTURE}"
if [ -n "$fixture" ] && [ -f "$fixture" ]; then cat "$fixture"; fi
exit "${!exit_var:-${FAKE_GH_EXIT:-0}}"
