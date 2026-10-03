// A deterministic stand-in for `opencode serve`, just enough of the HTTP + SSE
// contract for Canopy's adapter (verified against OpenCode 1.18 in Phase 0).
// It also acts as an MCP client: when a prompt looks like a delegation or a
// handoff wake-up, it calls Canopy's real MCP tools, the way the plugin-stamped
// agent would, so browser tests exercise the whole loop.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";

const PORT = Number(process.env.FAKE_OPENCODE_PORT || 4396);
// Pause between the steps of a turn; raise it (FAKE_TURN_DELAY_MS=2500) to
// keep an agent visibly "working" long enough for a screenshot.
const TURN_DELAY = Number(process.env.FAKE_TURN_DELAY_MS || 50);
const streams = new Set(); // SSE clients on GET /event
const sessions = new Map(); // id -> {parentID, title}
const pendingPermissions = new Map(); // per_id -> resume fn
const aborted = new Set(); // session ids aborted mid-turn (long turns stop early)
let dialogue = 0; // lines spoken in the load-test back-and-forth (site screenshots)
const pendingQuestions = new Map(); // que_id -> {request, resume}
let mcp = null; // {url, headers} of the latest POST /mcp; the tool calls below use it
// Per repository directory: whether Canopy registered there (OpenCode's
// registrations are per instance) and the status of each configured server.
const registered = new Set();
const serverStatus = new Map(); // directory -> Map(name -> {status, error?})
// The repository's own MCP servers, as `GET /config` returns them: from
// FAKE_OPENCODE_MCP (JSON), else one local server carrying a fake secret and a
// remote one that fails until reconnected.
const CONFIGURED_MCP = process.env.FAKE_OPENCODE_MCP
  ? JSON.parse(process.env.FAKE_OPENCODE_MCP)
  : {
      "fake-local": { type: "local", command: ["fake-mcp", "--verbose"], environment: { FAKE_SECRET: "fake-secret-value-123" } },
      "fake-remote": { type: "remote", url: "http://user:pw@127.0.0.1:9/mcp" },
    };
function statusFor(directory) {
  if (!serverStatus.has(directory)) {
    const m = new Map();
    for (const [name, cfg] of Object.entries(CONFIGURED_MCP)) {
      if (cfg.enabled === false) m.set(name, { status: "disabled" });
      else if (cfg.type === "remote") m.set(name, { status: "failed", error: `connect ECONNREFUSED ${cfg.url}` });
      else m.set(name, { status: "connected" });
    }
    serverStatus.set(directory, m);
  }
  return serverStatus.get(directory);
}
let counter = 0;
const nextId = (p) => `${p}_fake${String(++counter).padStart(4, "0")}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function emit(type, properties) {
  const line = `data: ${JSON.stringify({ id: nextId("evt"), type, properties })}\n\n`;
  for (const res of streams) res.write(line);
}

function json(res, status, body) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(body === undefined ? "" : JSON.stringify(body));
}

async function readBody(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const text = Buffer.concat(chunks).toString("utf8");
  return text ? JSON.parse(text) : {};
}

// ---- minimal MCP client (Streamable HTTP) ------------------------------------
let mcpSession = null;
async function mcpRpc(method, params, id) {
  const headers = {
    ...mcp.headers,
    "content-type": "application/json",
    accept: "application/json, text/event-stream",
  };
  if (mcpSession) headers["mcp-session-id"] = mcpSession;
  const body = { jsonrpc: "2.0", method, params };
  if (id !== undefined) body.id = id;
  const res = await fetch(mcp.url, { method: "POST", headers, body: JSON.stringify(body) });
  const sid = res.headers.get("mcp-session-id");
  if (sid) mcpSession = sid;
  const text = await res.text();
  const data = text.split("\n").filter((l) => l.startsWith("data:")).map((l) => JSON.parse(l.slice(5)));
  return data.find((d) => d.id === id);
}
async function mcpCall(name, args) {
  if (!mcp) throw new Error("Canopy never registered its MCP server");
  if (!mcpSession) {
    await mcpRpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "fake-opencode", version: "0" } }, 1);
    await mcpRpc("notifications/initialized", {});
  }
  const reply = await mcpRpc("tools/call", { name, arguments: args }, ++counter + 100);
  const content = reply?.result?.content?.[0]?.text ?? "";
  console.log(`[fake-opencode] mcp ${name} -> ${content.slice(0, 80)}`);
  return content;
}

// ---- story content for the site screenshots (e2e/tests/site-*.spec.ts) ----------
const ENQUEUE_PATHS_MD = `# Callers of \`enqueue_charge\`

Every code path that can enqueue a charge for an invoice, with the guard it relies on.

| # | Call site | Trigger | Guard before the call |
|---|---|---|---|
| 1 | \`acme/billing/retry_worker.py:7\` | cron, every minute | none (re-enqueues every failed job) |
| 2 | \`acme/billing/webhooks.py:5\` | \`payment_failed\` webhook | none (fires for the retry's own failure too) |
| 3 | \`acme/admin/replay.py:17\` | support's manual replay tool | operator confirmation only |

## Notes

- 1 and 2 overlap whenever the gateway is slow: the worker pops the job while the
  failure webhook for the same attempt is still in flight.
- 3 is rare but has the same race with 1; a replay during the worker's minute can
  double-charge in the same way.
- \`invoices.mark_paid\` runs after \`gateway.charge\` returns, so every caller sees
  \`status == "open"\` until the first charge completes.

Recommendation: one idempotency key per invoice attempt, checked before the gateway
call, and a \`charging\` status set before the call rather than after.
`;

