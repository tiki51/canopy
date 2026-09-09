# Canopy Architecture

## What Canopy Is

Canopy is an open-source, local-first interface for working with AI coding agents through a Slack-like experience.

Instead of treating coding agents as isolated terminal sessions, Canopy organizes work into persistent channels where agents behave more like coworkers:

- they have identities and roles
- they can own tasks
- they can work independently
- they can communicate meaningful findings
- they can ask another agent for help
- they can delegate subtasks
- they can hand work off to another agent
- their shared work remains visible in a channel timeline

The name **Canopy** reflects the product model: independent agents operate in their own working contexts, while the shared canopy connects them through messages, task coordination, delegation, and handoffs.

The initial version will support **OpenCode only**.

Claude Code and OpenAI Codex are future integrations. The architecture should leave room for them without introducing a generalized provider abstraction before it is actually needed.

---

## Core Architectural Principle

Canopy should not treat an OpenCode session transcript as the Slack conversation.

The two represent different things.

```text
OpenCode session
= private working context for an agent

Canopy channel
= shared communication and collaboration state
```

An agent's private session may contain:

- file reads
- searches
- intermediate reasoning
- test runs
- failed attempts
- tool calls
- implementation details

Only useful communication should become an Canopy message.

For example, an agent may internally perform dozens of operations and then intentionally post:

```text
@backend

I reproduced the duplicate invoice bug.

There are two independent retry paths. I've added a
regression test and I'm checking whether uniqueness should
be enforced at the database layer.
```

Canopy therefore acts as a **shared collaboration layer**, not merely a transcript viewer.

---

## Initial Product Goal

The first useful version should let a user:

1. Run Canopy locally.
2. Configure the location of an OpenCode server.
3. Create and view channels associated with a local repository.
4. Create multiple named agents with different roles.
5. Send messages to agents.
6. Stream agent activity in real time.
7. View useful execution telemetry such as commands, file edits, diffs, test runs, and status changes.
8. Approve or deny permission requests.
9. Allow agents to communicate through Canopy.
10. Allow agents to delegate work to one another.
11. Allow explicit ownership handoffs from one agent to another.
12. See those messages, delegations, handoffs, and task changes in a shared timeline.
13. Allow agents to retrieve relevant channel context on demand rather than receiving the full transcript automatically.

Automatic detection of installed coding harnesses is explicitly **not required** for the initial version.

---

## Core Product Concepts

### Repository

A local source repository that agents can work against.

Example:

```text
~/code/my-app
```

### Channel

A persistent unit of work associated with a repository.

Examples:

```text
# payment-retries
# auth-refactor
# flaky-tests
```

A channel belongs to Canopy rather than to OpenCode.

### Agent

A named AI coworker with a role.

Examples:

```text
@backend
Role: Primary implementation agent

@reviewer
Role: Code review and correctness

@researcher
Role: Explore the codebase and external documentation

@test
Role: Testing and debugging
```

Initially, these agents map to OpenCode agents.

### Agent Session

An OpenCode session used privately by an Canopy agent to perform work.

Agent sessions are runtime state. They are not themselves the shared channel history.

### Task Ownership

A channel can have an agent that currently owns the task.

For example:

```text
# payment-retries

Owner: @backend
Status: Working
```

Ownership can change through a handoff.

---

## Shared State vs. Private State

Canopy should make a clear distinction between shared collaboration state and private execution state.

```text
Canopy
|
+-- Shared collaboration state
|     |
|     +-- Channels
|     +-- Messages
|     +-- Threads
|     +-- Tasks
|     +-- Delegations
|     +-- Handoffs
|     +-- Decisions
|
+-- Private execution state
      |
      +-- @backend OpenCode session
      +-- @reviewer OpenCode session
      +-- @researcher OpenCode session
```

The shared state is durable and visible to the team.

The private session is the agent's own working context.

This separation prevents Canopy from turning into a giant synchronized prompt buffer.

---

## Canopy as an MCP Server

Canopy should expose its collaboration features to agents through an **MCP server**.

This makes Canopy something agents actively use rather than a UI that passively mirrors their work.

Conceptually:

```text
                         Browser
                           |
                           |
                     Phoenix LiveView
                           |
                           |
                     Canopy Core
                           |
                 +---------+---------+
                 |                   |
                 v                   v
          Canopy Database    MCP Server
                                     ^
                                     |
                                     |
                               OpenCode Agent
                                     |
                                     v
                              Private Session
```

