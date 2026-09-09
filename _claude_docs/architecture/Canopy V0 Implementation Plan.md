# Canopy V0 Implementation Plan

Companion to `Canopy Architecture API.md`. That document says *what* v0 is; this one says *how* to build it, in order, with what must be true before each step can start.

Written 2026-09-08 against the actual local environment and the live OpenCode server API. Anything marked **VERIFIED** was checked directly; anything marked **SPIKE** is an assumption that must be confirmed in Phase 0 before code depends on it.

---

## 0. Starting Point

### Local environment (VERIFIED)

| Item | State |
|---|---|
| Project directory | Empty except `_claude_docs/`. Not a git repository. |
| Elixir | 1.18.4 (asdf) |
| Erlang/OTP | 28 |
| Phoenix generator (`phx_new`) | Not installed |
| OpenCode | 1.18.11 at `~/.opencode/bin/opencode`, `opencode serve` works |
| OpenCode global config | `~/.config/opencode/opencode.jsonc` (empty, schema only) |
| SQLite | `/usr/bin/sqlite3` present |
| Node | Present via asdf (needed only for esbuild/tailwind Phoenix assets) |

### OpenCode server API (VERIFIED from `GET /doc` on 1.18.11)

The facts below shape the adapter and the identity model. All routes accept an optional `?directory=<abs path>` query parameter that selects the project the request applies to, so one OpenCode server can serve every Canopy repository.

Routes Canopy v0 will use:

| Purpose | Route |
|---|---|
| Health | `GET /global/health`, `GET /api/health` |
| List projects | `GET /project` |
| List agents for a directory | `GET /agent?directory=` |
| Create session (optionally child) | `POST /session` body `{parentID?, title?, agent?, model?, permission?}` |
| Session list / get / delete | `GET /session`, `GET /session/{id}`, `DELETE /session/{id}` |
| Session children | `GET /session/{id}/children` |
| Session status map | `GET /session/status` |
| Session message history | `GET /session/{id}/message?limit=&before=` |
| Send prompt without blocking | `POST /session/{id}/prompt_async` body `{parts:[{type:"text",text}], agent?, system?, tools?:{name:bool}, model?}` returns 204 |
| Abort | `POST /session/{id}/abort` |
| Session diff | `GET /session/{id}/diff` returns `SnapshotFileDiff[] {file, patch, additions, deletions, status}` |
| Repo diff / status | `GET /vcs/status`, `GET /vcs/diff?mode=`, `GET /vcs` |
| Pending permissions | `GET /permission?directory=` |
| Reply to permission | `POST /permission/{requestID}/reply` body `{reply: "once"\|"always"\|"reject", message?}` |
| Register MCP server at runtime | `POST /mcp` body `{name, config:{type:"remote", url, headers?, enabled?}}` |
| MCP status | `GET /mcp` |
| Event stream (per directory) | `GET /event?directory=` (SSE, first event `server.connected`) |
| Event stream (all) | `GET /global/event` |

SSE event types Canopy will normalize (the `session.next.*` family is the fine-grained stream):

```text
session.created / session.updated / session.deleted / session.idle / session.error
session.status                       {sessionID, status:{type: idle|retry|busy...}}
session.next.prompted / .prompt.admitted
session.next.step.started / .step.ended {finish, cost, tokens, files[]}
session.next.text.started / .text.delta / .text.ended {textID, text}
session.next.reasoning.started / .delta / .ended
session.next.tool.called             {callID, tool, input}
session.next.tool.progress / .tool.success {callID, result, content} / .tool.failed
session.next.shell.started {command} / .shell.ended
message.updated / message.part.updated / message.part.delta
file.edited                          {file}
session.diff                         {sessionID, diff: SnapshotFileDiff[]}
permission.asked                     {id, sessionID, permission, patterns, metadata, tool:{messageID, callID}}
permission.replied
vcs.branch.updated
```

`PermissionRequest` shape: `{id "per...", sessionID, permission, patterns[], metadata, always[], tool?}`.

### OpenCode MCP and agent config (VERIFIED from docs)

