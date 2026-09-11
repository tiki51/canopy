#!/usr/bin/env bash
# Boots Canopy for the Playwright suite on its own SQLite database and port,
# pointed at the fake OpenCode server. Invoked by playwright.config.ts.
set -euo pipefail
cd "$(dirname "$0")/../.."

export MIX_ENV=dev
export PORT="${CANOPY_E2E_PORT:-4100}"
export CANOPY_DB="${CANOPY_DB:-$PWD/canopy_e2e.db}"
export PHX_SERVER=true
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

mix run -e "
  {:ok, _} = Canopy.Settings.update(%{opencode_url: \"$FAKE_URL\"})
  Canopy.Repositories.get_by_path(\"$REPO\") ||
    ({:ok, _} = Canopy.Repositories.create(%{name: \"e2e-repo\", path: \"$REPO\"}))
"

# Optional extra seed, e.g. the Acme workspace for the user guide screenshots.
if [ -n "${CANOPY_SEED:-}" ]; then
  env -u PHX_SERVER mix run "$CANOPY_SEED"
fi

exec mix phx.server