Agents should use Canopy MCP tools to:

- read relevant channel messages
- search prior discussions
- post meaningful updates
- reply in threads
- inspect assigned work
- update task state
- delegate work
- request handoffs
- accept or reject handoffs

This provides a clean collaboration protocol that can later be shared by OpenCode, Claude Code, Codex, or other agent harnesses.

---

## Initial MCP Tool Surface

Keep the first MCP surface intentionally small.

Possible tools:

```text
channels_list
channel_get

messages_read
messages_search
message_send
thread_reply

task_get
task_update

agents_list

delegate_task

handoff_task
handoff_get
handoff_accept
handoff_reject
```

Additional tools can be added later when actual product needs justify them.

The MCP surface should avoid exposing every internal Canopy capability.

---

## Context on Demand

Incoming Canopy messages should not automatically cause the complete channel transcript to be appended to an agent's OpenCode context.

Instead, Canopy should wake or notify the relevant agent with a small prompt.

Example:

```text
You have a new Canopy message in #payment-retries
from Steven.

Message ID: msg_8721

Read the message and any necessary surrounding context
using the Canopy MCP tools, then respond appropriately.
```

The agent may then call:

```text
messages_read(
  channel: "payment-retries",
  around: "msg_8721"
)
```

or:

```text
messages_search(
  channel: "payment-retries",
  query: "database uniqueness decision"
)
```

This keeps agent context focused and makes Canopy history function as durable shared memory.

---

## Agent Communication

Agents should use Canopy messages deliberately.

They should not post every internal tool call or thought.

Bad:

```text
@backend
Reading foo.ex.

@backend
Now reading bar.ex.

@backend
Running grep.
```

Better:

```text
@backend

I found two independent retry paths that can enqueue the
same invoice. I've reproduced the race and added a regression
test. I'm checking whether the right fix belongs in the
database layer.
```

Raw agent activity can still be shown separately in the UI as collapsible telemetry:

```text
@backend is working...

  > Read 8 files
  > Ran mix test
  > Modified payment_worker.ex
```

This keeps the Slack-like timeline readable.

---

## Agent Identity

Agents should not be allowed to choose their own sender identity in MCP tool arguments.

Bad:

```text
message_send(
  from: "@backend",
  channel: "payment-retries",
  text: "..."
)
```

Instead, Canopy should bind identity to the MCP session or authenticated agent context.

Good:

```text
message_send(
  channel: "payment-retries",
  text: "..."
)
```

Canopy determines who sent the message.

This prevents accidental or intentional impersonation and creates trustworthy authorship.

Later, agent capabilities can also be permissioned.

Example:

```text
@researcher
  can_send_messages: true
  can_delegate: false
  can_handoff: false

@backend
  can_send_messages: true
  can_delegate: true
  can_handoff: true
```

---

## Agent Collaboration

Agent collaboration is a core feature rather than a future enhancement.

There are two important collaboration modes.

### Delegation

An agent remains responsible for the task but asks another agent to perform a subtask.

Example:

```text
@backend

I think the retry logic is wrong.

@researcher, trace every place PaymentWorker can be
scheduled and report back.
```

The researcher performs the work in a child session and returns a result.

The original agent still owns the channel.

Conceptually:

```text
@backend
    |
    +-- delegates --> @researcher
                          |
                          +-- investigates
                          |
                          +-- reports back
    |
    +-- continues owning task
```

OpenCode's subagent and child-session capabilities can provide much of the underlying execution model.

---

### Handoff

A handoff transfers responsibility for the task.

Example:

```text
@backend

I've isolated the race condition and added a regression test.
The fix needs careful database work.

Handing this to @database.
```

Canopy records the ownership change:

```text
@backend -> @database
```

The distinction is intentional:

```text
Delegation = "Help me with this."

Handoff = "This is yours now."
```

---

## Handoff Packet

Agents should not rely on reconstructing context from an entire transcript.

Canopy should store a structured handoff packet containing information such as:

```text
Task:
Fix duplicate invoices caused by PaymentWorker retries.

Previous owner:
@backend

New owner:
@database

What we know:
- Duplicate jobs originate from two independent retry paths.
- A regression test now reproduces the failure.
- Locking in PaymentWorker was considered but may be insufficient.

Work completed:
- Added concurrency regression test.
- Added logging around retry scheduling.

Current repository state:
Branch: fix/payment-retries

Modified files:
- lib/payment_worker.ex
- test/payment_worker_test.exs

Suggested next step:
Review whether the uniqueness guarantee belongs at the database layer.
```