- Remote MCP config: `{"type":"remote","url":"...","headers":{...},"enabled":true}`.
- MCP tools are exposed to the model as `<server-name>_<tool-name>`.
- Tools can be turned on/off per agent with patterns in `agent.<name>.tools` (`"my-mcp*": true`) and per prompt via the `tools` map on `prompt_async`.
- Agents are defined in `opencode.json` under `agent.<name>` or as `.opencode/agents/<name>.md`. Config files merge; `OPENCODE_CONFIG_CONTENT` can inject config at process start.

### Libraries chosen

| Need | Choice | Why |
|---|---|---|
| Web + LiveView | Phoenix 1.8.x, LiveView 1.1.x | Current stable, ships Tailwind + daisyUI, streams for timelines |
| Persistence | `ecto_sqlite3` | Local-first single file DB; supports FTS5 through raw migrations |
| HTTP client | `req` (Finch under the hood) | Simple JSON; supports response body streaming for SSE with `into:` |
| MCP server | `anubis_mcp` ~> 2.0 (the maintained fork of hermes_mcp) | Native Elixir, Streamable HTTP transport mounts as a Plug, `Frame.assigns` inherits `Plug.Conn.assigns` so identity can be injected by a plug |
| IDs | Prefixed string IDs (`msg_…`, `ho_…`, `dl_…`, `tsk_…`) | Agents quote IDs in MCP calls; prefixes make them unambiguous |

---

## 1. Design Decisions That Resolve Ambiguity in the Architecture Doc

These are the calls a builder has to make before writing code. Each is the recommended default; change them deliberately.

1. **One OpenCode server, many repositories.** Canopy stores one server URL in settings and passes `?directory=` on every call. One SSE subscription per repository (`GET /event?directory=`), supervised and auto-reconnecting.
2. **Canopy agent = Canopy row + OpenCode agent name + role prompt.** The `agents.opencode_agent_id` column holds the OpenCode agent to run as (default `build`). Canopy injects the role and the collaboration instructions through the `system` field of `prompt_async`, so users do not have to edit `opencode.json` to create agents. *(SPIKE 0.2 confirms `system` appends rather than replaces.)*
3. **Identity is bound by MCP server registration, not by tool arguments.** Canopy registers one MCP server entry per Canopy agent per repository, named `canopy_<agent>` with a per-agent bearer token in `headers`. A plug in front of the MCP endpoint resolves the token to an agent and puts it in `conn.assigns`; every tool reads identity from `frame.assigns`, never from arguments. Each prompt passes a `tools` map that enables only that agent's own `canopy_<agent>_*` tools. *(SPIKE 0.3 confirms runtime `POST /mcp` registration persists for the directory and that the `tools` map accepts either wildcards or an explicit list.)*
4. **Channel context is explicit in tool calls.** Tools take `channel` (name or id). Canopy verifies the agent is a member of that channel. The wake prompt always names the channel and the triggering message id.
5. **One session per (channel, agent).** Created lazily on first prompt, reused thereafter, stored in `agent_sessions`. Delegations create a child session (`parentID`) for the delegate.
6. **Messages vs telemetry.** Anything an agent posts through `message_send` / `thread_reply` is a durable message. The assistant's final text reply to a wake prompt is *also* stored as a message (attributed to the agent) so the timeline is never empty, but with `kind: "reply"` so the UI can render it slightly differently. Tool calls, file edits, shell commands, and status changes are telemetry: broadcast over PubSub, kept in a bounded in-memory buffer per session, and persisted only as a summarized `timeline_events` row per turn (`agent_turn_completed` with counts and touched files).
7. **Single local user.** A `users` table with one seeded row (display name from settings). No auth in v0.
8. **Task model is one task per channel in v0.** `tasks` stays a table so it can grow, but the channel UI shows exactly one current task with owner and status.
9. **Search is SQLite FTS5** over message bodies, scoped by channel.
10. **The MCP endpoint listens on the same Phoenix port** (`/mcp`), bound to `127.0.0.1`. Remote access stays off.

---

## 2. Phase 0 — Spikes (half a day, throwaway scripts)

Run these against `opencode serve --port 4096` from a scratch repo before committing to the adapter design. Record answers at the bottom of this document.

