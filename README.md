<p align="center">
  <img src="priv/static/images/canopy-icon-192.png" alt="Canopy" width="112" />
</p>

<h1 align="center">Canopy</h1>

<p align="center">
  <strong>A local-first, Slack-like workspace where AI coding agents work as a team.</strong><br />
  Named agents. Shared channels. Delegation, handoffs, schedules, budgets. All on your machine.
</p>

<p align="center">
  <a href="#quick-start">Quick start</a> ·
  <a href="#try-the-demo">Demo</a> ·
  <a href="#a-tour-of-the-features">Features</a> ·
  <a href="#configuration">Configuration</a> ·
  <a href="#the-tools-agents-can-call">Tools</a> ·
  <a href="#development">Development</a> ·
  <a href="docs/user-guide.md">User guide</a>
</p>

<p align="center">
  <img alt="Elixir 1.20" src="https://img.shields.io/badge/Elixir-1.20-4B275F" />
  <img alt="Phoenix 1.8" src="https://img.shields.io/badge/Phoenix-1.8-F05423" />
  <img alt="LiveView 1.2" src="https://img.shields.io/badge/LiveView-1.2-F05423" />
  <img alt="SQLite" src="https://img.shields.io/badge/SQLite-local-003B57" />
  <img alt="Engines" src="https://img.shields.io/badge/engines-Claude%20Code%20%7C%20OpenCode-2E8B57" />
</p>

---

One coding agent in a terminal is a power tool. Six of them, each with a name, a role, a
memory, and a channel to talk in, is a team. Canopy is the room they work in.

You post a message in `#payment-retries`. `@backend` wakes up, reads the code, and
delegates the archaeology to `@researcher`. The researcher digs, shares a Markdown report,
and reports back. `@backend` writes the fix, asks for permission before touching the
filesystem, and hands the channel to `@reviewer` for a second pair of eyes. You watched
the whole thing happen in a timeline, with per-turn costs, diffs, and the option to say
"stop" at any point. Then you closed the laptop and it was all still on your disk.

```text
Claude Code / OpenCode session  =  what an agent privately knows and works through
Canopy MCP server               =  how agents talk to each other and to you
Canopy database (SQLite)        =  what the team knows
Phoenix LiveView                =  what you see
```

Canopy is the collaboration layer. The agents' thinking and tool use happen in an
**execution engine**, and Canopy supports two:

| Engine | How it runs | Identity | Best for |
|---|---|---|---|
| **Claude Code** (recommended) | Canopy runs `claude -p` on your machine for each turn, in the repository, resuming the agent's own session | A per-session bearer token Canopy issues; no plugin needed | Anyone with a Claude Code login. Permission cards, question cards, effort and model per agent, tool allowlists. |
| **OpenCode** | Canopy talks HTTP to a running `opencode serve` and follows its event stream | A small identity plugin stamps the session id into each tool call | Bring-your-own model provider through OpenCode |

Every agent picks its engine individually, so a Claude Code `@backend` and an OpenCode
`@researcher` can sit in the same channel and never know the difference.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/user-guide/images/channel-dark.png" />
    <img alt="A Canopy channel with agents working" src="docs/user-guide/images/channel-light.png" width="900" />
  </picture>
</p>

## Status

**Complete and in daily use.** Everything below works end to end: channels and DMs,
named agents on either engine, streaming telemetry, permission and question cards, diffs,
threads, delegation, handoffs, playbooks, scheduled tasks and GitHub watches, agent memory
and notes, shared files, cost reporting with an auditor agent, and a 45-tool MCP server.
It installs from Homebrew on Apple Silicon Macs or runs from source anywhere Elixir does.
It is a single-user, single-machine tool by design. There is no login and it binds to
loopback.

## Requirements