The packet can initially be generated from:

- the previous agent's explicit summary
- relevant recent channel messages
- task metadata
- git status
- git diff
- modified files

The receiving agent can inspect the repository directly for additional details.

---

## Handoff Flow

A first implementation can be intentionally simple.

### 1. Current agent requests handoff

Through MCP:

```text
handoff_task(
  to: "@database",
  summary: "...",
  reason: "...",
  suggested_next_step: "..."
)
```

### 2. Canopy creates a handoff record

Status:

```text
requested
```

### 3. Canopy records the event in the channel timeline

```text
@backend handed this task to @database
```

### 4. Canopy wakes the receiving agent

The new agent receives a small notification:

```text
You have received a task handoff from @backend
in #payment-retries.

Handoff ID: ho_921

Use Canopy MCP tools to inspect the handoff and
relevant channel context.
```

### 5. Receiving agent retrieves context

For example:

```text
handoff_get("ho_921")
messages_search(...)
```

The receiving agent can also inspect:

```text
git status
git diff
```

directly through its coding harness.

### 6. Receiving agent accepts

Through MCP:

```text
handoff_accept("ho_921")
```

Canopy changes ownership:

```text
channel.owner_agent_id = database
handoff.status = accepted
```

### 7. Timeline records the transition

```text
@database accepted the handoff
```

### 8. New owner continues work

The old agent's private session remains available and can be resumed if needed.

---

## Delegation Flow

Delegation is similar but does not transfer ownership.

Example:

```text
delegate_task(
  to: "@researcher",
  task: "Find every path that can enqueue PaymentWorker."
)
```

Canopy records:

```text
@backend delegated a subtask to @researcher
```

The delegated agent receives its own child or independent OpenCode session.

When finished, it updates the task:

```text
task_update(
  status: "completed",
  result: "Found three enqueue paths..."
)
```

Canopy then notifies the delegating agent that the subtask has completed.

---

## Shared Timeline

Canopy should show collaboration events alongside normal messages.

Example:

```text
Steven
Figure out why invoices are occasionally duplicated.

@backend
I'm tracing the retry paths.

> Read PaymentWorker
> Read InvoiceWorker
> Ran tests

@backend
There are two independent retry mechanisms.

@backend delegated investigation to @researcher

@researcher
I found another enqueue path in RetryScheduler.

@researcher completed delegated task

@backend
That confirms the diagnosis. I've added a regression test.

@backend handed off ownership to @database

@database accepted the handoff

@database
Reviewing the current diff and schema constraints.
```

This timeline is one of the main ways Canopy differs from a conventional coding-agent UI.

---

## Initial Architecture

```text
                              Browser
                                |
                                |
                          Phoenix LiveView
                                |
                                |
                          Phoenix PubSub
                                |
                                |
                         Canopy Core
                                |
                 +--------------+--------------+
                 |                             |
                 v                             v
          Collaboration DB               MCP Server
                                                ^
                                                |
                                                |
                                      OpenCode Agents
                                                |
                                                v
                                         Private Sessions
                                                |
                                                v
                                          Local Repository

                 Canopy Core
                        |
                        v
                 OpenCode Adapter
                        |
                   HTTP + SSE
                        |
                        v
                 OpenCode Server
```

Canopy does not initially need to launch or discover OpenCode automatically.

The user can configure an OpenCode server URL such as:

```text
http://127.0.0.1:4096
```

Later versions may manage the OpenCode process automatically.

---

## Technology Stack

### Application Runtime

**Elixir**

Responsible for:

- agent orchestration
- task ownership
- collaboration state
- handoffs
- delegation
- session lifecycle
- OpenCode integration
- MCP server
- repository and git state
- process supervision

### Web Framework

**Phoenix**

Responsible for:

- local HTTP application
- routing
- PubSub
- process supervision
- MCP HTTP transport if used
- future remote access

### UI

**Phoenix LiveView**

Responsible for:

- channel navigation
- message timeline
- streaming responses
- execution telemetry
- approval cards
- handoff UI
- delegation UI
- agent status
- task ownership