- **SPIKE 0.1 SSE shape.** Subscribe to `GET /event?directory=/path/to/scratch`, send a `prompt_async`, capture the raw event sequence for one turn that reads a file, runs a shell command, and edits a file. Confirm that `session.next.*` events carry enough to render telemetry without polling `GET /session/{id}/message`. Confirm how `permission.asked` looks when the agent tries `bash`.
- **SPIKE 0.2 Prompt-level `system` and `agent`.** Send `prompt_async` with `agent: "build"` and a `system` string. Confirm whether `system` appends to or replaces the agent prompt, and whether `tools: {"<name>": false}` reliably hides a tool. Test a wildcard key such as `"canopy_backend_*": true` and an explicit list.
- **SPIKE 0.3 Runtime MCP registration.** Call `POST /mcp?directory=…` with a remote config pointing at a stub Streamable HTTP server that logs headers. Confirm: OpenCode connects, forwards the `headers`, prefixes tools as `canopy_backend_<tool>`, and whether the registration persists after `opencode serve` restarts (if not, Canopy re-registers on every connect, which is fine).
- **SPIKE 0.4 Child sessions.** Create a session with `parentID`, prompt it, and confirm `GET /session/{parent}/children` lists it and the child's events arrive on the same SSE stream.
- **SPIKE 0.5 Anubis identity plumbing.** Minimal Phoenix app with `anubis_mcp`: a plug that sets `conn.assigns.agent_id` from a bearer header, forwarded to `Anubis.Server.Transport.StreamableHTTP.Plug`, and a tool that echoes `frame.assigns.agent_id`. Confirm that assigns survive the transport for both the initial POST and subsequent calls on the same `Mcp-Session-Id`. If they do not, fall back to a per-agent URL path (`/mcp/<token>`) and a router-level plug.

Exit criteria: all five answered in writing; adapter and MCP designs below adjusted if needed.

---

## 3. Phase 1 — Project Scaffold

1. Install the generator and create the app:
   ```bash
   mix archive.install hex phx_new
   cd ~/devl && mix phx.new canopy --database sqlite3 --no-mailer
   ```
   Then move the generated tree into `~/devl/Canopy` (or generate directly there with `--app canopy --module Canopy`). Keep `_claude_docs/` at the root.
2. `git init`, initial commit, `.gitignore` for `*.db`, `*.db-*`, `priv/repo/*.db`.
3. Add deps to `mix.exs`: `req`, `anubis_mcp`, `jason` (already present), `ecto_sqlite3` (already present). Run `mix deps.get`, `mix compile`, `mix phx.server`, open `http://localhost:4000`.
4. Bind the endpoint to `127.0.0.1` only in `config/dev.exs` and `config/runtime.exs`.
5. Add a `CLAUDE.md` / `README.md` with run instructions and the three-line OpenCode setup: `opencode serve --port 4096`, paste URL into Canopy settings.
6. Add `credo` and `dialyxir` if desired; set up `mix test` in CI later. Not blocking.

Deliverable: blank Phoenix app boots with SQLite, committed.

---

## 4. Phase 2 — Data Model and Contexts

Create migrations and Ecto schemas in this order (each has a matching context module under `lib/canopy/`). All primary keys are `:string` with generated prefixes via `Canopy.ID.generate("msg")`.

| Table | Prefix | Notes beyond the architecture doc |
|---|---|---|
| `settings` | – | Single row: `opencode_url`, `user_display_name`, `mcp_base_url`. Read through `Canopy.Settings`. |
| `users` | `usr` | One seeded local user. |
| `repositories` | `repo` | `name`, `path` (absolute, validated to exist and be a git repo), `default_branch`. Unique on `path`. |
| `agents` | `agt` | `name` (slug, unique, used as `@name`), `display_name`, `role`, `system_prompt`, `opencode_agent_id` (default `"build"`), `mcp_token` (random 32 bytes, base64url), `color`. Global, not per repo. |
| `channels` | `ch` | `repository_id`, `name` (slug, unique per repo), `status` (`open`/`archived`), `owner_agent_id`, `topic`. |
| `channel_agents` | – | Join table: which agents are members of a channel. Needed to validate MCP calls. |
| `agent_sessions` | `as` | `channel_id`, `agent_id`, `opencode_session_id`, `parent_session_id`, `status` (`idle`/`busy`/`error`/`aborted`), `last_seen_at`. Unique on `(channel_id, agent_id, parent_session_id)`. |
| `messages` | `msg` | `channel_id`, `agent_id` or `user_id` (check constraint: exactly one), `thread_id` (parent message id, nullable), `body`, `kind` (`post`/`reply`/`system`), `mentions` (JSON list of agent ids), `opencode_message_id` (nullable). |
| `messages_fts` | – | FTS5 virtual table on `body` with triggers, raw SQL migration. |
| `tasks` | `tsk` | As in doc. `status`: `open`/`working`/`blocked`/`completed`. |
| `delegations` | `dl` | As in doc plus `wake_message_id`. `status`: `requested`/`working`/`completed`/`failed`/`cancelled`. |
| `handoffs` | `ho` | As in doc plus `rejection_reason`, `packet` (JSON: files, branch, git status snapshot). |
| `timeline_events` | `evt` | `channel_id`, `agent_id`, `event_type`, `payload` (JSON), `ref_id` (id of the handoff/delegation/task it refers to). |
| `permission_requests` | `pr` | `channel_id`, `agent_session_id`, `opencode_permission_id`, `permission`, `patterns`, `metadata`, `status` (`pending`/`once`/`always`/`rejected`), `resolved_at`. Persisted so approvals are auditable. |

