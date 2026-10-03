#!/bin/bash
# A stand-in for the `gh` binary in tests (Canopy.GitHub.CLI). It never talks
# to GitHub: it prints a fixture and exits.
#
#   FAKE_GH_FIXTURE       file to print (optional)
#   FAKE_GH_FIXTURE_<cmd> file to print for one subcommand instead: api, repo,
#                         auth, or version (for --version)
#   FAKE_GH_EXIT          exit status (default 0); FAKE_GH_EXIT_<cmd> per subcommand
#   FAKE_GH_LOG           append each argument on its own line, then "--", here
#   FAKE_GH_SLEEP         seconds to sleep before printing (optional)
cmd="${1#--}"
if [ -n "$FAKE_GH_LOG" ]; then
  for a in "$@"; do printf '%s\n' "$a" >> "$FAKE_GH_LOG"; done
  printf -- '--\n' >> "$FAKE_GH_LOG"
fi
if [ -n "$FAKE_GH_SLEEP" ]; then sleep "$FAKE_GH_SLEEP"; fi
fixture_var="FAKE_GH_FIXTURE_$cmd"
exit_var="FAKE_GH_EXIT_$cmd"
fixture="${!fixture_var:-$FAKE_GH_FIXTURE}"
if [ -n "$fixture" ] && [ -f "$fixture" ]; then cat "$fixture"; fi
exit "${!exit_var:-${FAKE_GH_EXIT:-0}}"
