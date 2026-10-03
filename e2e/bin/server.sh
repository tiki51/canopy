#!/usr/bin/env bash
# Boots Canopy for the Playwright suite on its own SQLite database and port,
# pointed at the fake OpenCode server, with the fake Claude Code
# (e2e/fake-claude/claude) first on PATH. Invoked by playwright.config.ts.
set -euo pipefail
cd "$(dirname "$0")/../.."

export PATH="$PWD/e2e/fake-claude:$PATH"
# Run from inside Canopy (an agent's shell) this would be the real library;
# e2e documents belong next to the e2e database.
unset CANOPY_FILES_DIR
export MIX_ENV=dev
# Other work in this checkout must not reload the page under a running test.
export CANOPY_LIVE_RELOAD=0
export PORT="${CANOPY_E2E_PORT:-4100}"
export CANOPY_DB="${CANOPY_DB:-$PWD/canopy_e2e.db}"
export PHX_SERVER=true
# A Claude Code turn that prints nothing this long is killed (120 s outside the
# suite); short enough for a spec to wait past it, longer than any fake hold.
export CANOPY_CLAUDE_STALL_MS="${CANOPY_CLAUDE_STALL_MS:-10000}"
FAKE_URL="http://127.0.0.1:${FAKE_OPENCODE_PORT:-4396}"
REPO="$PWD/tmp/e2e-repo"

rm -f "$CANOPY_DB" "$CANOPY_DB-shm" "$CANOPY_DB-wal"
mix ecto.create --quiet
mix ecto.migrate --quiet
mix run priv/repo/seeds.exs

if [ ! -d "$REPO/.git" ]; then
  mkdir -p "$REPO"
  printf '# e2e repo\n' > "$REPO/README.md"
  git -C "$REPO" init -q -b main
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=e2e@canopy.local -c user.name=e2e commit -q -m "init"
fi

# Setup counts as done, so `/` behaves as on an existing install; the
# onboarding spec drives /welcome itself.
mix run -e "
  {:ok, _} = Canopy.Settings.update(%{opencode_url: \"$FAKE_URL\"})
  {:ok, _} = Canopy.Settings.mark_onboarded()
  Canopy.Repositories.get_by_path(\"$REPO\") ||
    ({:ok, _} = Canopy.Repositories.create(%{name: \"e2e-repo\", path: \"$REPO\"}))
"

# Optional extra seed, e.g. the Acme workspace for the user guide screenshots.
if [ -n "${CANOPY_SEED:-}" ]; then
  env -u PHX_SERVER mix run "$CANOPY_SEED"
fi

exec mix phx.server
