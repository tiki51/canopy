#!/bin/sh
set -eu

artifact="${1:?usage: scripts/smoke-release.sh RELEASE_TARBALL}"
port="${CANOPY_SMOKE_PORT:-4568}"
root="${TMPDIR:-/tmp}/canopy-release-smoke-$$"
pid=""

cleanup() {
  if [ -n "$pid" ]; then
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi

  rm -rf "$root"
}

trap cleanup EXIT
trap 'exit 1' INT TERM
mkdir -p "$root/home"
tar -xzf "$artifact" -C "$root"

export HOME="$root/home"
export DATABASE_PATH="$root/state/canopy.db"
export CANOPY_FILES_DIR="$root/state/files"
export SECRET_KEY_BASE="0123456789012345678901234567890123456789012345678901234567890123"
export PORT="$port"
export CANOPY_URL="http://127.0.0.1:$port"
export PHX_SERVER=true

"$root/bin/canopy" start > "$root/canopy.log" 2>&1 &
pid=$!

attempt=0
until response="$(curl --fail --silent "http://127.0.0.1:$port/health")"; do
  attempt=$((attempt + 1))

  if [ "$attempt" -ge 60 ]; then
    cat "$root/canopy.log" >&2
    exit 1
  fi

  sleep 1
done

case "$response" in
  *'"status":"ok"'*) ;;
  *) echo "unexpected health response: $response" >&2; exit 1 ;;
esac

test -f "$DATABASE_PATH"
kill -TERM "$pid"
wait "$pid" || true
pid=""
printf '%s\n' "$response"