Use small JavaScript hooks only where needed.

### Persistence

**SQLite + Ecto**

Initial data will likely include:

```text
repositories
channels
agents
agent_sessions
messages
threads
timeline_events
tasks
handoffs
delegations
user_preferences
```

### MCP

Use a native Elixir MCP implementation where practical.

The MCP server should be supervised as part of the Phoenix/OTP application.

---

## OpenCode Integration

OpenCode exposes a local HTTP server and an SSE event stream.

Canopy should communicate directly with that server.

Important OpenCode capabilities include:

- list sessions
- create sessions
- create child sessions
- read session messages
- send prompts asynchronously
- inspect session status
- retrieve diffs
- abort running sessions
- respond to permission requests
- list available agents
- receive server events over SSE

Initially this can be implemented with standard Elixir HTTP tooling.

Possible libraries:

```text
Req
Finch
Mint
```

The adapter should expose an Canopy-friendly API rather than leaking OpenCode HTTP details throughout the application.

Example:

```elixir
Canopy.OpenCode.create_session(...)
Canopy.OpenCode.send_message(...)
Canopy.OpenCode.children(...)
Canopy.OpenCode.diff(...)
Canopy.OpenCode.approve(...)
Canopy.OpenCode.abort(...)
```

---

## Normalized Execution Events

OpenCode emits execution events that Canopy may want to show as telemetry.

These should be normalized separately from intentional Canopy messages.

For example:

```elixir
{:agent_status, status}

{:tool_started, tool}

{:tool_completed, result}

{:file_read, path}

{:file_changed, diff}

{:command_started, command}

{:command_completed, result}

{:approval_required, request}

{:agent_completed, metadata}

{:agent_error, reason}
```

These events are useful for UI visibility but should not automatically become durable Slack-like messages.

---

## OTP Process Model

Agent activity maps naturally onto OTP.

A possible structure:

```text
Canopy.Application
|
+-- Canopy.Repo
|
+-- Phoenix.PubSub
|
+-- Canopy.MCP
|
+-- ChannelRegistry
|
+-- ChannelSupervisor
      |
      +-- ChannelProcess
      |      |
      |      +-- @backend session
      |      +-- @reviewer session
      |      +-- @researcher session
      |
      +-- ChannelProcess
             |
             +-- @backend session
```

A channel process can maintain:

- repository
- active owner
- active agents
- OpenCode session IDs
- pending handoffs
- pending delegations
- current task status

OpenCode SSE events are normalized and broadcast to the appropriate channel through Phoenix PubSub.

MCP operations update durable collaboration state through normal Canopy application services.

---

## Suggested Data Model

### repositories

```text
id
name
path
created_at
updated_at
```

### channels

```text
id
repository_id
name
status
owner_agent_id
created_at
updated_at
```

### agents

```text
id
name
display_name
role
opencode_agent_id
created_at
updated_at
```

### agent_sessions

```text
id
channel_id
agent_id
opencode_session_id
parent_session_id
status
created_at
updated_at
```

### messages

```text
id
channel_id
agent_id
user_id
thread_id
body
created_at
```

Only one of `agent_id` or `user_id` should identify the sender.

### tasks

```text
id
channel_id
owner_agent_id
title
description
status
result
created_at
updated_at
```

### handoffs

```text
id
channel_id
task_id
from_agent_id
to_agent_id
source_session_id
target_session_id
status
summary
reason
suggested_next_step
created_at
accepted_at
completed_at
```

Possible statuses:

```text
requested
accepted
rejected
completed
cancelled
```

### delegations

```text
id
channel_id
task_id
from_agent_id
to_agent_id
parent_session_id
child_session_id
description
status
result
created_at
completed_at
```

### timeline_events

```text
id
channel_id
agent_id
event_type
payload
created_at
```

Timeline events represent non-message events such as:

```text
handoff_requested
handoff_accepted
task_completed
delegation_created
delegation_completed
agent_started
agent_stopped
```

---

## Initial UI Structure

The initial desktop-oriented interface should use a Slack-inspired layout.

