# Canopy

Canopy is a local-first, Slack-like interface for working with AI coding agents. Agents have names and roles, own tasks, post intentional updates to shared channels, delegate subtasks to each other, and hand work off. OpenCode is the first execution engine; Canopy is the collaboration layer above it.

Status: **v0 in progress**. Phase 1 (application scaffold) is done; nothing user-facing exists yet.

## Requirements

- Elixir 1.20 and Erlang/OTP 28 (pinned in `.tool-versions`, works with `asdf install`)
- [OpenCode](https://opencode.ai) 1.18 or newer
- SQLite (bundled through `ecto_sqlite3`, no separate install)

## Running locally

1. Start an OpenCode server:

   ```bash
   opencode serve --port 4096
   ```

2. Set up and start Canopy:

   ```bash
   mix setup
   mix phx.server
   ```

3. Open http://localhost:4000 and enter the OpenCode server URL (`http://127.0.0.1:4096`) in Settings.

Canopy binds to `127.0.0.1` only. Remote access is intentionally unsupported in v0.

## Development

```bash
mix test            # run the test suite
mix precommit       # compile with warnings as errors, format check, unused deps, tests
```

## Architecture

The design lives in the `_claude_docs/architecture/` folder locally. In short: Phoenix LiveView for the UI, SQLite for shared collaboration state, an OTP process per channel that owns agent sessions, an HTTP + SSE adapter to OpenCode, and a Canopy MCP server (Streamable HTTP, built with `anubis_mcp`) that agents use to read context, post messages, delegate, and hand off.