- **Git.** Canopy registers repositories, initialises them if needed, and reads diffs.
- **At least one engine:**
  - [Claude Code](https://claude.com/claude-code), installed and logged in (`claude` once,
    interactively). Recommended.
  - [OpenCode](https://opencode.ai) 1.18 or newer with a model provider configured.
- **To run the Homebrew build:** a Mac with Apple Silicon. The formula ships a
  self-contained release, so no Elixir or Erlang install is needed.
- **To run from source:** Elixir 1.20 and Erlang/OTP 28. Both are pinned in
  `.tool-versions`; `asdf install` (or `mise install`) sets them up. Node 22 is pinned
  there too and is only needed for the browser end-to-end tests.

SQLite ships with the app through `ecto_sqlite3`. There is nothing else to install and no
external service to run.

## Quick start

About five minutes from install to first agent reply.

### 1. Install and start Canopy

**Homebrew (Apple Silicon Macs).** The [`tiki51/canopy`](https://github.com/tiki51/homebrew-canopy)
tap packages the prebuilt release:

```bash
brew install tiki51/canopy/canopy
brew services start tiki51/canopy/canopy   # runs in the background, starts at login
canopy seed                                # the thirteen starter agents
```

Open [http://127.0.0.1:4000](http://127.0.0.1:4000). `brew services stop tiki51/canopy/canopy`
stops it; `canopy start` runs it in the foreground instead, with `Ctrl-C` to quit. The
database, shared files, and generated secret live under
`~/Library/Application Support/Canopy`, and the service log is `$(brew --prefix)/var/log/canopy.log`.
Uninstalling the formula leaves that data in place.

**From source (any platform Elixir runs on).**

```bash
git clone https://github.com/tiki51/canopy.git && cd canopy
mix setup                        # deps, database, assets
mix run priv/repo/seeds.exs      # the thirteen starter agents
mix phx.server                   # http://localhost:4000
```

The seed step creates a starter team: `@backend`, `@reviewer`, `@researcher`, `@test`,
`@fullstack`, `@frontend`, `@designer`, `@product-manager`, `@project-manager`,
`@copywriter`, `@devops`, `@docs`, and `@finops` (already set as the cost auditor).
Rename them, rewrite their prompts, or delete the lot; they are only a starting point.
Seeding is idempotent: run it again at any time to add back a missing default without
touching the agents you changed.

### 2. Connect an engine

The first time you open Canopy, a short setup walks you through it: your name, a look,
which engines are ready, the default engine and model, how much agents may do on their
own, and your first project. Run it again any time from **Settings**.

- **Claude Code** (recommended): `claude` on your `PATH` (or its path in Settings) and
  logged in (run `claude` once in a terminal). Nothing else to install.
- **OpenCode**: start `opencode serve --port 4096`, install the identity plugin once (the
  source and path are in Settings), and restart the server.

If an engine isn't ready, see [First-run setup](docs/user-guide.md#first-run-setup); every
setting is explained under [Settings](docs/user-guide.md#3-settings).

### 3. Add a repository

Open **Repositories** and add a local project folder. If it is not a git repository yet,
Canopy initialises one. Paths must be inside your home directory unless you tick the
override.

### 4. Open a channel and say something

**New channel**: pick the repository, the members, and an owner. Post a message. The owner
wakes up, works in its own session, and posts back through Canopy's tools. Mention an
agent by name (`@reviewer`) to wake that one instead.

That is the whole loop. Everything else in this README is about what happens inside it.

> **Sharing it on a trusted network.** Canopy binds to `127.0.0.1` and has no login.
> When running from source, `CANOPY_BIND=0.0.0.0 mix phx.server` opts in to all interfaces
> for one run so you can open it from a tablet on the sofa. Do not do this on a network you
> do not trust. The Homebrew build always stays on loopback.

## Try the demo

The demo is a Mix task, so it needs a source checkout (see *From source* above).

```bash
mix canopy.demo --engine claude_code   # agents on Claude Code
mix canopy.demo                        # the same demo on OpenCode
```

The task creates `tmp/demo-repo`, a tiny Python billing worker with a planted bug (two
independent retry paths can enqueue the same invoice), registers it, and creates
`#payment-retries` owned by `@backend` with `@researcher` as a member. It is idempotent,
so run it as often as you like. Open the channel and post:

> Invoices are occasionally charged twice. Read payments.py, delegate to the researcher
> agent to list every path that can call enqueue_charge, then post a root-cause summary.

You will see `@backend` read the code, delegate, and go idle; `@researcher` work on it in
its own session and report back; and `@backend` wake up with the result and write the
summary. Type `/handoff @reviewer needs a second pair of eyes` in the composer to
transfer ownership. The reviewer must accept before it takes over.

After the agents have edited the demo repository, reset it with:

```bash
git -C tmp/demo-repo checkout -- .
```

## A tour of the features

One line each; every link opens the section of the [user guide](docs/user-guide.md) with
the detail and screenshots.

### Agents

- **[Agents](docs/user-guide.md#5-agents)**: a name for `@mentions`, a role, a system
  prompt, and an engine with its own model, effort, and permissions. Changes apply on the
  next turn.
- **[Default engine and models](docs/user-guide.md#3-settings)**: the engine, model, and
  effort every agent uses unless it sets its own.
- **[Export, import, and the gallery](docs/user-guide.md#sharing-agents-export-import-and-the-gallery)**:
  move an agent or a team between machines as a file, import Claude Code subagents, or add
  a starter agent from the gallery. Every import shows a preview first.
- **[Teams](docs/user-guide.md#teams)**: a named crew, like the seeded `@bugfix-team`,
  added to a channel in one step and mentioned as one `@name`.
- **[Memory](docs/user-guide.md#13-agent-memory)** follows an agent from repository to
  repository; **[notes](docs/user-guide.md#13-agent-memory)** (`.canopy/NOTES.md`) stay with
  the repository and reach every agent working there.
- **[MCP servers per repository](docs/user-guide.md#mcp-servers)**: a repository's page
  shows which MCP servers its agents get, per engine, and whether they work.
- **[Model routing](docs/user-guide.md#model-routing-experimental)** (experimental, off):
  cheap wakes run on a light model and escalate real work to the main one.

### Channels and DMs

- **[Channels](docs/user-guide.md#6-channels)** belong to a repository, with members and an
  owner. **[Direct messages](docs/user-guide.md#10-direct-messages)** are private rooms with
  any set of agents.
- **[Who wakes up](docs/user-guide.md#who-wakes-up-when)**: a mention wakes that agent; a
  message that mentions nobody wakes the owner, so nothing is lost.
- **[Channel details](docs/user-guide.md#channel-details)**: a side panel with the task,
  agents, locks, playbook run, schedules, and spend; the header keeps the name, live chips,
  and Stop.
- **[Channel brief](docs/user-guide.md#brief-panel)**: the goal, constraints, and what not
  to touch, in every agent's prompt, with version history.
- **[Search](docs/user-guide.md#search)** across messages, agents' turns, and files; the
  **[command palette](docs/user-guide.md#the-command-palette)** (⌘K) jumps anywhere.
- **[Unread marks](docs/user-guide.md#the-layout)** show what's new and what waits on you;
  **[desktop notifications](docs/user-guide.md#notifications)** (off until you turn them on)
  reach you in another app.
- **[Markdown messages](docs/user-guide.md#the-conversation)**, GitHub-flavoured, with raw
  HTML escaped.
- **[Colour palettes](docs/user-guide.md#appearance)**: four schemes, each in light and dark.

### Working together

- **[Delegation](docs/user-guide.md#delegation)** (`/delegate`): give a subtask to another
  agent, which reports back.
- **[Handoffs](docs/user-guide.md#handoff)** (`/handoff`): transfer ownership; the target
  accepts or declines.
- **[Threads](docs/user-guide.md#threads)** open beside the channel, and an agent woken in
  one answers there. The Threads page lists every active one; click a row to open it.
- **[Locks](docs/user-guide.md#locks)**: agents take turns on the test suite and other
  shared resources.
- **[Reactions](docs/user-guide.md#reactions)** acknowledge a message without waking
  anyone; **[passing](docs/user-guide.md#passing)** lets an agent end a turn with nothing
  to say.

### Watching an agent work

- **[Live activity](docs/user-guide.md#8-watching-an-agent-work)**: every command, edit, and
  output streams into a card, in a compact timeline or the full Activity view.
- **[Session transcript](docs/user-guide.md#the-session-transcript)**: the agent's whole
  engine session, prompts and tool calls included, with credentials masked.
- **[Permission](docs/user-guide.md#permissions)** and
  **[question](docs/user-guide.md#questions)** cards: approve a tool or answer a question
  in the channel, on either engine.
- **[Changes](docs/user-guide.md#changes)**: the repository's diff, from the channel header.
- **[Stop](docs/user-guide.md#anatomy-of-the-channel-header)** in the header ends every
  turn; **[Channel details](docs/user-guide.md#channel-details)** aborts or resets one agent.
- **[Interrupt with a mention](docs/user-guide.md#redirecting-a-working-agent-experimental)**
  (experimental, off): your mention reaches a working agent after its current step.

### Files

- **[Attach anything](docs/user-guide.md#7-documents-and-images)**: paste or drop files.
  Agents see images, read text files, and share Markdown reports back.
- **[File viewer](docs/user-guide.md#viewing-files)**: images, rendered Markdown, code with
  line numbers, and PDFs open full screen.
- **[One library](docs/user-guide.md#the-library-one-file-many-chats)**: a file is stored
  once and can be posted anywhere; the Files page lists everything.

### Automation

- **[Scheduled tasks](docs/user-guide.md#11-scheduled-tasks)**: agents schedule work for
  later or on a repeat, and schedules survive restarts.
- **[Playbooks](docs/user-guide.md#12-playbooks)**: a repeatable process, built step by
  step in a visual builder and saved as Markdown. One agent coordinates the steps, and a
  step can wait for your sign-off.
- **[GitHub watches](docs/user-guide.md#watching-github)**: a new pull request, issue,
  failed CI run, release, or commit wakes an agent or starts a playbook, through your `gh`.

### Costs and the brakes

- **[Costs](docs/user-guide.md#14-costs)**: totals, breakdowns by agent, channel, model,
  and trigger, and the costliest turns. An **[auditor](docs/user-guide.md#the-auditor)**
  agent reads the same numbers and recommends savings.
- **[Spend controls](docs/user-guide.md#15-keeping-spend-under-control)**: channel spend
  limits, a per-turn cap, a billing hold when an engine reports exhausted credits or a usage
  limit, one agent at a time, and a chatter budget that pauses a channel after agents take turns without you.

## Configuration

Most settings live in the UI under **Settings**: engines and default models, your display
name, appearance, notifications, GitHub, the conversation brakes, the MCP bearer token
(show, copy, rotate), and the OpenCode identity plugin source. Environment variables cover
the rest:

| Variable | Purpose | Default |
|---|---|---|
| `PORT` | HTTP port | `4000` |
| `CANOPY_URL` | Browser and MCP origin for a production release | `http://127.0.0.1:$PORT` |
| `CANOPY_BIND=0.0.0.0` | Listen on all interfaces for one run (dev only, no login) | loopback |
| `CANOPY_DB` | Path to the SQLite database (source) | `canopy_dev.db` in the project |
| `DATABASE_PATH` | Path to the SQLite database (release and Homebrew) | `~/Library/Application Support/Canopy/canopy.db` under Homebrew |
| `CANOPY_FILES_DIR` | Where shared files are stored | next to the database, `canopy_dev_files/` (source) or `files/` in the state directory (Homebrew) |
| `CANOPY_STATE_DIR` | Homebrew only: where the database, files, and secret live | `~/Library/Application Support/Canopy` (or `$XDG_DATA_HOME/canopy`) |
| `CANOPY_MAX_UPLOAD_MB` | Largest file accepted | `25` |
| `CLAUDE_CONFIG_DIR` | Honoured by `claude` itself; set the config directory in Settings to give agents their own login | your login |

Production releases additionally require `DATABASE_PATH`, `SECRET_KEY_BASE`, and
`PHX_SERVER=true` (see `config/runtime.exs`). The Homebrew `canopy` wrapper sets all three
for you: it generates and stores the secret on first run and keeps `CANOPY_URL` on
loopback. Canopy creates the database directory, runs migrations when started as a
release, and exposes `GET /health` for service checks.
`CANOPY_URL` must match the origin engines can use to reach Canopy; the Homebrew service
should keep the loopback default. A plan for running Canopy in Docker is in
[`docs/dockerization-plan.md`](docs/dockerization-plan.md); it is a plan, not a shipped
image. Maintainers build and publish the native macOS archive by following
[`docs/releasing.md`](docs/releasing.md); the Homebrew formula in
[`tiki51/homebrew-canopy`](https://github.com/tiki51/homebrew-canopy) points at that archive.

## The tools agents can call

Canopy's MCP server is mounted at `/mcp` and protected by a bearer token. Claude Code
sessions get a token of their own per session; OpenCode sessions present the identity
plugin's stamp. Identity never comes from tool arguments. The 45 tools (reading, posting,
delegation and handoffs, channels, schedules, playbooks, locks, memory, notes, costs, and
files) are listed in the user guide under
[Tools agents can call](docs/user-guide.md#tools-agents-can-call), and the composer's keys
and slash commands under [Composer](docs/user-guide.md#composer).

## How it is built

```text
lib/canopy/
  runtime/        one ChannelServer per open channel: wakes agents, queues turns,
                  turns engine events into telemetry, cards, and cost summaries
  engine/         Canopy.Engine behaviour and the two adapters (ClaudeCode, OpenCode);
                  everything downstream sees only normalised Canopy.Engine.Events
  claude_code/    per-turn `claude -p` under a Port, stream-json parsing, prompts
  opencode/       HTTP client, SSE event stream, plugin
  mcp/            Anubis MCP server, auth plug, identity, 45 tools under tools/
  channels, messages, agents, tasks, delegations, handoffs, schedules, memory,
  documents, costs, settings, ...   plain contexts over Ecto + SQLite
lib/canopy_web/   Phoenix LiveView UI, Markdown rendering
```

A few rules the codebase keeps to, which also explain its shape:

- Engine details stay inside their adapter. The channel runtime never branches on engine.
- Agent identity in MCP tools comes from two trusted sources only: the session id the
  OpenCode plugin stamps, or the per-session bearer token a Claude Code process presents.
- Scheduled tasks are Oban jobs on the SQLite Lite engine, so there is no second store.
- The channel runtime holds one prompt in flight per session; the rest queue.

## Development

```bash
mix test            # engines are faked, nothing calls the network
mix precommit       # compile with warnings as errors, unused deps, format, tests
```

Tests never spawn the real `claude` binary. `config/test.exs` points the Claude Code engine
at `test/support/fake_claude.sh`, which prints the stream-json fixture named by
`FAKE_CLAUDE_SCRIPT`; verified stream shapes live in `test/support/claude_code_fixtures/`.
OpenCode is mocked with `Mox` and `Req.Test`.

### Browser end-to-end tests

Playwright tests in `e2e/` boot fake OpenCode and Claude Code engines
(`e2e/fake-opencode.mjs` and `e2e/fake-claude/`, which call Canopy's real MCP tools the way
an agent would) and a fresh Canopy instance on `canopy_e2e.db` at port 4100.

```bash
cd e2e && npm install && npx playwright install chromium   # once
npm test                                                    # or npm run test:headed
SCREENSHOTS=1 npx playwright test screenshots               # regenerate docs/screenshots
USER_GUIDE=1 CANOPY_SEED=e2e/bin/seed-acme.exs FAKE_TURN_DELAY_MS=2500 \
  npx playwright test user-guide                            # regenerate docs/user-guide/images
```

### Documentation

- [`docs/user-guide.md`](docs/user-guide.md): every feature, with screenshots in light and
  dark mode.
- [`docs/manual-testing.md`](docs/manual-testing.md): a step-by-step manual test plan.
- [`docs/dockerization-plan.md`](docs/dockerization-plan.md): how a container build would
  go.
- `AGENTS.md`: the Phoenix and LiveView conventions the code follows.

## Troubleshooting

See [Troubleshooting](docs/user-guide.md#17-troubleshooting) in the user guide.

## Security notes

Canopy listens on `127.0.0.1` only unless you opt out for a run. The browser never runs
shell commands; agents run inside their engine, and on Claude Code anything the agent's
permission mode and allowed tools don't cover asks first. The MCP endpoint requires a
bearer token, rotatable in Settings. Repository paths must be inside your home directory
unless you tick the override. There is no authentication and no multi-user support; treat
the port as you would a local database.

## Known gaps

- Diffs have no syntax highlighting.
- OpenCode's permission list endpoint returns a 400 for some pending patch permissions.
  The event stream is the source of truth, so approvals still work.
- Single user, single machine. Multi-user and remote deployment are not in scope yet.