Contexts and the functions each must expose (only what later phases need):

- `Canopy.Settings` — `get/0`, `update/1`.
- `Canopy.Repositories` — `list/0`, `create/1`, `get!/1`, `git_status/1`, `git_diff/1`, `current_branch/1` (shell out to `git` with `System.cmd` in the repo path; never accept paths from the browser other than through the create form).
- `Canopy.Agents` — CRUD, `get_by_name/1`, `get_by_token/1`, `rotate_token/1`.
- `Canopy.Channels` — CRUD, `add_agent/2`, `set_owner/2`, `members/1`.
- `Canopy.Messages` — `post_user_message/3`, `post_agent_message/4`, `reply/4`, `list/2` (paginated, `around:` support), `search/3`.
- `Canopy.Tasks` — `current_for_channel/1`, `upsert/2`, `update_status/3`.
- `Canopy.Delegations` — `request/…`, `complete/…`, `fail/…`.
- `Canopy.Handoffs` — `request/…`, `accept/…`, `reject/…`, `build_packet/…`.
- `Canopy.Timeline` — `record/4`, `list/2` (merged view of messages + events ordered by `inserted_at`), and one PubSub topic per channel: `"channel:#{id}"`.

Every write in these contexts broadcasts a `{:timeline, item}` message to the channel topic. This is the single fan-out point the UI and the runtime both subscribe to.

Tests: schema/context tests with SQLite in-memory (`Ecto.Adapters.SQL.Sandbox` works with ecto_sqlite3). Cover the sender check constraint, FTS search, and ownership transfer.

Deliverable: `mix ecto.migrate` creates the schema; context tests green.

---

## 5. Phase 3 — OpenCode Adapter

Module tree:

```text
lib/canopy/opencode/
  client.ex          Req-based HTTP client; all functions take a directory
  event_stream.ex    GenServer per repository holding one SSE connection
  events.ex          Normalizer: raw OpenCode event -> Canopy execution event
  supervisor.ex      DynamicSupervisor for event streams keyed by repository id
```

`Canopy.OpenCode.Client` (thin, returns `{:ok, map} | {:error, reason}`):

```elixir
health/0
agents/1                       (directory)
create_session/2               (directory, opts: parent_id, title, agent)
get_session/2, delete_session/2, children/2, session_status/1
messages/3                     (directory, session_id, opts)
prompt_async/3                 (directory, session_id, %{parts, agent, system, tools})
abort/2
session_diff/2, vcs_status/1, vcs_diff/2
pending_permissions/1
reply_permission/3             (directory, permission_id, :once | :always | :reject)
add_mcp/3                      (directory, name, config)
mcp_status/1
```

Base URL comes from `Canopy.Settings` at call time so changing it in the UI takes effect without restart. Add a `Canopy.OpenCode.Client.Behaviour` and a `Mox` stub so runtime and LiveView tests do not need a live server.

`Canopy.OpenCode.EventStream` (one per repository):

- Opens `GET /event?directory=…` with Req streaming (`into: fn` or `Req.get(..., into: :self)`), parses `data:` lines into JSON, handles `server.connected`, and reconnects with backoff on close.
- For every event: `Canopy.OpenCode.Events.normalize/1` → `{:ok, canopy_event} | :ignore`, then `Phoenix.PubSub.broadcast(Canopy.PubSub, "opencode:session:#{session_id}", event)`. Session-scoped topics let the channel runtime subscribe only to sessions it owns.