// The load-test back-and-forth between @researcher and @test; each line
// mentions whoever spoke last, so the channel reaches its chatter limit.
const DIALOGUE = [
  "I'd start the load test at 50 concurrent checkouts for five minutes against staging. Can you run it and send me the p95?",
  "50 is under Tuesday's peak of 80. I'd ramp the load test to 100 over two minutes and hold for five. Fine with you?",
  "Agreed on 100. Let's also run the load test once with the `priceCart` cache on and once with it off, so we see the difference.",
  "Two load test runs, then. I'll use the seeded carts from `fixtures/carts.json`; the big ones are where `priceCart` hurts.",
  "Good. For the load test, report p50, p95 and the pricing service's own latency, per run.",
  "Will do. I'll post the load test numbers as a table once both runs finish.",
  "Thanks. I'll draft the cache change while the load test runs.",
];

// ---- the #payment-retries story (e2e/tests/site-shots.spec.ts, site-video.spec.ts) ----
// @backend reads the code and delegates the caller list to @researcher, proposes
// a fix, asks one question, edits behind a permission card, tests, and hands
// off to @reviewer, who reviews the real diff. Files change in the channel's
// repository (the `directory` Canopy sends with each prompt), so the Changes
// modal shows them. Recording mode ("…fix it…" in the first message) skips the
// proposal, the question and the permission card, and goes straight to building.
const PAYMENTS_OLD = `    gateway.charge(invoice.customer_id, invoice.amount_cents)
    invoices.mark_paid(invoice_id)`;
const PAYMENTS_NEW = `    if not invoices.claim_charge(invoice_id):
        log.info("charge for %s already in flight", invoice_id)
        return
    try:
        gateway.charge(invoice.customer_id, invoice.amount_cents)
        invoices.mark_paid(invoice_id)
    finally:
        invoices.release_claim(invoice_id)`;
const TEST_OLD = `    assert paid_invoice.charges == 1`;
const TEST_NEW = `    assert paid_invoice.charges == 1


def test_concurrent_retries_charge_once(open_invoice, slow_gateway):
    with slow_gateway.hold():
        payments.enqueue_charge(open_invoice.id)
        payments.enqueue_charge(open_invoice.id)
    assert open_invoice.charges == 1`;

const ROOT_CAUSE = `**Root cause.** Two independent retry paths can both call \`enqueue_charge\` for the same invoice, and the only guard is \`invoice.status == "paid"\`, which is set *after* the gateway call returns:

1. \`retry_worker.py:7\` pops failed jobs every minute and re-enqueues them.
2. \`webhooks.py:5\` re-enqueues on every \`payment_failed\` event, including the retried attempt's own failure event.

When the gateway is slow, both run inside the same window:

\`\`\`python
if invoice.status == "paid":   # both callers see "open"
    return
gateway.charge(...)            # charged twice
invoices.mark_paid(invoice_id)
\`\`\`

Before I propose a fix I want the full list of callers, so I've delegated that to the researcher.`;

const PLAN = `Three callers confirmed, including support's manual replay tool, so fixing the callers one by one is fragile. **Proposal:** make \`enqueue_charge\` itself idempotent.

- Add \`invoices.claim_charge(invoice_id)\`: an \`UPDATE … WHERE charge_claimed_at IS NULL\` that returns whether this caller won.
- Call it before \`gateway.charge\`; losers log and return.
- Release the claim in a \`finally\`, so a gateway timeout can't leave it stuck.

One migration, ~20 lines in \`payments.py\`, one new test. Shall I go ahead?`;

const doneMessage = (key) => `Done, in the working tree:

- \`enqueue_charge\` claims the invoice with \`invoices.claim_charge\` before calling the gateway, keyed on ${key}.
- The claim is released in a \`finally\`, so a gateway timeout can't leave it stuck.
- New test \`test_concurrent_retries_charge_once\`.

\`\`\`text
$ pytest tests/test_payments.py -q
15 passed in 2.1s
\`\`\`

Handing it to review for a second pair of eyes before we open the PR.`;

const APPROVAL = `Reviewed the diff. Approving with two small notes, neither blocking:

1. \`claim_charge\` should also skip invoices in \`void\` status, not just \`paid\`.
2. The new test holds a real gateway stub; a fake gateway with a latch would be faster and deterministic.

Ready for a PR once Priya is happy.`;

const QUEUE_CHECK =
  "**09:00 check:** the failed-charge queue is at 63, above the threshold of 50. 58 of them are `card_declined` for a single merchant, each on a different invoice, so these are genuine declines rather than duplicate retries; the claim fix is holding. Worth a word with support about that merchant.";

const story = new Map(); // sessionID -> {mode: "plan" | "build", phase}

