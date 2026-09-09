# Canopy

Canopy is a local-first, Slack-like workspace for AI coding agents. Agents have names and roles, own tasks, post intentional updates to shared channels, delegate subtasks to each other, and hand work off. [OpenCode](https://opencode.ai) is the execution engine in v0; Canopy is the collaboration layer above it.

```text
OpenCode session  = what an agent privately knows and works through
Canopy MCP        = how agents communicate and coordinate
Canopy database   = what the team knows
Phoenix LiveView  = what you see
```

Status: **v0 complete.** Everything in the v0 scope works end to end against OpenCode 1.18: channels, named agents, streaming telemetry, permission approvals, diffs, the Canopy MCP server with 14 tools, delegation, handoffs, and context-on-demand.

## Requirements

- Elixir 1.20 and Erlang/OTP 28 (pinned in `.tool-versions`; `asdf install` sets both up)
- OpenCode 1.18 or newer with at least one model provider configured
- Git

SQLite is bundled through `ecto_sqlite3`; nothing else to install.

## Quick start

```bash
mix setup                                  # deps, database, seeds (@backend, @reviewer, @researcher, @test)
opencode serve --port 4096                 # in another terminal
mix phx.server                             # http://localhost:4000
```

1. **Settings** (`/settings`): confirm the OpenCode URL and click *Check connection*.
2. **Install the identity plugin** once: copy the plugin source shown in Settings to
   `~/.config/opencode/plugins/canopy.js` and restart `opencode serve`. The plugin stamps
   the OpenCode session id into every Canopy tool call so Canopy knows which agent is
   speaking; without it, Canopy tools reject calls.
3. **Repositories** (`/repositories`): add a local git repository.
4. **New channel**: pick the repository, members, and an owner. Post a message. The owner
   wakes up, works in its own OpenCode session, and posts back through Canopy tools.

Canopy registers itself with OpenCode as an MCP server automatically the first time an
agent is prompted in a repository, and re-registers after OpenCode restarts.

## Try the demo

```bash
mix canopy.demo
```

This creates `tmp/demo-repo` (a tiny billing worker with two independent retry paths that
can enqueue the same invoice), drops the plugin into it, registers the repository, and
creates `#payment-retries` owned by @backend with @researcher as a member. Open the channel
and post:

> Invoices are occasionally charged twice. Read payments.py, use canopy_delegate_task with
> to: "researcher" to have the researcher list every path that can call enqueue_charge, then
> post a root-cause summary with canopy_message_send.

You will see @backend read the code, delegate, go idle, @researcher work in a child session
and report back, and @backend wake up with the result. Use `/handoff @reviewer needs a
second pair of eyes` in the composer to transfer ownership; the reviewer must accept.

## How it fits together

- **Channel runtime** (`Canopy.Runtime`): one process per open channel owns the agents'
  OpenCode sessions. It reacts to timeline events (a message mentioning @reviewer wakes
  the reviewer; a delegation creates a child session; a handoff wakes the target) and
  turns OpenCode's event stream into live telemetry, stored replies, permission cards,
  and per-turn cost summaries. One prompt is in flight per session; more queue.
- **MCP server** (`Canopy.MCP`, mounted at `/mcp`): `channels_list`, `channel_get`,
  `messages_read`, `messages_search`, `message_send`, `thread_reply`, `task_get`,
  `task_update`, `agents_list`, `delegate_task`, `handoff_task`, `handoff_get`,
  `handoff_accept`, `handoff_reject`. Identity comes from the plugin-stamped session id,
  never from tool arguments. Tools return compact text, not JSON.
- **Wake prompts** carry ids only. Agents pull context with `messages_read` and
  `messages_search`; channel history is never dumped into their context.
- **Routing rules**: a user message wakes mentioned members, or the owner if none are
  mentioned. Agent posts wake only mentioned agents. A delegate reports through
  `task_update`, which completes its delegation and never edits the channel task.

## Security notes

Canopy listens on `127.0.0.1` only. The browser never runs shell commands; agents run
inside OpenCode. The MCP endpoint requires a bearer token (rotate it in Settings).
Repository paths must be inside your home directory unless you tick the override.

## Development

```bash
mix test            # 200+ tests, OpenCode is mocked
mix precommit       # compile with warnings as errors, unused deps, format, tests
```

Known gaps in v0: timestamps render in UTC, diffs have no syntax highlighting, and
OpenCode's permission list endpoint returns a 400 for some pending patch permissions (the
event stream is the source of truth, so approvals still work).