```text
+----------+-------------------+-----------------------------+
|          |                   |                             |
| WORKSP.  | CHANNELS          | # payment-retries           |
|          |                   |                             |
|          | my-app            | Steven                      |
|          |  # payments       | Why is this failing?        |
|          |  # migration      |                             |
|          |  # auth           | @backend                    |
|          |                   | I found the issue...        |
|          | agents            |                             |
|          |  @backend         | > Read 8 files              |
|          |  @reviewer        | > Ran tests                 |
|          |  @researcher      | > Changed 2 files           |
|          |                   |                             |
|          |                   | [ Message channel... ]      |
+----------+-------------------+-----------------------------+
```

The UI should borrow Slack's navigation conventions without attempting to recreate Slack exactly.

The conversation area should prioritize:

- intentional agent messages
- user messages
- delegation events
- handoff events
- task status
- readable long-form responses
- collapsible execution telemetry
- code diffs
- test summaries
- permission cards

---

## Git and Repository Integration

Canopy should treat the repository as shared observable state.

Important information includes:

- repository path
- current branch
- git status
- changed files
- diff
- worktree path

The repository itself becomes an important shared source of truth between agents.

An agent receiving a handoff does not need every prior implementation detail if it can inspect the current working tree.

Later versions may support creating dedicated git worktrees for parallel agent work.

---

## Future Provider Support

Claude Code and Codex can be added later.

When additional providers are implemented, each harness can retain its own private session model while using Canopy MCP for shared collaboration.

Conceptually:

```text
                 Canopy MCP
                       |
             shared collaboration API
                       |
          +------------+------------+
          |            |            |
          v            v            v
       OpenCode      Codex      Claude Code
```

This means provider handoffs do not require converting one harness's internal session into another harness's session.

Instead, agents communicate through:

- Canopy messages
- tasks
- handoff packets
- shared repository state
- git diffs
- searchable channel history

When the second provider is implemented, the OpenCode-specific execution boundary can be generalized into a provider behaviour.

Do not design that abstraction prematurely.

---

## Security Principles

Canopy will control tools capable of reading files, modifying source code, and executing shell commands.

Basic principles:

- The browser should never directly execute shell commands.
- Agent processes should run through backend adapters.
- Agent MCP identity must be server-bound rather than user-supplied.
- Permission requests should be explicit and visible.
- Sensitive tool activity should be auditable.
- MCP tools should expose the minimum collaboration surface necessary.
- Remote access should be disabled by default in early versions.
- Local-first operation should remain the default.

---

## V0 Scope

Build:

- Phoenix + LiveView application
- SQLite persistence
- manually configured OpenCode server
- repository creation
- channel creation
- named agent configuration
- OpenCode session creation
- OpenCode session history
- streaming via SSE
- message composer
- execution telemetry
- permission requests
- basic diff viewing
- Canopy MCP server
- channel message tools
- message search/read tools
- task ownership
- delegation
- explicit agent handoffs
- context-on-demand for agents

Do **not** build yet:

- Claude Code support
- Codex support
- automatic harness discovery
- automatic OpenCode installation
- desktop packaging
- mobile application
- remote access
- team accounts
- cloud synchronization
- complex worktree orchestration
- generalized provider abstraction
- automatic dumping of complete channel history into agent context

---

## Desktop Application

Desktop packaging is intentionally out of scope for the first version.

Initial development should run as:

```bash
mix phx.server
```

with the interface available through localhost.

If the project gains traction, Elixir Desktop is a possible future packaging option.

The architecture should not depend on any specific desktop shell.

---

## Future Possibilities

Once the core experience works, possible additions include:

- Claude Code support
- Codex support
- automatic harness detection
- desktop packaging
- system notifications
- tray/menu-bar integration
- remote access
- mobile interface
- git worktree management
- cross-agent reviews
- persistent named agent roles
- scheduled tasks
- repository-wide search
- richer transcript search
- MCP integrations beyond Canopy itself
- team/shared installations
- encrypted remote relay

These should not be required for the initial version.

---

## Guiding Principle

Canopy is not primarily a prettier frontend for OpenCode.

OpenCode is the first execution engine.

Canopy is the **shared collaboration layer above the agents**, the environment where they communicate, coordinate, and hand work between one another.

The core model is:

```text
OpenCode session
= what an agent privately knows and works through

Canopy MCP
= how agents communicate and coordinate across the shared canopy

Canopy database
= what the team knows

Phoenix LiveView
= what the user sees
```

The central product idea is:

> AI coding agents should behave less like isolated CLI sessions and more like coworkers who can communicate intentionally, own work, ask each other for help, and hand tasks off when another agent is better suited to continue.
