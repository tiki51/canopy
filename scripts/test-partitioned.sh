#!/usr/bin/env bash
# Runs the ExUnit suite as N partitions in parallel (`mix test --partitions N`).
# Each partition has its own database (canopy_test<N>.db), files directory and
# TMPDIR (config/test.exs), so they never share a SQLite writer. About 2.5x
# faster than `mix test` on an M-series Mac at the default of 4.
#
#   scripts/test-partitioned.sh                 # the whole suite, 4 partitions
#   scripts/test-partitioned.sh test/canopy     # extra arguments go to `mix test`
#   MIX_TEST_PARTITIONS=8 scripts/test-partitioned.sh
#
# Each partition's output goes to _build/test/partitions/<i>.log; a failing
# partition's log is printed at the end. `mix precommit` runs this script.
set -uo pipefail

cd "$(dirname "$0")/.."

n="${MIX_TEST_PARTITIONS:-4}"
export MIX_ENV=test
logs="_build/test/partitions"

# compile once up front, so the partitions don't queue on the build lock
mix compile || exit $?

rm -rf "$logs"
mkdir -p "$logs"

start=$SECONDS
pids=()
tmps=()
for i in $(seq 1 "$n"); do
  # outside the home directory, like the system's (repositories tests rely on it)
  tmp=$(mktemp -d -t "canopy-test-p$i") || exit 1
  tmps+=("$tmp")
  TMPDIR="$tmp/" MIX_TEST_PARTITION="$i" mix test --partitions "$n" "$@" >"$logs/$i.log" 2>&1 &
  pids+=($!)
done

failed=()
for i in $(seq 1 "$n"); do
  if wait "${pids[$((i - 1))]}"; then status=ok; else status=FAILED; failed+=("$i"); fi
  summary=$(grep -E '^(Result: |[0-9]+ (doctests?, )?tests?, )' "$logs/$i.log" | tail -1)
  echo "partition $i/$n: $status  ${summary:-(no summary, see $logs/$i.log)}"
done

for i in ${failed[@]+"${failed[@]}"}; do
  echo
  echo "==> partition $i ($logs/$i.log)"
  cat "$logs/$i.log"
done

rm -rf "${tmps[@]}"
echo "finished in $((SECONDS - start)) s with $n partitions"
[ ${#failed[@]} -eq 0 ]