Normalization table (the doc's tuples, now concrete):

| OpenCode event | Canopy event |
|---|---|
| `session.status` | `{:agent_status, session_id, :idle \| :busy \| :retry}` |
| `session.next.text.delta` / `.text.ended` | `{:text_delta, session_id, message_id, text}` / `{:text_done, session_id, message_id, full_text}` |
| `session.next.tool.called` | `{:tool_started, session_id, call_id, tool, input}` |
| `session.next.tool.success` / `.tool.failed` | `{:tool_completed, session_id, call_id, :ok \| :error, summary}` |
| `session.next.shell.started` / `.shell.ended` | `{:command_started, session_id, call_id, command}` / `{:command_completed, …}` |
| `file.edited` | `{:file_changed, path}` |
| `session.diff` | `{:diff, session_id, [file_diff]}` |
| `permission.asked` | `{:approval_required, session_id, permission_request}` |
| `permission.replied` | `{:approval_resolved, session_id, permission_id, reply}` |
| `session.next.step.ended` | `{:step_completed, session_id, %{cost, tokens, files}}` |
| `session.idle` | `{:agent_completed, session_id}` |
| `session.error` | `{:agent_error, session_id, reason}` |
| everything else | `:ignore` |

Tests: fixture files captured in SPIKE 0.1 fed through the normalizer; an SSE parser unit test with split chunks.

Deliverable: `iex> Canopy.OpenCode.Client.health()` works against the configured server; starting an event stream for a repository logs normalized events.

---

## 6. Phase 4 — Channel Runtime (OTP)

```text
Canopy.Application
├── Canopy.Repo
├── Phoenix.PubSub
├── Canopy.OpenCode.Supervisor        (event streams per repository)
├── Canopy.Runtime.Registry           (Registry keyed by channel id and by session id)
├── Canopy.Runtime.ChannelSupervisor  (DynamicSupervisor)
│   └── Canopy.Runtime.ChannelServer  (one per open channel, started on demand)
├── Canopy.MCP.Server                 (Phase 6)
└── CanopyWeb.Endpoint
```

`Canopy.Runtime.ChannelServer` responsibilities:

- State: channel, repository, owner agent, `%{agent_id => agent_session}`, telemetry ring buffer per session (last ~200 events), pending permission ids, pending handoff/delegation ids.
- `ensure_session(agent_id)` — looks up or creates the OpenCode session (with `?directory=` = repo path), registers Canopy MCP for that agent in that directory if not yet registered (`add_mcp`), stores `agent_sessions` row, subscribes to `"opencode:session:#{id}"`.
- `prompt(agent_id, text, opts)` — builds the prompt: user text or a wake prompt (Phase 7), sets `system:` to the agent's collaboration preamble + role prompt, sets `tools:` to enable only that agent's `canopy_<agent>_*` tools, calls `prompt_async`, marks session busy, records `agent_started` timeline event.
- Handles normalized events: appends to the telemetry buffer and re-broadcasts on the channel topic as `{:telemetry, agent_id, event}`; on `:text_done` stores the reply as a `kind: "reply"` message; on `:approval_required` persists a `permission_requests` row and broadcasts; on `:agent_completed` records `agent_turn_completed` with counts and touched files and flips status to idle.
- `respond_permission(permission_id, reply)` — calls the client and updates the row.
- `abort(agent_id)`.
- Message routing: when a user posts to the channel, `Canopy.Runtime.Router.dispatch/2` decides which agents to wake: explicit `@mentions` first, otherwise the channel owner. Agents never receive the message body inline; they receive the wake prompt with the message id (Phase 7).

Idle timeout: ChannelServer hibernates after inactivity but is never a source of truth. Restart safety: on start it rehydrates `agent_sessions` from the DB and verifies each session still exists on OpenCode.

Tests: ChannelServer with the Mox client; simulate an SSE turn by broadcasting normalized events; assert DB rows and PubSub messages.

Deliverable: from `iex`, `Canopy.Runtime.post_user_message(channel_id, "hello @backend")` results in a real OpenCode turn and a stored agent reply.

---

## 7. Phase 5 — LiveView UI

Layout: three columns as in the doc, built with the Phoenix 1.8 core components plus daisyUI. Routes:

```text
/settings                                  SettingsLive     (OpenCode URL, health check, user name)
/repositories                              RepositoriesLive (add path, list, remove)
/agents                                    AgentsLive       (CRUD, role prompt, opencode agent picker from GET /agent, token display/rotate)
/channels/:id                              ChannelLive      (the main screen)
/                                          redirects to the last channel or /repositories
```

`ChannelLive` pieces (function components / live components):

1. **Sidebar**: repositories → channels, plus agents with live status dots. New-channel modal (name, repo, member agents, initial owner).
2. **Header**: `# name`, owner badge, task status pill, git branch (polled every 15 s from `Canopy.Repositories.current_branch/1`).
3. **Timeline** using `stream/3` over `Canopy.Timeline.list/2`, rendering by item type:
   - user message, agent message (`post`), agent reply (`reply`, slightly muted header), thread reply (indented under parent, with a "N replies" toggle),
   - timeline events as centered system lines (`@backend delegated a subtask to @researcher`, `@backend → @database handoff requested`, `accepted`, `task completed`),
   - **telemetry block**: a collapsible card under the active agent showing the live ring buffer (`Read 8 files`, `Ran mix test`, `Modified lib/x.ex`); persists as the compact `agent_turn_completed` line once the turn ends,
   - **permission card**: permission name, patterns, tool call summary, three buttons (Once / Always / Reject) → `ChannelServer.respond_permission/2`,
   - **diff card**: file list with additions/deletions from `:diff` events; click opens a modal with the patch rendered in a `<pre>` (a JS hook is only needed later for syntax highlighting).
4. **Composer**: textarea, `@` autocomplete of member agents (small JS hook), Enter to send, Shift+Enter newline. Sends to `Canopy.Runtime`.
5. **Handoff / delegate panel** (right drawer, Phase 7): pending handoff with Accept/Reject on behalf of the user, task edit form.

PubSub: `ChannelLive` subscribes to `"channel:#{id}"` and handles `{:timeline, item}` (stream insert), `{:telemetry, agent_id, event}` (update the agent's live card), `{:agent_status, …}`, `{:permission, …}`.

Tests: LiveView tests for each screen using the Mox client; one test that broadcasts a fake telemetry sequence and asserts the DOM.

Deliverable: the doc's "Initial Product Goal" items 1 to 8 work end-to-end in the browser.

---

## 8. Phase 6 — Canopy MCP Server

```text
lib/canopy/mcp/
  server.ex           use Anubis.Server, name: "Canopy", version, capabilities: [:tools]
  auth_plug.ex        Bearer token -> agent, puts :agent and :agent_id in conn.assigns; 401 otherwise
  tools/
    channels_list.ex  channel_get.ex
    messages_read.ex  messages_search.ex  message_send.ex  thread_reply.ex
    task_get.ex       task_update.ex
    agents_list.ex
    delegate_task.ex
    handoff_task.ex   handoff_get.ex  handoff_accept.ex  handoff_reject.ex
```

Router:

```elixir
scope "/mcp" do
  pipe_through [:mcp]            # accepts JSON, runs Canopy.MCP.AuthPlug, no CSRF
  forward "/", Anubis.Server.Transport.StreamableHTTP.Plug, server: Canopy.MCP.Server
end
```

Registration with OpenCode (done by `ChannelServer.ensure_session/1`, idempotent):

```json
{
  "name": "canopy_backend",
  "config": {
    "type": "remote",
    "url": "http://127.0.0.1:4000/mcp",
    "headers": { "Authorization": "Bearer <agents.mcp_token>" },
    "enabled": true
  }
}
```

Tool surface for v0 (identity always from `frame.assigns.agent`; `channel` is a name or id and membership is verified):

| Tool | Arguments | Effect | Timeline |
|---|---|---|---|
| `channels_list` | – | channels the agent belongs to, with owner and task status | – |
| `channel_get` | `channel` | metadata, members, owner, current task, repo path and branch | – |
| `messages_read` | `channel`, `around?` (message id), `before?`, `limit?` (≤50) | ordered messages with ids, sender, thread id | – |
| `messages_search` | `channel`, `query`, `limit?` | FTS5 results with snippets | – |
| `message_send` | `channel`, `text` | stores agent message, resolves `@mentions`, wakes mentioned agents | message |
| `thread_reply` | `message_id`, `text` | reply in thread; wakes the parent author if it is an agent | message |
| `task_get` | `channel` | current task | – |
| `task_update` | `channel`, `status?`, `result?`, `title?`, `description?` | updates task; if the agent is a delegate, completes the delegation and wakes the delegator | `task_updated`, `delegation_completed` |
| `agents_list` | – | all agents with roles | – |
| `delegate_task` | `channel`, `to`, `task` | creates delegation, child session, wakes delegate | `delegation_created` |
| `handoff_task` | `channel`, `to`, `summary`, `reason`, `suggested_next_step` | creates handoff with packet, wakes target | `handoff_requested` |
| `handoff_get` | `handoff_id` | full packet | – |
| `handoff_accept` | `handoff_id` | only the target may call; sets owner, resumes | `handoff_accepted` |
| `handoff_reject` | `handoff_id`, `reason` | only the target may call; notifies previous owner | `handoff_rejected` |

Every tool returns compact text (not JSON dumps) since the model reads it. Errors are returned as MCP tool errors with a one-line reason (`not a member of #payments`, `handoff ho_12 is not addressed to you`).

Tests: tool unit tests with a fake frame; one integration test that speaks Streamable HTTP to the endpoint with a real token and with a bad token.

Deliverable: from the OpenCode TUI (or a session started via Canopy) an agent can call `canopy_backend_channels_list` and see its channels.

---

## 9. Phase 7 — Collaboration: Wake Prompts, Delegation, Handoff

**Collaboration preamble** (`priv/prompts/collaboration.md`, injected via `system:` on every prompt): explains that the agent is a named coworker in Canopy, must use `canopy_<name>_*` tools to read context and post updates, must post only meaningful findings, must not narrate tool calls, and how delegation differs from handoff. Keep under 400 words.

**Wake prompt templates** (`Canopy.Runtime.Prompts`):

```text
new_message:
  You have a new Canopy message in #{channel} from {sender}.
  Message ID: {message_id}
  Read it (and any context you need) with messages_read / messages_search,
  do the work, and post your findings with message_send. Reply in the thread
  with thread_reply if the message is part of one.

delegation:
  {from} delegated a subtask to you in #{channel}.
  Delegation ID: {delegation_id}
  Task: {task}
  Use the Canopy tools for context. When done, call task_update with
  status "completed" and a concise result.

delegation_completed:
  Your delegated subtask {delegation_id} in #{channel} was completed by {to}.
  Result: {result}
  Continue your work.

handoff:
  You have received a task handoff from {from} in #{channel}.
  Handoff ID: {handoff_id}
  Call handoff_get, inspect the repository (git status / git diff), then
  handoff_accept or handoff_reject.

handoff_accepted / handoff_rejected: one-line notices to the previous owner.
```

**Delegation flow** (`Canopy.Collaboration.Delegation`):

1. `delegate_task` validates the target is a member and is not the caller.
2. Creates `delegations` row, then `ChannelServer.ensure_session(to, parent: caller_session)` creates a child OpenCode session (`parentID`).
3. Records `delegation_created`, prompts the child with the `delegation` template.
4. `task_update` from the delegate marks the delegation completed, stores `result`, records `delegation_completed`, prompts the delegator with `delegation_completed`.
5. Ownership never changes.

**Handoff flow** (`Canopy.Collaboration.Handoff`):

1. `handoff_task` requires the caller to be the current owner.
2. `build_packet/…` assembles: summary/reason/next step from args, last 10 channel messages (ids only, not bodies), task row, `git status --porcelain`, `git diff --stat`, branch. Stored as JSON on the handoff.
3. Records `handoff_requested`, prompts target with `handoff` template.
4. `handoff_accept`: transaction sets `channels.owner_agent_id`, `handoffs.status = accepted`, `accepted_at`, records `handoff_accepted`, notifies previous owner. `handoff_reject`: status rejected, notifies previous owner with the reason.
5. UI shows the pending handoff in the header and lets the user accept/reject on the target's behalf (useful when an agent is stuck).

**User-initiated handoff and delegation**: the composer supports `/handoff @agent reason` and `/delegate @agent task` slash commands that hit the same context functions as a user actor (timeline text `Steven handed this task to @database`).

Tests: full-flow tests with the Mox client where tool calls are invoked directly on the tool modules; assert timeline order matches the doc's "Shared Timeline" example.

Deliverable: the doc's timeline example can be reproduced with two or three agents in one channel.

---

## 10. Phase 8 — Context on Demand and Search Quality

- `messages_read` supports `around:` (N before and after a message id) and `before:` pagination; default limit 20.
- FTS5 query sanitization (quote user input, support prefix matching with `*`).
- `channel_get` returns a short "state of the channel" block: owner, task status, last handoff, last five message ids with senders, so agents can orient with one call.
- Wake prompts never contain message bodies; enforce with a test.
- Add a `messages_read` variant `thread: message_id` to read one thread.

Deliverable: an agent woken cold can answer a question about earlier channel history using only tools.

---

## 11. Phase 9 — Hardening, Docs, Demo

1. **Reconnect and drift**: event stream backoff; on reconnect, reconcile `GET /session/status` and `GET /permission` so no permission card is missed.
2. **Abort and error states**: abort button per agent; `session.error` surfaces as a red system line and idle status.
3. **Token rotation**: rotating an agent token re-registers MCP for every repository the agent is active in.
4. **Security checks**: endpoint bound to loopback; MCP auth plug tested; repository paths validated; no user-supplied shell input reaches `System.cmd` (arguments only, never a shell string).
5. **Seeds**: `mix run priv/repo/seeds.exs` creates `@backend`, `@reviewer`, `@researcher`, `@test` with role prompts, and a sample repository if `CANOPY_SAMPLE_REPO` is set.
6. **Docs**: README quick start; `_claude_docs/architecture/` updated with spike answers and any deviations.
7. **Demo script** (`_claude_docs/demo.md`): the payment-retries scenario from the architecture doc, run against a small sample repo with a seeded bug, showing delegation and handoff in one channel.

Definition of done for v0: every item in the architecture doc's "V0 Scope" list has a checked box in the README, the demo script runs cleanly on a fresh clone with only `opencode serve` running, and `mix test` is green.

---

## 12. Sequencing and Estimates

| Phase | Depends on | Rough effort |
|---|---|---|
| 0 Spikes | – | 0.5 day |
| 1 Scaffold | – | 0.5 day |
| 2 Data model | 1 | 1.5 days |
| 3 OpenCode adapter | 0, 1 | 2 days |
| 4 Channel runtime | 2, 3 | 2 days |
| 5 LiveView UI | 2, 4 | 4 days |
| 6 MCP server | 0.5, 2 | 2 days |
| 7 Collaboration | 4, 6 | 3 days |
| 8 Context on demand | 6 | 1 day |
| 9 Hardening and demo | all | 2 days |

Phases 3 and 6 can proceed in parallel once Phase 2 lands. Phase 5 can start with a static timeline before Phase 4 is finished.

---

## 13. Risks and Open Questions

- **Identity plumbing through Anubis** (SPIKE 0.5). If `conn.assigns` do not reach `frame.assigns` on follow-up requests, use per-agent URLs (`/mcp/<token>`) so the router carries identity. Either way the model never supplies its identity.
- **`system` semantics on `prompt_async`** (SPIKE 0.2). If it replaces the agent prompt entirely, Canopy must include a base coding prompt or fall back to writing `.opencode/agents/<name>.md` into the repository, which the doc would rather avoid.
- **Tool gating** (SPIKE 0.2). If per-prompt `tools` does not support wildcards, enumerate the 14 names explicitly for every agent's server; that is ~14 × agents keys, fine.
- **OpenCode API churn.** The `session.next.*` events are new in 1.18; keep the normalizer isolated and fixture-tested so upgrades are one-file changes.
- **OTP 28 with Elixir 1.18.4.** Supported, but if any dependency misbehaves, pin OTP 27 in `.tool-versions`.
- **Child session events.** If child sessions do not appear on the parent's stream, subscribe by directory (already the plan) and route by session id.
- **Cost visibility.** `step.ended` carries cost and tokens; show per-turn cost in the telemetry summary so users notice runaway loops. Small addition, high value.

---

## 14. Spike Answers

_Fill in during Phase 0._

- 0.1 SSE shape:
- 0.2 `system` / `tools` semantics:
- 0.3 Runtime MCP registration:
- 0.4 Child sessions:
- 0.5 Anubis assigns:
