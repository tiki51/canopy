# Canopy — notes for Claude Code

Read `AGENTS.md` first; it carries the Phoenix 1.8 / LiveView 1.2 conventions this project follows.

## What this is

Local-first Slack-like collaboration layer for AI coding agents, with Claude Code as the primary execution engine and OpenCode as the second. Elixir 1.20 / OTP 28, Phoenix 1.8, LiveView 1.2, SQLite via `ecto_sqlite3`, `req` for HTTP, `anubis_mcp` for the MCP server.

## Planning documents (local only, gitignored)

- `_claude_docs/architecture/Canopy Architecture API.md` — product and architecture intent.
- `_claude_docs/architecture/Canopy V0 Implementation Plan.md` — phased build plan; follow it in order.
- `_claude_docs/architecture/Phase 0 Spike Notes.md` — verified OpenCode 1.18.11 behaviour. Trust these notes over the OpenAPI spec where they disagree (for example, telemetry comes from `message.part.updated`, not `session.next.*`).
- `_claude_docs/architecture/phase0-events-capture.jsonl` — raw SSE capture, use as fixtures.
- `_claude_docs/architecture/Claude Code Engine Plan.md` — phased plan for Claude Code as a second engine (per-turn `claude -p` under a Port, per-session MCP token identity); `claude-code-events-capture.jsonl` beside it is a verified stream-json fixture and `Claude Code Spike Notes.md` records what was checked.

## Working agreements

- Never commit or push unless the user explicitly asks in the current request.
- Bind to `127.0.0.1` by default. `CANOPY_BIND=0.0.0.0` (dev only) is the user's opt-in for
  showing it on a trusted network; there is no login yet, so never make it the default.
- Agent identity in MCP tools comes from two trusted sources only: the `canopy_session_id` stamped by the OpenCode plugin, or the per-session bearer token a Claude Code process presents (assigned as `:canopy_session` by `Canopy.MCP.AuthPlug`). Never from model-supplied values.
- Keep OpenCode HTTP details inside `Canopy.OpenCode.*`. The runtime talks to engines only through `Canopy.Engine` adapters (`Canopy.Engine.OpenCode` today) and normalized `Canopy.Engine.Event`s; never add an engine branch to the channel server, put it in the adapter.
- Run `mix precommit` before declaring a phase done.
- Tests never spawn the real `claude` CLI: `config/test.exs` points `config :canopy, :claude_code` at `test/support/fake_claude.sh`, which prints the jsonl named by `FAKE_CLAUDE_SCRIPT`. Verified stream shapes live in `test/support/claude_code_fixtures/`.
- Routing rule to remember: a user message that mentions an agent wakes that agent, not the owner. Demo prompts should say "the researcher agent" unless the mention is intended.
- Scheduled agent tasks are Oban jobs (`Canopy.Schedules`, queue `schedules`, SQLite Lite engine).
  Tests use `Oban.Testing` with `Oban.drain_queue/1`; never sleep to wait for a fire.
- `mix canopy.demo` builds the demo repository under `tmp/` (gitignored); `--engine claude_code` puts the demo agents on Claude Code. Reset it with `git -C tmp/demo-repo checkout -- .` after agents edit it.
