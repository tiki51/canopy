# Canopy user guide

Canopy is a local-first, Slack-like workspace for AI coding agents. You give agents names
and roles, put them in channels tied to your repositories, and talk to them the way you
would talk to teammates. Agents read the channel, work in their own OpenCode session, post
back, delegate to each other, hand work off, schedule follow-ups, and remember what they
learn. Everything runs on your machine; OpenCode is the only execution engine.

This guide walks through every feature with screenshots from a fictional company, Acme,
whose billing team is chasing an invoice that gets charged twice. Every screen is shown in
light mode and then in dark mode. The theme follows your system by default; the three
buttons at the bottom of the left rail switch between system, light, and dark.

> The screenshots come from Canopy's browser test suite running against a scripted
> stand-in for OpenCode. Everything on screen is real Canopy; the handful of live agent
> replies in the "Watching an agent work" section are placeholder text from that stand-in.

## Contents

1. [How Canopy thinks](#1-how-canopy-thinks)
2. [Getting started](#2-getting-started)
3. [Settings](#3-settings)
4. [Repositories](#4-repositories)
5. [Agents](#5-agents)
6. [Channels](#6-channels)
7. [Documents and images](#7-documents-and-images)
8. [Watching an agent work](#8-watching-an-agent-work)
9. [Working together: delegation, handoff, threads](#9-working-together-delegation-handoff-threads)
10. [Direct messages](#10-direct-messages)
11. [Scheduled tasks](#11-scheduled-tasks)
12. [Agent memory](#12-agent-memory)
13. [Costs](#13-costs)
14. [Keeping spend under control](#14-keeping-spend-under-control)
15. [Reference](#15-reference)
16. [Troubleshooting](#16-troubleshooting)

---

## 1. How Canopy thinks

Four ideas explain almost everything on screen.

- **A repository** is a local git folder. Agents run inside it. Every channel belongs to
  exactly one repository.
- **An agent** is a named coworker: a role, a system prompt, an OpenCode agent (`build`,
  `plan`, and so on), and optionally a model. Agents are shared across repositories.
- **A channel** is one task in one repository with a set of member agents and one owner.
  Each member gets its own private OpenCode session per channel, so what it learns in
  `#payment-retries` does not leak into `#checkout-latency`.
- **The timeline** is the durable record of a channel: your messages, agent posts,
  and events such as "started working", "delegated", "handed off", or "spend limit reached".

```text
OpenCode session  = what an agent privately knows and works through
Canopy MCP tools  = how agents communicate and coordinate
Canopy database   = what the team knows
The browser       = what you see
```

Agents never see the whole channel dumped into their context. A wake-up prompt tells an
agent what happened and which message to look at; the agent then pulls exactly what it
needs through Canopy's tools. That keeps turns cheap and is why the Costs page matters.

### Who wakes up when

- **Your message** wakes the agents you mention. If you mention nobody, the channel's
  owner wakes. In a direct message, every agent in it wakes.
- **An agent's post** wakes the agents it mentions, otherwise the author of the thread it
  replied in, otherwise the owner. Unaddressed posts are never lost.
- **A delegation** wakes the delegate in a child session; its result wakes the delegator.
- **A handoff** wakes the target, who must accept or decline.
- **A scheduled task** wakes its agent at the chosen time.

Write "the researcher agent" if you want the owner to handle something *about* the
researcher; write `@researcher` if you want the researcher itself to answer.

---

## 2. Getting started

You need Elixir 1.20 with Erlang/OTP 28, OpenCode 1.18 or newer with at least one model
provider configured, and git.

```bash
mix setup                      # dependencies, database, and four starter agents
opencode serve --port 4096     # in a second terminal, leave it running
mix phx.server                 # http://localhost:4000
```

Then, in the browser:

1. **Settings**: confirm the OpenCode URL and press *Check connection*.
2. **Install the identity plugin** once (Settings explains where). It stamps the OpenCode
   session id into every Canopy tool call so Canopy knows which agent is speaking.
   Restart `opencode serve` afterwards.
3. **Repositories**: add a project folder.
4. **New channel**: pick the repository, the members, and an owner. Post a message. The
   owner wakes up, works, and posts back.

Canopy binds to `127.0.0.1` only. There is no login, so keep it that way unless you are
on a network you trust: `CANOPY_BIND=0.0.0.0 mix phx.server` opts in for one run.

### The layout

The left **rail** holds Repositories, Agents, Costs, and Settings, with the theme buttons
at the bottom. The **sidebar** lists channels grouped by repository (archived ones fold
away), direct messages, and agents. The main area shows the page you are on. On a narrow
window the sidebar becomes a drawer behind a menu button.

In the sidebar, a channel with something you have not read yet turns bold with a dot.
When an agent mentions you by your display name, the dot becomes a badge with the number
of mentions. Opening the channel clears both. Agent rows show a green dot while the agent
is working and a small clock with a count when it has scheduled tasks.

---

## 3. Settings

Settings is where Canopy meets OpenCode. Open it from the gear in the rail.

![Settings, light](user-guide/images/settings-light.png)

![Settings, dark](user-guide/images/settings-dark.png)

- **OpenCode server**: the URL of your `opencode serve`. *Check connection* shows the
  version it answered with, in green when it worked.
- **You**: the display name on your messages. Agents mention you with it, and the
  sidebar's mention badges count those.
- **Conversation**: the brakes, both optional. *One agent at a time per channel* makes
  agents woken together take turns instead of running at once. *Pause a channel after
  agents have taken turns without me* is a check-in: when it is on, a channel holds after
  the number of agent turns you set until you type or press Continue. Leave it off when
  you want agents to run autonomously for as long as the work takes, and use spend limits
  as the backstop instead.

Scroll down for the MCP bridge.

![Settings, MCP bridge, light](user-guide/images/settings-mcp-light.png)

![Settings, MCP bridge, dark](user-guide/images/settings-mcp-dark.png)

- **MCP** shows the endpoint Canopy registers with OpenCode, the bearer token that
  protects it (show, copy, or rotate it; rotating needs nothing else, Canopy re-registers
  on the next prompt), and the source of the identity plugin with a copy button and the
  path to put it at. Canopy also drops the plugin into every registered repository under
  `.opencode/plugins/`, excluded from git, so the global copy is a convenience.

### The billing hold

When OpenCode reports an exhausted balance or quota, Canopy stops spending on your behalf:
every schedule pauses, wake-ups are dropped with one note per channel, and a red banner
appears on every page until you release it.

![Billing hold banner, light](user-guide/images/hold-banner-light.png)

![Billing hold banner, dark](user-guide/images/hold-banner-dark.png)

*Release hold* resumes the paused schedules. The next message in a channel wakes agents
again. Agents are also told never to poll for a human: they ask once and wait for you.

---

## 4. Repositories

A repository is any local project folder. If it is not a git repository yet, Canopy runs
`git init` there; otherwise it never modifies the folder itself.

![Repositories, light](user-guide/images/repositories-light.png)

![Repositories, dark](user-guide/images/repositories-dark.png)

Each row shows the current branch, how many channels live in it, a shortcut to create a
channel there, and a delete button. Paths must be inside your home directory unless you
tick *Allow a path outside my home directory*.

Registering a repository also creates a small `.canopy/` workspace inside it (a README,
shared notes, and one notes file per agent), listed in `.git/info/exclude` so it never
shows up in your diffs.

---

## 5. Agents

Agents are the coworkers. `mix setup` creates four: `@backend`, `@reviewer`,
`@researcher`, and `@test`. Acme added `@finops` to watch spending and `@docs`, which is
currently deactivated.

![Agents, light](user-guide/images/agents-light.png)

![Agents, dark](user-guide/images/agents-dark.png)

The list shows each agent's role, the OpenCode agent it runs as, its model, and how many
scheduled tasks it has. The *deactivated* toggle at the bottom reveals retired agents with
a *Reactivate* button. Clicking a row, or an agent in the sidebar, opens its page.

### An agent's page

![Agent page, light](user-guide/images/agent-page-light.png)

![Agent page, dark](user-guide/images/agent-page-dark.png)

- **About**: status, role, OpenCode agent, model with its price per million tokens (from
  OpenCode's provider list), spend today, this week, and all time, and the system prompt.
- **Memory**: what the agent carries across every repository and channel. See
  [Agent memory](#12-agent-memory).
- **Scheduled**: the agent's schedules across all channels, each with a link and a cancel
  button.
- **Channels**: every channel the agent belongs to, owned ones marked.
- **Message** opens (or creates) your direct message with the agent. **Edit** opens the
  form. The power icon deactivates the agent.

### Creating and editing an agent

![Edit agent, light](user-guide/images/agent-edit-light.png)

![Edit agent, dark](user-guide/images/agent-edit-dark.png)

- **Name** is the slug used for `@name`. **Display name** is what the list shows.
- **Role** is one line that other agents and the sidebar see.
- **System prompt** is the agent's personality and standing instructions. It is sent with
  every prompt on top of OpenCode's own agent prompt.
- **OpenCode agent**: `build`, `plan`, or any agent your OpenCode server offers. The
  suggestions come from the server.
- **Model provider** and **Model** are optional overrides; leave them blank to use the
  OpenCode agent's default. The line under them shows the price of the chosen model.

Changing the model or the prompt takes effect on the agent's next turn; no reset needed.
If an existing session has talked itself into a corner, reset it from the channel header
(the arrow on the agent's pill), and the next turn starts fresh with the new settings.

Pick a cheap model for agents that mostly acknowledge and report, and keep the expensive
one for the agent that edits code. The Costs page will tell you whether that split holds.

---

## 6. Channels

A channel is a focused room for one task in one repository.

### Creating a channel

Press **+** next to *Channels* in the sidebar, or *Channel* on a repository row.

![New channel, light](user-guide/images/new-channel-light.png)

![New channel, dark](user-guide/images/new-channel-dark.png)

- **Name** is a slug shown as `#name`. **Topic** is one line; it also becomes the task
  title.
- **Members** are the agents allowed in. All active agents are ticked by default; untick
  the ones that do not belong. Fewer members means fewer accidental wake-ups.
- **Initial owner** is woken for every message that mentions nobody. Only members can own.
- **Spend limit** is optional: the total, in dollars, the channel may spend before agents
  in it go quiet. See [Keeping spend under control](#14-keeping-spend-under-control).

Agents can create channels too, through `canopy_channel_create`. Ask one to "create a
channel called retry-backoff with @reviewer and post a plan" and it appears in the
sidebar with the agent as owner.

![Empty channel, light](user-guide/images/channel-empty-light.png)

![Empty channel, dark](user-guide/images/channel-empty-dark.png)

### Anatomy of the channel header

From left to right on the top row: the channel name and topic, then the buttons
**Members**, **Activity**, **Scheduled** (with a count), the **budget** (spent so far,
and the limit when there is one), **Task**, **Changes**, and **Archive**.

The second row shows the owner badge, the task status pill, the task title, the git
branch, and one pill per member. A member's dot is grey when idle, green while working,
amber while waiting for its turn, and red after an error. A working agent's pill has an
**Abort** button; an idle agent's pill has a small reset arrow that drops its OpenCode
session in this channel (with a confirmation) so its next turn starts with a clean
context.

### The conversation

Here is Acme's `#payment-retries` from the top. Priya asked `@backend` for a root cause,
`@backend` read the code and posted findings in Markdown, then delegated the caller
search to `@researcher`.

![Channel conversation, light](user-guide/images/channel-conversation-light.png)

![Channel conversation, dark](user-guide/images/channel-conversation-dark.png)

Messages are GitHub-flavoured Markdown: headings, lists, tables, fenced code, and inline
code all render. Mentions are highlighted. Raw HTML is escaped and unsafe links are
dropped, so an agent cannot inject markup into your page.

Between messages, the timeline records what happened: system lines for delegations,
handoffs, ownership changes, task updates, schedules, permissions, and spend limits. Times
are shown in your local time zone.

Further down, the same channel after the fix: `@backend` handed the task to `@reviewer`,
the reviewer accepted (the owner badge changed), reviewed, and finally *passed* on Priya's
thank-you because there was nothing to add.

![Channel, light](user-guide/images/channel-light.png)

![Channel, dark](user-guide/images/channel-dark.png)

### The composer

Type at the bottom. **Enter** sends, **Shift+Enter** adds a line. Typing `@` suggests the
channel's members.

![Composer autocomplete, light](user-guide/images/composer-autocomplete-light.png)

![Composer autocomplete, dark](user-guide/images/composer-autocomplete-dark.png)

Two slash commands are built in:

| Command | What it does |
|---|---|
| `/delegate @agent task` | Delegates a subtask to a member; it works in a child session and reports back |
| `/handoff @agent reason` | Asks a member to take over ownership of the channel's task |

While an agent is working, a second message from you queues and runs when the turn ends.

### Compact timeline and the Activity view

By default the timeline hides routine lines: "started working", clean "finished" lines,
and scheduled fires. Errors, passes with a note, and anything you can act on always show.
**Activity** in the header shows everything, and the browser remembers your choice.

![Channel with Activity on, light](user-guide/images/channel-activity-light.png)

![Channel with Activity on, dark](user-guide/images/channel-activity-dark.png)

Each finished line reads `@agent finished · N tools · $cost · duration`. Click it to open
the card of what the agent did: every tool call, every file it touched, and its closing
note. A turn that spoke through the tools keeps its closing text on this card instead of
posting it twice; a turn that posted nothing ends with a muted **REPLY** message instead.

### Task panel

**Task** opens the channel's task: a title, a status (`open`, `working`, `blocked`, or
`completed`), and a description. Agents update it through `canopy_task_update`; you can edit it
here. Every change lands on the timeline.

![Task panel, light](user-guide/images/task-panel-light.png)

![Task panel, dark](user-guide/images/task-panel-dark.png)

### Members panel

**Members** lists the members as pills, the owner marked and not removable. Pick an agent
in the dropdown and *Add*, or press × on a pill to remove one. Agents can do the same with
`canopy_channel_add_members` and `canopy_channel_remove_members`; only the owner may
remove someone, and never itself.

![Members panel, light](user-guide/images/members-panel-light.png)

![Members panel, dark](user-guide/images/members-panel-dark.png)

### Scheduled panel

**Scheduled** lists the channel's scheduled tasks with their next run and a cancel button.
See [Scheduled tasks](#11-scheduled-tasks).

![Schedules panel, light](user-guide/images/schedules-panel-light.png)

![Schedules panel, dark](user-guide/images/schedules-panel-dark.png)

### Budget panel

The budget button shows what the channel has spent and its limit. Opening it lets you set,
raise, or remove the limit.

![Budget panel, light](user-guide/images/budget-panel-light.png)

![Budget panel, dark](user-guide/images/budget-panel-dark.png)

### Changes

**Changes** shows `git status` for the repository. Click a file for its diff. Files under
`.canopy/` are ignored, so agent notes never count as changes.

![Changes modal, light](user-guide/images/changes-modal-light.png)

![Changes modal, dark](user-guide/images/changes-modal-dark.png)

### Archiving

**Archive** (with a confirmation) closes the channel: an *archived* badge appears, the
composer becomes a notice with a **Reopen** button, and the sidebar folds the channel
under an "archived" toggle. Agents see it as archived in `canopy_channels_list`.

![Archived channel, light](user-guide/images/archived-channel-light.png)

![Archived channel, dark](user-guide/images/archived-channel-dark.png)

---

## 7. Documents and images

Files travel with messages the way they do in Slack: a screenshot of a bug, a log, a
design to react to, a report an agent wrote. A file is stored once, can be posted in any
channel or DM, and agents can see it, read it, and share files of their own.

### Attaching a file

Paste a screenshot from the clipboard, drop a file on the composer, or click the folder
button to pick one from your computer. Each file shows as a chip with its progress until
you send; the × removes it. A message can be files only. Ten files per message, 25 MB each
by default (`CANOPY_MAX_UPLOAD_MB`).

### Asking for feedback on an image

Attach the image to the message that asks the question and mention who should look. The
agent receives the picture itself in its prompt, not a description of it, so a multimodal
model can comment on what it sees. Here Priya asks @researcher whether a new logo holds up
at header size:

![Asking for feedback on an image, light](user-guide/images/image-feedback-light.png)

![Asking for feedback on an image, dark](user-guide/images/image-feedback-dark.png)

Images render inline under the message and open full size in a new tab. The same goes for
screenshots of errors, admin pages, and designs: in `#payment-retries`, the retry log from
a support ticket travels with the bug report.

![Attachments on messages, light](user-guide/images/attachments-light.png)

![Attachments on messages, dark](user-guide/images/attachments-dark.png)

### Documents

Anything that is not an image is a card with the file's kind, size, and a download arrow:
Markdown, text, CSV, JSON, PDF, logs, diffs. Text files are readable by agents; PDFs and
other binaries are download only. Agents publish their own files this way too, most often
a Markdown report; in the screenshot above, @researcher's caller list is a shared
`enqueue-charge-callers.md` rather than a long post.

### The library: one file, many chats

The paperclip button next to the folder opens the library: every file shared anywhere in
Canopy, by you or by an agent, with search. Pick one and it joins your next message
without being uploaded again.

![Library picker, light](user-guide/images/library-picker-light.png)

![Library picker, dark](user-guide/images/library-picker-dark.png)

### The Files page

The paperclip icon in the rail opens the Files page: every shared file, who shared it,
when, and which chats it was posted in, with search and a filter by kind. **Share to…**
drops a file into another channel's composer, ready to send. **Delete** removes the file
from the store and from every message that carried it.

![Files page, light](user-guide/images/files-page-light.png)

![Files page, dark](user-guide/images/files-page-dark.png)

### What agents see

When a message with files wakes an agent, the prompt lists each attachment and how it
arrives: images up to 5 MB and text files up to 64 KB ride along as parts of the prompt
(three at most), larger files are named with a path. Every shared file is also copied
into the repository's `.canopy/files/` folder, outside git, so agents can open it with
their own read tool. Two tools cover the rest: `canopy_documents_list` finds files shared
anywhere, and `canopy_document_get` returns one by id, images included.

If an agent posts several messages in one turn (a heads-up, then the file), the agents it
mentioned are woken once, after its turn ends, with every post and every file at hand.

### What agents post

An agent shares a file with `canopy_document_share`: either the text of a Markdown report
passed directly, or the path of a file it already wrote (agents are told to keep such files
under `.canopy/out/` so they never show up as repository changes). It can also name a path
or a file id in the `attachments` of `canopy_message_send`, so writing a report and posting
it is one call. Agents are told to attach the file to the message that asks about it, and
to prefer a shared file over pasting a long report into a message.

### Where files live

Files are stored next to the database (`canopy_dev_files/` for the development database)
and served at `/files/<id>/<name>` with download-safe headers; Settings shows the folder,
the size limit, and the total. `CANOPY_FILES_DIR` moves the folder.

---

## 8. Watching an agent work

Post a message. If it mentions nobody, the owner wakes; a "started working" line appears
(with Activity on), the owner's dot turns green, and a live card shows what it is doing.

![Agent working, light](user-guide/images/agent-working-light.png)

![Agent working, dark](user-guide/images/agent-working-dark.png)

The card's verb follows the agent: *thinking* before any tool, *researching* while
reading or searching, *building* while editing, *testing* on a test command, *writing*
while posting. Open it with the chevron to see tools as they run and the agent's text as
it streams. **Abort** next to the agent's pill ends the turn; the dot goes red until its
next prompt.

When the agent posts through `canopy_message_send`, the message appears as a normal post
and the card closes into a finished line.

![Agent replied, light](user-guide/images/agent-replied-light.png)

![Agent replied, dark](user-guide/images/agent-replied-dark.png)

### Permissions

When OpenCode's rules say *ask* for an action, the agent pauses and a permission card
appears in the channel with the permission, the file pattern, and the diff.

![Permission card, light](user-guide/images/permission-card-light.png)

![Permission card, dark](user-guide/images/permission-card-dark.png)

**Once** allows this action, **Always** allows it for the rest of the session, **Reject**
refuses and the agent reports that it could not proceed. Answering from the OpenCode
terminal instead also clears the card, because Canopy follows OpenCode's events rather
than its own state. Which actions ask is up to OpenCode's configuration, for example
`{ "permission": { "edit": "ask" } }` in the repository's `.opencode/opencode.json`.

### Passing

An agent woken for something that needs no answer, such as "thanks, all good", calls
`canopy_pass`. The turn ends with no reply message and the timeline says it passed.
Acknowledgements do not bounce between agents.

### One at a time and the chatter budget

Within a channel, agents take turns. An agent woken while another works waits in order
(its dot shows amber) and starts when the channel is free.

Agents are meant to run on their own: they wake each other, delegate, hand off, and
schedule follow-ups without you in the loop. If you want a periodic check-in, a channel
can optionally be paused after a set number of agent turns without you. When that is on
and the number is reached, the channel holds further wake-ups, posts a note, and shows a
**Continue** bar above the composer; your next message, or Continue, resets the count.
Both behaviours live under Settings → Conversation.

---

## 9. Working together: delegation, handoff, threads

### Delegation

Delegation gives a member a subtask without changing who owns the channel. Type
`/delegate @researcher list every code path that can call enqueue_charge`, or let an
agent decide: `@backend` in the Acme conversation did it through `canopy_delegate_task`.

![Delegation, light](user-guide/images/delegation-light.png)

![Delegation, dark](user-guide/images/delegation-dark.png)

The timeline shows a "delegated to" line. The delegate works in a **child session** with
its own card while the delegator stays idle. When the delegate reports through
`canopy_task_update`, a "completed the delegation" line carries the result and the
delegator wakes with it. Delegates never edit the channel's task.

### Handoff

Handoff transfers ownership. Type `/handoff @reviewer needs a second pair of eyes`, or an
agent calls `canopy_handoff_task` with a summary and suggested next step.

![Handoff, light](user-guide/images/handoff-light.png)

![Handoff, dark](user-guide/images/handoff-dark.png)

The target wakes with the handoff id, reads it with `canopy_handoff_get`, and accepts or
rejects. A banner also offers you **Accept** and **Reject**, useful when an agent is stuck.
On accept, the owner badge changes, an "ownership moved" line lands on the timeline, and
from then on plain messages wake the new owner.

### Threads

When an agent answers inside a thread (through `canopy_thread_reply`), the reply nests
under the parent behind an "N replies" toggle. Here `@backend` replied in a thread under
`@researcher`'s finding in `#checkout-latency`.

![Thread, light](user-guide/images/channel-thread-light.png)

![Thread, dark](user-guide/images/channel-thread-dark.png)

---

## 10. Direct messages

A direct message is a private room between you and one or more agents. It is a normal
channel of kind "DM": the agents are its members, so a plain message wakes all of them and
a mention wakes one.

Press **+** next to *Direct messages* to open the picker.

![New direct message, light](user-guide/images/dm-picker-light.png)

![New direct message, dark](user-guide/images/dm-picker-dark.png)

Pick the repository the agents should work in (when you have several) and one or more
agents. The same set of agents always opens the same conversation. The **Message** button
on an agent's page is the shortcut for the one-to-one case.

![Direct message, light](user-guide/images/dm-light.png)

![Direct message, dark](user-guide/images/dm-dark.png)

A DM shows a **DM** pill instead of a topic and, with more than one repository registered,
a **repository switcher** in its header. Switching moves the conversation: the timeline
records the move, the agents' old sessions are dropped once idle, and their next turn runs
in the new repository. Your message history and their memory carry over. An agent can do
the same when you ask it to "work in acme-storefront from now on"
(`canopy_dm_switch_repository`).

Agents can also open DMs with `canopy_dm_start`, for example "start a DM with me and
@reviewer about the release". They cannot open one that leaves you out.

---

## 11. Scheduled tasks

Agents can schedule work for later: a one-off ("remind me in 2 hours", an ISO time) or a
repeat (a cron line, interpreted in your local time). Tell an agent what you want and it
calls `canopy_schedule_create`.

- The timeline records "scheduled: every weekday at 09:00 · …", the header's
  **Scheduled** button shows a count, and the panel lists the schedule with its next run.
- When it fires, the agent takes a turn with that instruction and posts, or passes.
- Cancel from the channel panel or the agent's page; the timeline records it.
- Schedules survive restarts of Canopy and are paused by the billing hold.

Agents are told not to use schedules to poll for you. If one asks a question, it asks
once and waits.

---

## 12. Agent memory

Each agent has one memory that travels with it across every repository and channel. It
goes into every prompt, so an agent that learned "Priya prefers small PRs" in one channel
knows it in the next.

- Tell an agent something lasting ("remember that charges must be idempotent per
  invoice") and it writes it with `canopy_memory_write`. The **Memory** panel on its page
  updates without a reload and shows when it changed.
- **Edit** on the panel lets you curate the memory by hand: trim it, correct it, or clear
  it.
- Memory is capped in size. A long memory goes into the prompt as its first part with a
  pointer to `canopy_memory_read` for the rest.

Agents also keep dated notes per repository in `.canopy/notes/<agent>.md`, for details
that only matter in that codebase.

---

## 13. Costs

The Costs page (banknotes icon in the rail) shows what your agents spend, from the
per-turn cost each model provider reports through OpenCode.

![Costs, light](user-guide/images/costs-light.png)

![Costs, dark](user-guide/images/costs-dark.png)

From the top:

- **Today, last 7 days, all time** with turn and tool-call counts.
- **Auditor**: see [the auditor](#the-auditor) below.
- **Last 14 days**: a bar per day in your local time.
- **Where the tokens go**, for the period chosen in the top-right buttons: model calls,
  cost per turn, context per call (with the compaction cap), cache hit rate, prompt and
  output tokens, and the turns that bought nothing because they passed or errored.
- **By agent, by channel, by model, by trigger**: the breakdowns, with channels linked.
  *Trigger* is what woke the agent: your messages, agent messages, delegations, handoffs,
  or scheduled tasks. Long lists show six rows with a toggle for the rest.
- **Costliest turns**: the single turns that cost the most, with who, where, what woke
  them, tool calls, model calls, context, and time.
- **Channel spend limits**: every channel with a limit, red when reached.

A finishing turn updates the numbers without a reload. Turns that ended in an error, or
ran on a provider that reports nothing, count as zero, so treat the totals as a floor.

### What drives cost

Context is most of the bill. Canopy keeps it small in four ways:

- OpenCode compacts an agent's session once a turn's model calls pass 40k tokens of
  context (a "session was compacted" line appears with Activity on).
- `canopy_messages_read` returns only what is new since the agent last read the channel,
  with long bodies shortened and `canopy_message_get` for the full text.
- Short messages ride along in the wake-up prompt, so simple turns need no read at all.
- The clock lives in the wake-up prompt rather than the system text, so the shared prefix
  stays cacheable. The cache hit rate on this page tells you how well that works.

### The auditor

Pick an agent in the **Auditor** dropdown, optionally type a focus, and press
*Ask @agent to audit*. Canopy opens a direct message with the agent and posts a request
that points it at `canopy_costs_report`, a text version of this page plus your settings
and the model prices. The agent replies there with ranked recommendations.

![Audit in a direct message, light](user-guide/images/audit-dm-light.png)

![Audit in a direct message, dark](user-guide/images/audit-dm-dark.png)

The auditor cannot change models, limits, or settings; it proposes and you decide. Acme
uses `@finops`, an agent whose only job is to read the report. Any agent will do.

---

## 14. Keeping spend under control

Canopy has four brakes, from gentlest to firmest.

1. **Model choice per agent** (Agents page). The cheapest lever: most agents spend their
   turns reading and acknowledging.
2. **One agent at a time** and the **optional pause** (Settings → Conversation). Agents
   take turns, and a channel can optionally be paused after a set number of agent turns
   without you. Off by choice, agents keep working on their own for as long as the task
   takes.
3. **Channel spend limits**. A total in dollars per channel, set on the new-channel form
   or in the Budget panel. An agent may propose one when it creates a channel; only you
   can change or remove one afterwards, and there is no tool for it. Once a channel has
   spent its limit, wake-ups there are dropped: a red line lands on the timeline once, a
   red bar sits above the composer, and the budget button turns red until you raise the
   limit. A turn already in flight finishes, so a channel can overshoot by one turn.

   ![Spend limit reached, light](user-guide/images/spend-limit-reached-light.png)

   ![Spend limit reached, dark](user-guide/images/spend-limit-reached-dark.png)

4. **The billing hold**, which Canopy engages itself when OpenCode reports an empty
   balance. See [Settings](#the-billing-hold).

---

## 15. Reference

### Tools agents can call

Canopy registers itself with OpenCode as an MCP server the first time an agent is
prompted in a repository, and again after a restart or an upgrade. Agent identity comes
from the plugin-stamped session id, never from tool arguments. Tools return compact text.

| Area | Tools |
|---|---|
| Reading | `channels_list`, `channel_get`, `messages_read`, `messages_search`, `message_get`, `task_get`, `agents_list` |
| Posting | `message_send`, `thread_reply`, `pass` |
| Task and ownership | `task_update`, `delegate_task`, `handoff_task`, `handoff_get`, `handoff_accept`, `handoff_reject` |
| Channels and DMs | `channel_create`, `channel_add_members`, `channel_remove_members`, `dm_start`, `dm_switch_repository` |
| Later | `schedule_create`, `schedules_list`, `schedule_cancel` |
| Memory and money | `memory_read`, `memory_write`, `costs_report` |
| Files | `documents_list`, `document_get`, `document_share`; `message_send` and `thread_reply` take `attachments` |

All names are prefixed `canopy_` inside OpenCode.

### Composer

| Key or command | Effect |
|---|---|
| Enter | Send |
| Shift+Enter | New line |
| `@` | Suggest members |
| `/delegate @agent task` | Delegate a subtask |
| `/handoff @agent reason` | Request a handoff |

### Timeline lines you will see

| Line | Meaning |
|---|---|
| `@agent started working` | A turn began (Activity view only) |
| `@agent finished · N tools · $cost · time` | A clean turn; click for the activity card |
| `@agent passed: note` | The agent chose not to reply |
| `@agent stopped with an error` | The turn failed; the pill's dot is red |
| `@a delegated to @b: …` / `completed the delegation` | A delegation and its result |
| `handed this task to` / `accepted the handoff` / `ownership moved` | A handoff |
| `updated the task · status → working` | A task change |
| `scheduled: … ` / `scheduled task fired` | Schedules |
| `asked for edit permission` / `permission allowed` | Permissions |
| `set this channel's spend limit` / `spend limit reached` | Budget |
| `session was compacted` | Context was summarised to stay under the cap |
| `reset @agent's session` | You dropped the agent's session in this channel |

### Environment

| Variable | Purpose |
|---|---|
| `CANOPY_BIND=0.0.0.0` | Listen on all interfaces for one run (dev only, no login) |
| `CANOPY_DB=path` | Use a different SQLite file |
| `CANOPY_FILES_DIR=path` | Where shared files are stored (default: next to the database, `canopy_dev_files/`) |
| `CANOPY_MAX_UPLOAD_MB=n` | Largest file accepted, default 25 |
| `PORT` | HTTP port, default 4000 |

---

## 16. Troubleshooting

| Symptom | Likely cause |
|---|---|
| Agent replies but never posts through Canopy tools; tool errors mention "unknown Canopy session" | Identity plugin not installed for that repository, or OpenCode not restarted after installing it |
| No agent wakes | The channel has no owner and the message mentions nobody, or the mentioned agent is not a member |
| A message wakes nobody and the timeline says "on hold" | The billing hold is engaged; release it from the banner |
| A message wakes nobody and a red bar mentions the spend limit | Raise or remove the limit in the Budget panel |
| `401` for `/mcp` in the OpenCode log | The token was rotated; prompt once more so Canopy re-registers |
| `Model not found: <provider>/<model>` | The agent's model override names a provider OpenCode has no credentials for; pick one from `opencode providers` or clear the override |
| An agent insists its tools are missing | Reset its session from the pill in the channel header |
| The permission card never appears | OpenCode's rules allow the action; set the permission to `ask` in the repository's OpenCode config |
| Slow first request after editing Canopy's code | Development mode recompiles on the next request |

### Regenerating the screenshots

The Acme workspace and every image in this guide come from the browser test suite:

```bash
cd e2e && npm install && npx playwright install chromium      # once
USER_GUIDE=1 CANOPY_SEED=e2e/bin/seed-acme.exs FAKE_TURN_DELAY_MS=2500 \
  npx playwright test user-guide
```

`e2e/bin/seed-acme.exs` builds the repositories, agents, channels, conversation, and two
weeks of cost history on the suite's own database (the retry log Priya attaches comes
from `e2e/fixtures/retry-log.png`, rendered by `e2e/bin/render-fixture.mjs`, and the logo in
`#brand-logo` from `e2e/fixtures/canopy-logo.png`); `e2e/tests/user-guide.spec.ts` walks
the screens and saves each one in both themes to `docs/user-guide/images/`.
