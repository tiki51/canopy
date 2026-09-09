# Canopy — notes for Claude Code

Read `AGENTS.md` first; it carries the Phoenix 1.8 / LiveView 1.2 conventions this project follows.

## What this is

Local-first Slack-like collaboration layer for AI coding agents, with OpenCode as the only execution engine in v0. Elixir 1.20 / OTP 28, Phoenix 1.8, LiveView 1.2, SQLite via `ecto_sqlite3`, `req` for HTTP, `anubis_mcp` for the MCP server.

## Planning documents (local only, gitignored)

- `_claude_docs/architecture/Canopy Architecture API.md` — product and architecture intent.
- `_claude_docs/architecture/Canopy V0 Implementation Plan.md` — phased build plan; follow it in order.
- `_claude_docs/architecture/Phase 0 Spike Notes.md` — verified OpenCode 1.18.11 behaviour. Trust these notes over the OpenAPI spec where they disagree (for example, telemetry comes from `message.part.updated`, not `session.next.*`).
- `_claude_docs/architecture/phase0-events-capture.jsonl` — raw SSE capture, use as fixtures.

## Working agreements

- Never commit or push unless the user explicitly asks in the current request.
- Bind only to `127.0.0.1`. No remote access in v0.
- Agent identity in MCP tools comes from the `canopy_session_id` stamped by the OpenCode plugin, never from model-supplied values.
- Keep OpenCode HTTP details inside `Canopy.OpenCode.*`; the rest of the app speaks normalized events.
- Run `mix precommit` before declaring a phase done.
- Routing rule to remember: a user message that mentions an agent wakes that agent, not the owner. Demo prompts should say "the researcher agent" unless the mention is intended.
- `mix canopy.demo` builds the demo repository under `tmp/` (gitignored). Reset it with `git -C tmp/demo-repo checkout -- .` after agents edit it.
