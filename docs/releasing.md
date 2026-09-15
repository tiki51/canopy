# Releasing Canopy for macOS

Canopy's release archive includes Erlang/OTP and is native to the macOS architecture
that builds it. The initial Homebrew artifact targets Apple Silicon.

## Build locally

Use an arm64 Mac with the Erlang and Elixir versions from `.tool-versions`:

```sh
scripts/build-release.sh
scripts/smoke-release.sh dist/canopy-*.tar.gz
```

The build produces a versioned archive and checksum in `dist/`:

```text
canopy-0.1.0-aarch64-apple-darwin.tar.gz
canopy-0.1.0-aarch64-apple-darwin.tar.gz.sha256
```

The smoke test extracts the archive into a temporary directory, starts it with an
isolated `HOME`, database, and files directory, waits for `GET /health`, verifies that
the database was created during successful application startup, and terminates the service.

## Publish from GitHub Actions

The `macOS release` workflow can be run manually to build and retain an artifact without
publishing it. Pushing a version tag builds the same artifact and creates a public GitHub
release:

1. Update the version in `mix.exs` and merge the release commit.
2. Tag that commit with the matching `v<version>` tag, such as `v0.1.0`.
3. Push the tag and verify the `macOS release` workflow.
4. Use the published archive URL and SHA-256 in the Homebrew formula.

The workflow rejects a tag whose version does not match `mix.exs`. Do not bundle Claude
Code or OpenCode; both remain separately installed engines.

## Runtime state

The Homebrew service must provide stable values for `HOME`, `DATABASE_PATH`,
`CANOPY_FILES_DIR`, `SECRET_KEY_BASE`, `PORT`, `CANOPY_URL`, and `PATH`. Keep the listener
and `CANOPY_URL` on loopback. Preserve the database and files directory during upgrades,
and back up both before rollback. Canopy automatically runs pending migrations when the
release starts; `bin/migrate` is available for an explicit one-shot migration.