/** The unified diff `edit` would make, as OpenCode puts it in a permission request. */
function unifiedDiff(file, before, after) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "fake-opencode-"));
  fs.writeFileSync(path.join(dir, "a"), before);
  fs.writeFileSync(path.join(dir, "b"), after);
  let diff = "";
  try {
    execFileSync("git", ["diff", "--no-index", "--no-color", "a", "b"], { cwd: dir, encoding: "utf8" });
  } catch (e) {
    diff = e.stdout; // exit status 1: the files differ
  }
  fs.rmSync(dir, { recursive: true, force: true });
  return diff.replace(/^diff --git .*\n(index .*\n)?/, "").replace(/^--- a$/m, `--- ${file}`).replace(/^\+\+\+ b$/m, `+++ ${file}`);
}

async function storyTurn(sessionID, text, cwd) {
  const messageID = nextId("msg");
  const part = (extra) => ({ id: nextId("prt"), sessionID, messageID, ...extra });
  const state = story.get(sessionID) || {};
  story.set(sessionID, state);
  const abs = (rel) => path.join(cwd, rel);

  // One tool part: pending -> running for `hold` × FAKE_TURN_DELAY_MS (so the live
  // card shows it) -> completed. `beforeRun` may block (a permission card) and
  // return false to fail the call.
  const tool = async (name, input, title, run, { hold = 1, beforeRun } = {}) => {
    const callID = nextId("call");
    const base = { id: nextId("prt"), sessionID, messageID, type: "tool", callID, tool: name };
    const start = Date.now();
    emit("message.part.updated", { sessionID, part: { ...base, state: { status: "pending", input: {} } } });
    emit("message.part.updated", { sessionID, part: { ...base, state: { status: "running", input, time: { start } } } });
    if (beforeRun && !(await beforeRun(callID))) {
      emit("message.part.updated", { sessionID, part: { ...base, state: { status: "error", input, error: "The user rejected permission to use this specific tool call.", time: { start, end: Date.now() } } } });
      return { denied: true };
    }
    const output = run ? await run() : "";
    await sleep(Math.max(0, TURN_DELAY * hold - (Date.now() - start)));
    emit("message.part.updated", { sessionID, part: { ...base, state: { status: "completed", input, title, output, metadata: {}, time: { start, end: Date.now() } } } });
    return { output };
  };
  const read = (rel, hold = 1) => tool("read", { filePath: abs(rel) }, rel, () => fs.readFileSync(abs(rel), "utf8"), { hold });
  const grep = (pattern, hold = 1) =>
    tool("grep", { pattern, path: cwd }, pattern, () => {
      try {
        return execFileSync("git", ["grep", "-n", pattern], { cwd, encoding: "utf8" });
      } catch {
        return "No files found"; // git grep exits 1 on no match
      }
    }, { hold });
  const bash = (command, output, hold = 1) => tool("bash", { command, description: command }, command, () => (typeof output === "function" ? output() : output), { hold });
  // Canopy's own tools, through the real MCP server, the way the plugin-stamped agent calls them.
  const canopy = (name, args = {}) =>
    tool(`canopy_${name}`, args, name, () => mcpCall(name, { canopy_session_id: sessionID, ...args }), { hold: 0.3 });
  const edit = (rel, oldString, newString, { ask = false, hold = 1 } = {}) => {
    const before = fs.readFileSync(abs(rel), "utf8");
    const after = before.replace(oldString, newString);
    const beforeRun = ask
      ? (callID) =>
          new Promise((resume) => {
            const id = nextId("per");
            pendingPermissions.set(id, (reply) => resume(reply !== "reject"));
            emit("permission.asked", { id, sessionID, permission: "edit", patterns: [rel], metadata: { filepath: abs(rel), diff: unifiedDiff(rel, before, after) }, always: ["*"], tool: { messageID, callID } });
          })
      : undefined;
    return tool("edit", { filePath: abs(rel), oldString, newString }, rel, () => (fs.writeFileSync(abs(rel), after), emit("file.edited", { file: abs(rel) }), ""), { hold, beforeRun });
  };
  const done = (reply, cost) => finishTurn(sessionID, messageID, part, reply, cost);

  aborted.delete(sessionID);
  emit("session.status", { sessionID, status: { type: "busy" } });
  await sleep(TURN_DELAY / 2);

  const from = text.match(/new Canopy message in #\S+ from (\S+)\./)?.[1];
  const body = text.match(/Message text:\n([\s\S]*?)\n(?:Attachments on this message:|canopy_messages_read returns)/)?.[1]?.trim() || "";
  let m;

  // @reviewer takes the handoff, reads the real diff and approves.
  if ((m = text.match(/Handoff ID: (ho_\S+)/))) {
    const packet = await canopy("handoff_get", { handoff_id: m[1] });
    await canopy("handoff_accept", { handoff_id: m[1] });
    if (!/claim_charge/.test(packet.output || "")) {
      await canopy("message_send", { text: "Took over the task; reading the handoff and the working tree now." });
      return done("Accepted the handoff.", 0.004);
    }
    await bash("git diff", () => execFileSync("git", ["diff"], { cwd, encoding: "utf8" }) || "(no changes)", 1.2);
    await read("tests/test_payments.py");
    await canopy("message_send", { text: APPROVAL });
    return done("Reviewed the diff; approved with two non-blocking notes.", 0.0834);
  }
  if (/accepted your handoff/.test(text)) {
    await canopy("pass", {});
    return done("Nothing to do: the handoff was accepted.", 0.0011);
  }
  if (/A scheduled task of yours is due/.test(text)) {
    await grep("failed_charges", 0.6);
    await canopy("message_send", { text: /failed-charge queue/i.test(text) ? QUEUE_CHECK : "Ran the scheduled check: all green." });
    return done("Posted the 09:00 queue check.", 0.0142);
  }

  const build = async (key) => {
    state.phase = "built";
    await read("acme/billing/payments.py");
    const edited = await edit("acme/billing/payments.py", PAYMENTS_OLD, PAYMENTS_NEW, { ask: state.mode === "plan" });
    if (edited.denied) {
      await canopy("message_send", { text: "Stopped before changing anything: the edit to `payments.py` was not approved. Tell me how you'd like to proceed." });
      return done("The edit was not approved; nothing changed.", 0.0093);
    }
    await edit("tests/test_payments.py", TEST_OLD, TEST_NEW, { hold: 0.6 });
    await bash("pytest tests/test_payments.py -q", "...............                                                          [100%]\n15 passed in 2.1s", 1.2);
    await canopy("message_send", { text: doneMessage(key) });
    await canopy("handoff_task", {
      to: "reviewer",
      summary: `Idempotent enqueue_charge via invoices.claim_charge, keyed on ${key}; 15 tests pass.`,
      reason: "needs a second pair of eyes before the PR",
      suggested_next_step: "Review the diff, then ask @test for a load test if the claim query looks hot.",
    });
    return done("Fix and test in the working tree; handed to @reviewer.", 0.0612);
  };

  // The researcher's report and the delegation's completion both wake the owner;
  // whichever arrives first continues the story, the other is a pass.
  const research = /Your delegated subtask .* was completed/.test(text) || from === "@researcher";
  if (research && state.phase === "delegated") {
    if (state.mode === "build") return build("the invoice only");
    state.phase = "planned";
    await canopy("message_send", { text: PLAN });
    await canopy("task_update", { status: "working" });
    return done("Proposed an idempotent enqueue_charge; waiting for a go-ahead.", 0.0127);
  }
  if (/Your delegated subtask/.test(text) || from?.startsWith("@")) {
    await canopy("pass", {});
    return done("Nothing to add.", 0.0009);
  }

  // Priya's first message: read the code, post the root cause, delegate the caller list.
  if (/charged twice/i.test(body)) {
    state.mode = /\bfix it\b/i.test(body) ? "build" : "plan";
    state.phase = "delegated";
    await read("acme/billing/payments.py");
    await read("acme/billing/retry_worker.py");
    await grep("enqueue_charge");
    // three tools done: the live card holds on "researching" for the ST-2 still
    await read("acme/billing/webhooks.py", 2.5);
    await canopy("message_send", { text: ROOT_CAUSE });
    await canopy("delegate_task", {
      to: "researcher",
      task: "List every code path in acme-billing that can call enqueue_charge, with file and line and the guard each one relies on.",
    });
    return done("Posted the root cause; the researcher is tracing every caller of enqueue_charge.", 0.0341);
  }

  // The go-ahead: ask about the claim key (the question card), then build.
  if (/\bgo ahead\b/i.test(body) && state.phase === "planned") {
    const id = nextId("que");
    const request = {
      id,
      sessionID,
      questions: [{
        question: "Should the claim key include the attempt number?",
        header: "Claim key",
        options: [
          { label: "Invoice only (Recommended)", description: "One claim per invoice: every retry path competes for it, so a charge lands at most once." },
          { label: "Invoice + attempt", description: "A fresh claim per attempt; the worker has to dedupe retries itself." },
        ],
      }],
      tool: { messageID, callID: nextId("call") },
    };
    let answer = [];
    await tool("question", { questions: request.questions }, "Asked 1 question", async () => {
      answer = await new Promise((resume) => {
        pendingQuestions.set(id, { request, resume });
        emit("question.asked", request);
      });
      return JSON.stringify(answer);
    }, { hold: 0.2 });
    return build(/attempt/i.test(answer.flat().join(" ")) ? "the invoice and the attempt number" : "the invoice only");
  }

  // "every weekday at 09:00, <instruction>" → a cron schedule.
  if ((m = body.match(/every (weekday|day) at (\d{1,2}):(\d{2}),?\s*(.*)$/is))) {
    const [, days, hh, mm, rest] = m;
    const cron = `${Number(mm)} ${Number(hh)} * * ${days.toLowerCase() === "weekday" ? "1-5" : "*"}`;
    const what = (rest.charAt(0).toUpperCase() + rest.slice(1)).trim().replace(/\.?$/, ".");
    await canopy("schedule_create", { when: cron, what });
    const clock = `${hh.padStart(2, "0")}:${mm}`;
    // not "09:00 check": site-shots waits for that text from the scheduled run itself
    await canopy("message_send", { text: `Scheduled: every ${days.toLowerCase()} at ${clock}. I'll ${rest.replace(/\.$/, "").replace(/post here if/, "post here only if")}.` });
    return done(`Scheduled the weekday queue check for ${clock}.`, 0.0088);
  }

  await read("README.md");
  await canopy("message_send", { text: "Acknowledged: looking into it now." });
  return done("Replied.", 0.004);
}

// ---- a scripted agent turn -----------------------------------------------------
async function runTurn(sessionID, text, cwd) {
  // The site story's owner and reviewer; @researcher's delegation below is part of it too.
  if (/ #payment-retries[.\s]/.test(text) && cwd && !/Delegation ID: dl_/.test(text)) return storyTurn(sessionID, text, cwd);

  const messageID = nextId("msg");
  const part = (extra) => ({ id: nextId("prt"), sessionID, messageID, ...extra });
  // one tool call, pending -> running (for TURN_DELAY, so the live card shows it) -> completed
  const tool = async (name, input, title, output = "") => {
    const callID = nextId("call");
    const toolID = nextId("prt");
    const base = { id: toolID, sessionID, messageID, type: "tool", callID, tool: name };
    const start = Date.now();
    emit("message.part.updated", { sessionID, part: { ...base, state: { status: "pending", input: {} } } });
    emit("message.part.updated", { sessionID, part: { ...base, state: { status: "running", input, time: { start } } } });
    await sleep(TURN_DELAY);
    emit("message.part.updated", { sessionID, part: { ...base, state: { status: "completed", input, title, output, metadata: {}, time: { start, end: Date.now() } } } });
  };
  aborted.delete(sessionID);
  emit("session.status", { sessionID, status: { type: "busy" } });
  await sleep(TURN_DELAY);

  // Site story: @researcher traces every caller of enqueue_charge and reports
  // back with a Markdown file.
  if (/Delegation ID: dl_/.test(text) && /enqueue_charge/.test(text)) {
    await tool("grep", { pattern: "enqueue_charge", path: "acme" }, "enqueue_charge");
    await tool("read", { filePath: "acme/admin/replay.py" }, "acme/admin/replay.py");
    const shared = await mcpCall("document_share", { canopy_session_id: sessionID, filename: "enqueue-paths.md", content: ENQUEUE_PATHS_MD, caption: "Full caller list with the guard each path relies on" });
    const id = (shared.match(/\[(doc_\w+)\]/) || [])[1];
    await mcpCall("message_send", { canopy_session_id: sessionID, text: "Full caller list attached; the short version is in the task result.", attachments: id });
    await mcpCall("task_update", { canopy_session_id: sessionID, status: "completed", result: "Three callers: retry_worker.py:7, webhooks.py:5, and admin/replay.py:17 (the manual replay tool support uses)." });
    return finishTurn(sessionID, messageID, part, "Reported three callers of enqueue_charge.", 0.0009);
  }

  // Playbooks (e2e/tests/playbooks.spec.ts): "run the <name> playbook" starts
  // it as the coordinator and advances through to the step held for the
  // user's sign-off; the user's Approve wakes it again to close.
  const playbookAsk = (text.match(/Message text:\n([\s\S]*?)\n\n/)?.[1] || "").match(/run the (\S+) playbook/i);
  if (playbookAsk && /new Canopy message/.test(text)) {
    const started = await mcpCall("playbook_start", { canopy_session_id: sessionID, name: playbookAsk[1], brief: "Make the e2e button green." });
    if (!/^started/.test(started)) {
      await mcpCall("message_send", { canopy_session_id: sessionID, text: `Could not start it: ${started}` });
      return finishTurn(sessionID, messageID, part, "Could not start the playbook.", 0.0004);
    }
    await tool("read", { filePath: "README.md" }, "README.md");
    await mcpCall("playbook_advance", { canopy_session_id: sessionID, result: "Planned: one file, README.md." });
    await mcpCall("playbook_advance", { canopy_session_id: sessionID, result: "Built: README.md updated." });
    await mcpCall("playbook_advance", { canopy_session_id: sessionID, result: "Summary posted for sign-off." });
    await mcpCall("message_send", { canopy_session_id: sessionID, text: "Ready for your sign-off: README.md updated." });
    return finishTurn(sessionID, messageID, part, "Waiting for sign-off.", 0.0008);
  }
  if (/^The user approved "/m.test(text)) {
    await mcpCall("message_send", { canopy_session_id: sessionID, text: "Signed off; closing the run." });
    return finishTurn(sessionID, messageID, part, "Closed.", 0.0003);
  }

  // Locks (e2e/tests/locks.spec.ts): "take the tests lock [and keep it]" asks
  // Canopy for the lock; queued, the agent passes and ends its turn, the way
  // the system prompt tells it to. The grant wake runs the work and ends, which
  // releases the lock.
  const granted = text.match(/You now hold the `([^`]+)` lock/);
  if (granted) {
    await tool("bash", { command: "mix test" }, "mix test", "42 tests, 0 failures");
    await mcpCall("message_send", { canopy_session_id: sessionID, text: `Ran the suite with the \`${granted[1]}\` lock: 42 tests, 0 failures.` });
    return finishTurn(sessionID, messageID, part, "Ran the suite.", 0.0006);
  }
  const lockAsk = (text.match(/Message text:\n([\s\S]*?)\n\n/)?.[1] || "").match(/take the (\S+) lock( and keep it)?/i);
  if (lockAsk && /new Canopy message/.test(text)) {
    const keep = Boolean(lockAsk[2]);
    const result = await mcpCall("lock_acquire", { canopy_session_id: sessionID, name: lockAsk[1], reason: keep ? "e2e run" : "precommit", hold_across_turns: keep });
    if (/End your turn now/.test(result) || keep) {
      await mcpCall("pass", { canopy_session_id: sessionID, reason: keep ? "holding the lock" : "queued for the lock" });
      return finishTurn(sessionID, messageID, part, keep ? "Holding the lock." : "Waiting for the lock.", 0.0004);
    }
    await tool("bash", { command: "mix precommit" }, "mix precommit", "ok");
    await mcpCall("message_send", { canopy_session_id: sessionID, text: "Ran precommit with the lock." });
    return finishTurn(sessionID, messageID, part, "Ran precommit.", 0.0005);
  }

  const inline = text;
  // Site "Stop all" shot: a long turn that keeps calling tools until aborted.
  if (/under load|checkout suite/i.test(inline) && /new Canopy message/i.test(text)) {
    const steps = [
      ["bash", { command: "k6 run load/checkout.js --vus 100" }, "k6 run load/checkout.js"],
      ["read", { filePath: "src/checkout/session.ts" }, "src/checkout/session.ts"],
      ["grep", { pattern: "priceCart" }, "priceCart"],
      ["bash", { command: "npm test -- checkout" }, "npm test -- checkout"],
    ];
    for (let i = 0; i < 60 && !aborted.has(sessionID); i++) {
      const [name, input, title] = steps[i % steps.length];
      await tool(name, input, title);
    }
    aborted.delete(sessionID);
    return;
  }

  // Site chatter shot: two agents talk a load-test plan through between them.
  const from = (text.match(/new Canopy message in #\S+ from (@\w+)/) || [])[1];
  if (/load[- ]test/i.test(inline) && /new Canopy message/i.test(text)) {
    const other = from || "@test";
    const line = DIALOGUE[dialogue++ % DIALOGUE.length];
    await tool("read", { filePath: "load/checkout.js" }, "load/checkout.js");
    await mcpCall("message_send", { canopy_session_id: sessionID, text: `${other} ${line}` });
    return finishTurn(sessionID, messageID, part, "Replied about the load test.", 0.0004);
  }

  // A wake for a message in a thread names the thread's root; the agent then
  // answers there with canopy_thread_reply, the way the wake prompt tells it to
  // (e2e/tests/threads.spec.ts). "tell the channel" in the message also sends
  // the reply to the channel; "take your time" keeps the turn running for a
  // couple of seconds, so the live card can be seen.
  const threadRoot = text.match(/^Thread: (msg_\S+)/m)?.[1];
  const slow = /take your time/i.test(text);
  const post = (args) =>
    threadRoot
      ? mcpCall("thread_reply", { canopy_session_id: sessionID, message_id: threadRoot, also_send_to_channel: /tell the channel/i.test(text), ...args })
      : mcpCall("message_send", { canopy_session_id: sessionID, ...args });

  // one read tool, pending -> running -> completed
  const callID = nextId("call");
  const toolID = nextId("prt");
  emit("message.part.updated", { sessionID, part: { id: toolID, sessionID, messageID, type: "tool", callID, tool: "read", state: { status: "pending", input: {} } } });
  emit("message.part.updated", { sessionID, part: { id: toolID, sessionID, messageID, type: "tool", callID, tool: "read", state: { status: "running", input: { filePath: "README.md" }, time: { start: Date.now() } } } });
  await sleep(slow ? 2500 : TURN_DELAY);
  emit("message.part.updated", { sessionID, part: { id: toolID, sessionID, messageID, type: "tool", callID, tool: "read", state: { status: "completed", input: { filePath: "README.md" }, title: "README.md", output: "# e2e repo", metadata: {}, time: { start: Date.now() - 50, end: Date.now() } } } });

  // Like a real agent, read the message the wake prompt points at; the prompt
  // itself carries only ids, never bodies.
  let body = "";
  const mention = text.match(/Message ID: (msg_\S+)/);
  if (mention && mcp) {
    body = await mcpCall("messages_read", { canopy_session_id: sessionID, around: mention[1], limit: 5 });
  }

  if (/permission/i.test(body)) {
    const id = nextId("per");
    await new Promise((resume) => {
      pendingPermissions.set(id, resume);
      emit("permission.asked", { id, sessionID, permission: "edit", patterns: ["notes.txt"], metadata: { filepath: "notes.txt", diff: "--- notes.txt\n+++ notes.txt\n@@ -1 +1,2 @@\n hello\n+perm: test" }, always: ["*"], tool: { messageID, callID: nextId("call") } });
    });
    emit("file.edited", { file: "notes.txt" });
  }

  // "ask me" puts the question tool on hold until the card is answered or
  // dismissed; the answer comes back as a list of labels per question.
  let answer = null;
  if (/\bask me\b/i.test(body)) {
    const id = nextId("que");
    const request = {
      id,
      sessionID,
      questions: [{
        question: "Should the retry key include the attempt number?",
        header: "Retry key",
        options: [
          { label: "Invoice only", description: "Every retry reuses one key, so a charge lands at most once." },
          { label: "Invoice + attempt", description: "Each retry gets a fresh key; the worker has to dedupe." },
        ],
      }],
      tool: { messageID, callID: nextId("call") },
    };
    answer = await new Promise((resume) => {
      pendingQuestions.set(id, { request, resume });
      emit("question.asked", request);
    });
  }

  let reply = "Reply from the fake agent.";
  const delegation = text.match(/Delegation ID: (dl_\S+)/);
  const handoff = text.match(/Handoff ID: (ho_\S+)/);
  const channel = text.match(/Canopy message in #(\S+)/) || text.match(/in #(\S+)\./);

  if (delegation) {
    await mcpCall("task_update", { canopy_session_id: sessionID, status: "completed", result: "Found two enqueue paths." });
    reply = "Delegated work finished.";
  } else if (handoff) {
    await mcpCall("handoff_get", { canopy_session_id: sessionID, handoff_id: handoff[1] });
    await mcpCall("handoff_accept", { canopy_session_id: sessionID, handoff_id: handoff[1] });
    reply = "Accepted the handoff.";
  } else if (/delegated subtask .* was completed/i.test(text)) {
    await mcpCall("message_send", { canopy_session_id: sessionID, text: "Delegation result received; wrapping up." });
    reply = "Continuing after the delegation.";
  } else if (/scheduled task of yours is due/i.test(text)) {
    await mcpCall("message_send", { canopy_session_id: sessionID, text: "Ran the scheduled check: all green." });
    reply = "Scheduled task done.";
  } else if (/new Canopy message/i.test(text)) {
    const msg = text.match(/Message ID: (msg_\S+)/);
    const body = msg ? await mcpCall("messages_read", { canopy_session_id: sessionID, around: msg[1], limit: 1 }) : "";
    if (/publish a report/i.test(body)) {
      const shared = await mcpCall("document_share", { canopy_session_id: sessionID, filename: "retry-report.md", content: "# Retry report\n\nTwo callers race on `enqueue_charge`.\n", caption: "the report" });
      const id = (shared.match(/\[(doc_\w+)\]/) || [])[1];
      await mcpCall("message_send", { canopy_session_id: sessionID, text: "Report attached.", attachments: id });
      reply = "Published the report.";
    } else if (/schedule/i.test(body)) {
      const created = await mcpCall("schedule_create", { canopy_session_id: sessionID, when: "3s", what: "Run the scheduled check and report." });
      await mcpCall("message_send", { canopy_session_id: sessionID, text: "Scheduled it: " + created.split(".")[0] + "." });
      reply = "Scheduled.";
    } else if (answer) {
      const choice = answer.flat().join(", ");
      await post({ text: choice ? `Going with **${choice}**.` : "Skipped the question; keeping the current key." });
      reply = "Answered.";
    } else if (threadRoot) {
      await post({ text: "Answering in the thread: per-request caching is the safe option." });
    } else {
      await post({ text: "Acknowledged: looking into it now.\n\n1. Read `README.md`\n2. Check the queue\n\n```python\nqueue.add(invoice_id)\n```" });
    }
  }

  void channel;
  finishTurn(sessionID, messageID, part, reply, 0.0012);
}

// The final text, the cost, and back to idle.
function finishTurn(sessionID, messageID, part, reply, cost) {
  const textID = nextId("prt");
  emit("message.part.updated", { sessionID, part: part({ id: textID, type: "text", text: "", time: { start: Date.now() } }) });
  emit("message.part.delta", { sessionID, messageID, partID: textID, field: "text", delta: reply });
  emit("message.part.updated", { sessionID, part: part({ id: textID, type: "text", text: reply, time: { start: Date.now() - 10, end: Date.now() } }) });
  emit("message.updated", { info: { id: messageID, sessionID, role: "assistant", cost, tokens: { input: 100, output: 20 }, finish: "stop", time: { created: Date.now(), completed: Date.now() } } });
  emit("session.status", { sessionID, status: { type: "idle" } });
  emit("session.idle", { sessionID });
}

// ---- HTTP surface ---------------------------------------------------------------
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const p = url.pathname;
  try {
    if (req.method === "GET" && (p === "/global/health" || p === "/api/health")) return json(res, 200, { healthy: true, version: "fake-1.0" });
    if (req.method === "GET" && p === "/config/providers")
      return json(res, 200, { providers: [{ id: "opencode", name: "OpenCode Zen", models: { "gpt-5-nano": { cost: { input: 0.05, output: 0.4, cache: { read: 0.005, write: 0 } } }, "claude-haiku-4-5": { cost: { input: 1, output: 5, cache: { read: 0.1, write: 1.25 } } }, "claude-sonnet-5": { cost: { input: 3, output: 15, cache: { read: 0.3, write: 3.75 } } }, "claude-opus-5-5": { cost: { input: 5, output: 25, cache: { read: 0.5, write: 6.25 } } } } }], default: { opencode: "gpt-5-nano" } });
    if (req.method === "GET" && p === "/agent") return json(res, 200, [{ name: "build", mode: "primary" }, { name: "plan", mode: "primary" }]);
    // Test-only: every session Canopy created, for specs that check how many it made.
    if (req.method === "GET" && p === "/__fake/sessions") return json(res, 200, [...sessions].map(([id, s]) => ({ id, ...s })));
    const directory = url.searchParams.get("directory") || "";
    if (req.method === "GET" && p === "/mcp") {
      const out = Object.fromEntries(statusFor(directory));
      if (mcp && registered.has(directory)) out.canopy = { status: "connected" };
      return json(res, 200, out);
    }
    if (req.method === "GET" && p === "/config") return json(res, 200, { mcp: CONFIGURED_MCP });
    if (req.method === "POST" && p === "/instance/dispose") {
      registered.delete(directory);
      if (registered.size === 0) mcp = null;
      mcpSession = null;
      return json(res, 200, true);
    }
    if (req.method === "POST" && p === "/mcp") {
      const body = await readBody(req);
      mcp = { url: body.config.url, headers: body.config.headers || {} };
      mcpSession = null;
      registered.add(directory);
      console.log(`[fake-opencode] MCP registered for ${directory} -> ${mcp.url}`);
      return json(res, 200, { [body.name]: { status: "connected" } });
    }
    if (req.method === "GET" && p === "/event") {
      res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache", connection: "keep-alive" });
      res.write(`data: ${JSON.stringify({ id: nextId("evt"), type: "server.connected", properties: {} })}\n\n`);
      streams.add(res);
      const hb = setInterval(() => res.write(`data: ${JSON.stringify({ type: "server.heartbeat", properties: {} })}\n\n`), 10_000);
      req.on("close", () => { clearInterval(hb); streams.delete(res); });
      return;
    }
    if (req.method === "POST" && p === "/session") {
      const body = await readBody(req);
      const id = nextId("ses");
      sessions.set(id, { parentID: body.parentID || null, title: body.title });
      emit("session.created", { info: { id, projectID: "fake", parentID: body.parentID, title: body.title } });
      return json(res, 200, { id, parentID: body.parentID, title: body.title });
    }
    if (req.method === "GET" && p === "/session/status") return json(res, 200, {});
    if (req.method === "GET" && p === "/permission") return json(res, 200, []);
    if (req.method === "GET" && p === "/question") return json(res, 200, [...pendingQuestions.values()].map((q) => q.request));
    if (req.method === "GET" && p === "/vcs/status") return json(res, 200, []);
    let m;
    if (req.method === "POST" && (m = p.match(/^\/mcp\/([^/]+)\/connect$/))) {
      const name = decodeURIComponent(m[1]);
      const statuses = statusFor(directory);
      if (name === "canopy" && registered.has(directory)) return json(res, 200, true);
      if (!statuses.has(name)) return json(res, 404, { name: "McpServerNotFoundError", data: { name } });
      statuses.set(name, { status: "connected" });
      return json(res, 200, true);
    }
    if (req.method === "POST" && (m = p.match(/^\/session\/([^/]+)\/prompt_async$/))) {
      const body = await readBody(req);
      const text = (body.parts || []).map((x) => x.text || "").join("\n");
      res.writeHead(204); res.end();
      runTurn(m[1], text, url.searchParams.get("directory")).catch((e) => console.error("[fake-opencode] turn failed", e));
      return;
    }
    if (req.method === "POST" && p.match(/^\/session\/([^/]+)\/summarize$/)) { await readBody(req); return json(res, 200, true); }
    if (req.method === "POST" && (m = p.match(/^\/session\/([^/]+)\/abort$/))) {
      aborted.add(m[1]);
      emit("session.status", { sessionID: m[1], status: { type: "idle" } });
      emit("session.idle", { sessionID: m[1] });
      return json(res, 200, true);
    }
    if (req.method === "POST" && (m = p.match(/^\/permission\/([^/]+)\/reply$/))) {
      const body = await readBody(req);
      const resume = pendingPermissions.get(m[1]);
      pendingPermissions.delete(m[1]);
      emit("permission.replied", { sessionID: "", requestID: m[1], reply: body.reply });
      if (resume) resume(body.reply);
      return json(res, 200, true);
    }
    if (req.method === "POST" && (m = p.match(/^\/question\/([^/]+)\/(reply|reject)$/))) {
      const body = await readBody(req);
      const pending = pendingQuestions.get(m[1]);
      if (!pending) return json(res, 404, { error: `fake-opencode: no question ${m[1]}` });
      pendingQuestions.delete(m[1]);
      const sessionID = pending.request.sessionID;
      if (m[2] === "reply") {
        emit("question.replied", { sessionID, requestID: m[1], answers: body.answers || [] });
        pending.resume(body.answers || []);
      } else {
        emit("question.rejected", { sessionID, requestID: m[1] });
        pending.resume([]);
      }
      return json(res, 200, true);
    }
    if (req.method === "GET" && (m = p.match(/^\/session\/([^/]+)\/(children|message|diff)$/))) return json(res, 200, []);
    if (req.method === "GET" && (m = p.match(/^\/session\/([^/]+)$/))) return json(res, 200, { id: m[1], ...(sessions.get(m[1]) || {}) });
    json(res, 404, { error: `fake-opencode: no route for ${req.method} ${p}` });
  } catch (e) {
    console.error("[fake-opencode]", e);
    json(res, 500, { error: String(e) });
  }
});

server.listen(PORT, "127.0.0.1", () => console.log(`[fake-opencode] listening on http://127.0.0.1:${PORT}`));
