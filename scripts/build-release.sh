#!/bin/sh
set -eu

mix deps.get --only prod

project_version="$(mix run --no-start --no-compile --no-deps-check -e 'IO.write(Mix.Project.config()[:version])')"
version="${1:-$project_version}"

if [ "$version" != "$project_version" ]; then
  echo "release version $version does not match mix.exs version $project_version" >&2
  exit 1
fi

case "$(uname -m)" in
  arm64) target="aarch64-apple-darwin" ;;
  x86_64) target="x86_64-apple-darwin" ;;
  *) echo "unsupported macOS architecture: $(uname -m)" >&2; exit 1 ;;
esac

export MIX_ENV=prod

cleanup() {
  mix phx.digest.clean --all --no-compile >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM
mix assets.deploy
mix release --overwrite

mkdir -p dist
artifact="dist/canopy-${version}-${target}.tar.gz"
cp "_build/prod/canopy-${version}.tar.gz" "$artifact"
checksum="$(shasum -a 256 "$artifact" | cut -d ' ' -f 1)"
printf '%s  %s\n' "$checksum" "$(basename "$artifact")" > "${artifact}.sha256"
printf '%s\n' "$artifact"
