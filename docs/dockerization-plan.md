# Dockerization Plan

This document captures the deployment plan for running Canopy in Docker. It is
planning documentation only; it does not describe an implemented Docker setup.

## Application Profile

- Phoenix release application using Elixir 1.20.4, Erlang/OTP 28.5, and Node 22.22.2.
- SQLite database with Oban Lite and file-backed document storage.
- OpenCode runs as a separate HTTP service.
- Claude Code agents run `claude -p` as a child process of the release, so the runtime
  image needs the `claude` binary on `PATH` (set `claude_binary` in Settings to its path
  otherwise) and a login: mount a directory on `/data` as `CLAUDE_CONFIG_DIR` (set it as
  the Claude Code config directory in Settings) after logging in there once with
  `claude`, or pass `ANTHROPIC_API_KEY` into the container for headless API-key auth.
  Each Claude Code session also needs to reach the MCP endpoint at the container's own
  `PHX_HOST`, so the release must be able to connect to itself.
- Canopy executes Git commands for registered repositories and passes repository
  paths to OpenCode as working directories.
- SQLite is single-writer; deploy one application replica unless the persistence
  layer is changed.

## Image Build

Use a multi-stage build:

1. A pinned Elixir/OTP Debian builder installs Node 22 for asset tooling,
   fetches locked dependencies, compiles the application, builds assets, and
   creates the production release.
2. A small pinned Debian/OTP runtime image contains only the release and the
   digested static assets.
3. Run the generated release (`bin/canopy start`), not `mix phx.server`.

The builder must account for the current dependency configuration: Tailwind and
esbuild are runtime dependencies only when `Mix.env() == :dev`. Build assets in
a tooling stage before production release compilation, or deliberately adjust
that configuration during implementation.

Add a `.dockerignore` excluding `.git`, `_build`, `deps`, local SQLite database
files (`*.db`, `-wal`, `-shm`), `*_files`, temporary files, screenshots/e2e
artifacts, and `assets/node_modules`.

Pin base image versions or digests. Run the runtime as non-root where volume
permissions permit.

## Runtime Configuration

Set these values at deployment time rather than baking them into the image:

```text
SECRET_KEY_BASE=<secret>
PHX_HOST=<public hostname>
PORT=4000
PHX_SERVER=true
DATABASE_PATH=/data/canopy.db
CANOPY_FILES_DIR=/data/files
POOL_SIZE=<optional>
```

Production currently binds Phoenix to `127.0.0.1`. The implementation must make
the bind address configurable and use `0.0.0.0` in the container while retaining
a safe local default outside Docker.

Mount a persistent volume at `/data`. It must preserve the SQLite database,
SQLite WAL/SHM files, documents, settings, and generated MCP bearer token.
Back up both the database and `/data/files`; use SQLite-aware consistent backup
or snapshot procedures rather than copying a live WAL database.

## Fresh Volume Bootstrap

Release startup runs migrations when `RELEASE_NAME` is present, but it does not
run `priv/repo/seeds.exs`. A fresh volume therefore needs a documented,
one-shot release `eval`/seed procedure, or the product must explicitly support
starting with no seeded agents. Never run seeds silently on every boot.

## OpenCode Connectivity

Canopy needs an outbound connection to OpenCode, and OpenCode needs a reverse
callback path to Canopy. Agent startup registers MCP using the advertised
Canopy endpoint (`/mcp`). An HTTP-only Compose network can therefore fail even
when Canopy can reach OpenCode.

Choose one of these deployment models:

- Put a TLS reverse proxy in front of Canopy with DNS reachable by OpenCode.
- Make the advertised scheme and port configurable, then use an internal HTTP
  URL only on an isolated, trusted network.

The OpenCode URL is currently persisted in Canopy Settings rather than supplied
by an environment variable. Set it after first boot, or add an explicit
bootstrap environment option during implementation. For a host OpenCode
process, the likely URL is `http://host.docker.internal:4096`; for Compose, use
the service DNS name such as `http://opencode:4096`.

Do not mount the Docker socket. Treat OpenCode and repository mounts as trusted
access to the host and keep the raw app private behind authentication, a reverse
proxy, or a private network. The browser app currently has no login; MCP is
bearer-token protected.

## Repository Mounts

Repository paths are absolute paths persisted in the database. Canopy runs Git
inside those paths, writes `.canopy/` and `.opencode/plugins/`, and passes the
same path to OpenCode as its `directory`.

When Canopy and OpenCode run in separate containers, mount each repository
read/write at the identical absolute path in both containers. A host path
mounted at different paths invalidates existing records; repositories must then
be re-registered. Mount only explicitly selected repositories.

## Compose Shape

The intended baseline is:

- `app`: publishes port 4000, mounts `canopy-data:/data`, and mounts selected
  repository directories.
- `opencode`: optional Compose service with the same repository mounts, or an
  externally managed host service.
- Reverse proxy: terminates TLS, provides the public hostname, and makes the
  Canopy callback URL reachable by OpenCode.

Avoid assuming an OpenCode image or binary until that image is selected and
versioned.

### OpenCode Container

Upstream OpenCode maintains a Dockerfile at
`anomalyco/opencode/packages/opencode/Dockerfile`. It is a minimal Alpine image
that copies a prebuilt platform binary from
`dist/opencode-linux-{x64,arm64}-musl/bin/opencode`; it is not a conventional
source-build Dockerfile. Pin a published image if one is available, or build
the upstream release artifact in a controlled pipeline.

The headless server command is:

```text
opencode serve --hostname 0.0.0.0 --port 4096
```

OpenCode exposes `GET /global/health` and supports Basic Auth through
`OPENCODE_SERVER_PASSWORD` (the default username is `opencode`). The upstream
minimal image installs `libgcc`, `libstdc++`, and ripgrep only. Verify whether
the selected image includes Git and the shell/tools required by agents; a
derived image may need to add them.

## PostgreSQL Option

Compose is a natural deployment shape for the app, OpenCode, a reverse proxy,
and an optional database service. PostgreSQL should be an intentional profile,
not an automatic replacement for SQLite:

- `Canopy.Repo` currently hard-codes `Ecto.Adapters.SQLite3`.
- Production config requires a filesystem `DATABASE_PATH`.
- `ecto_sqlite3` is the declared database adapter dependency.

Supporting PostgreSQL requires an adapter/configuration abstraction, the
`postgrex` dependency, `DATABASE_URL` or equivalent host/credential settings,
a migration and query compatibility review, and a data import/migration path
from SQLite. SQLite remains the simplest single-instance default; PostgreSQL is
appropriate for concurrent or multi-instance deployments after this work is
implemented and tested.

## Health and Operations

Add a narrow health endpoint or release health command, then configure Docker
`HEALTHCHECK`; no obvious health route currently exists. If TLS terminates at a
reverse proxy, preserve `x-forwarded-proto` for the existing force-SSL behavior.

Verify:

- Clean image build without host `_build` or dependency leakage.
- Fresh-volume migrations and the documented seed/bootstrap procedure.
- Static assets, LiveView websocket, `/mcp`, uploads, and downloads.
- OpenCode request, MCP callback registration, and SSE connectivity.
- Git status/diff and agent operations with mounted repositories.
- Oban schedules after restart and graceful shutdown.
- Backup and restore of SQLite plus document files.
- Required/malformed environment variables and health-check failures.

Run `mix precommit` outside the image and a clean-image smoke test before
deployment.
