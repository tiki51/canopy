// A deterministic stand-in for `claude -p` in the browser tests, the way
// e2e/fake-opencode.mjs stands in for `opencode serve`. Canopy spawns it once
// per turn exactly as it spawns Claude Code (see Canopy.ClaudeCode.Command):
// it reads one stream-json `user` line from stdin and prints stream-json on
// stdout until the `result` line. Lines written to stdin while it runs (a
// message steered into the turn) are read at the next tool round, the way
// Claude Code is believed to fold `priority: "next"` messages, and the result
// lists their uuids in `user_message_uuids`; one that comes after the last
// tool is left unread, so Canopy sends it again.
//
// It is also an MCP client: it calls Canopy's real MCP server with the bearer
// token from --mcp-config, so messages, delegations, handoffs and schedules
// go through the same tools a real agent uses. Permission prompts and
// AskUserQuestion go through `mcp__canopy__permission` like the real CLI's
// --permission-prompt-tool, so the cards in the channel are the app's own.
//
// The site story (e2e/tests/site-*.spec.ts) is scripted below; anything else
// gets a short generic turn. Per-session story state lives in the OS temp dir,
// standing in for the transcript Claude Code would keep between turns.
//
//   FAKE_TURN_DELAY_MS   pause per tool call (default 50; the site specs use 2500)
//   FAKE_CLAUDE_VERSION  what --version prints and system/init reports
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";

const argv = process.argv.slice(2);
const out = (obj) => process.stdout.write(JSON.stringify(obj) + "\n");

if (argv[0] === "--version") {
  console.log(`${process.env.FAKE_CLAUDE_VERSION || "2.1.283"} (Claude Code)`);
  process.exit(0);
}
if (argv[0] === "auth") {
  out({ loggedIn: true, authMethod: "claude.ai", subscriptionType: "max", email: "priya@acme.example" });
  process.exit(0);
}

const TURN_DELAY = Number(process.env.FAKE_TURN_DELAY_MS || 50);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- command line ------------------------------------------------------------
function flags(args) {
  const opts = { allowed: [] };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    const next = () => args[++i];
    if (a === "--session-id" || a === "--resume") opts.sid = next();
    else if (a === "--model") opts.model = next();
    else if (a === "--mcp-config") opts.mcpConfig = next();
    else if (a === "--permission-mode") opts.mode = next();
    else if (a === "--permission-prompt-tool") opts.promptTool = next();
    else if (a === "--allowedTools") while (args[i + 1] && !args[i + 1].startsWith("--")) opts.allowed.push(next());
  }
  return opts;
}
const opts = flags(argv);
const sid = opts.sid || "fake-session";
const cwd = process.cwd();
const MODELS = { sonnet: "claude-sonnet-5", opus: "claude-opus-5-5", haiku: "claude-haiku-4-5" };
const model = MODELS[opts.model] || opts.model || "claude-sonnet-5";

// ---- per-session story state -----------------------------------------------------
const stateFile = path.join(os.tmpdir(), "canopy-fake-claude", `${sid}.json`);
const loadState = () => {
  try {
    return JSON.parse(fs.readFileSync(stateFile, "utf8"));
  } catch {
    return {};
  }
};
const saveState = (s) => {
  fs.mkdirSync(path.dirname(stateFile), { recursive: true });
  fs.writeFileSync(stateFile, JSON.stringify(s));
};

// ---- minimal MCP client (Streamable HTTP) -------------------------------------------
// node:http rather than fetch: a permission call blocks until someone answers
// the card, and fetch gives up on response headers after five minutes.
const mcp = (() => {
  try {
    const config = JSON.parse(fs.readFileSync(opts.mcpConfig, "utf8"));
    // Canopy's own entry; the repository's .mcp.json servers ride along beside it
    return config.mcpServers?.canopy || null;
  } catch {
    return null;
  }
})();
let mcpSession = null;
let rpcId = 0;

function post(body) {
  return new Promise((resolve, reject) => {
    const headers = {
      ...(mcp.headers || {}),
      "content-type": "application/json",
      accept: "application/json, text/event-stream",
    };
    if (mcpSession) headers["mcp-session-id"] = mcpSession;
    const req = http.request(mcp.url, { method: "POST", headers }, (res) => {
      const sessionHeader = res.headers["mcp-session-id"];
      if (sessionHeader) mcpSession = sessionHeader;
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
      res.on("error", reject);
    });
    req.on("error", reject);
    req.end(JSON.stringify(body));
  });
}

async function rpc(method, params, id) {
  const body = { jsonrpc: "2.0", method, params };
  if (id !== undefined) body.id = id;
  const text = await post(body);
  const lines = text.split("\n").filter((l) => l.startsWith("data:"));
  const messages = lines.length ? lines.map((l) => JSON.parse(l.slice(5))) : text.trim() ? [JSON.parse(text)] : [];
  return messages.find((m) => m.id === id);
}

async function mcpCall(name, args = {}) {
  if (!mcp) throw new Error("no --mcp-config: Canopy's MCP server is unknown");
  if (!mcpSession) {
    await rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "fake-claude", version: "0" } }, ++rpcId);
    await rpc("notifications/initialized", {});
  }
  const reply = await rpc("tools/call", { name, arguments: args }, ++rpcId);
  const text = (reply?.result?.content || []).map((c) => c.text || "").join("\n");
  return { text, error: reply?.error?.message || (reply?.result?.isError ? text : null) };
}

// ---- stream-json output ------------------------------------------------------------
let steps = 0;
let cost = 0;
let context = 17_000 + Math.floor(Math.random() * 3_000);
const usage = { input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 };
const price = model.includes("opus") ? 3 : model.includes("haiku") ? 0.35 : 1;

// One model call: message_start (input usage), the assistant message, message_delta (output usage).
function modelCall(content, stopReason) {
  const id = `msg_fake_${sid.slice(0, 8)}_${++steps}`;
  const fresh = 200 + Math.floor(Math.random() * 400);
  const produced = 60 + Math.floor(Math.random() * 240);
  out({ type: "stream_event", session_id: sid, event: { type: "message_start", message: { id, usage: { input_tokens: 4, cache_read_input_tokens: context, cache_creation_input_tokens: fresh } } } });
  for (const [index, block] of content.entries()) {
    if (block.type !== "text") continue;
    for (const piece of block.text.match(/[\s\S]{1,80}/g) || []) {
      out({ type: "stream_event", session_id: sid, parent_tool_use_id: null, event: { type: "content_block_delta", index, delta: { type: "text_delta", text: piece } } });
    }
  }
  out({ type: "assistant", session_id: sid, parent_tool_use_id: null, message: { id, type: "message", role: "assistant", model, content } });
  out({ type: "stream_event", session_id: sid, event: { type: "message_delta", delta: { stop_reason: stopReason }, usage: { output_tokens: produced } } });
  usage.input_tokens += 4;
  usage.output_tokens += produced;
  usage.cache_read_input_tokens += context;
  usage.cache_creation_input_tokens += fresh;
  cost += price * (context * 0.3e-6 + fresh * 3.75e-6 + produced * 15e-6);
  context += fresh + produced;
}

// Would the real CLI ask before running this tool? Mirrors --permission-mode
// and --allowedTools; read-only tools and Canopy's own tools never ask.
function needsPermission(name, input) {
  if (name === "AskUserQuestion") return true;
  if (name.startsWith("mcp__") || ["Read", "Grep", "Glob"].includes(name)) return false;
  if (opts.mode === "bypassPermissions") return false;
  if (opts.mode === "acceptEdits" && ["Edit", "Write", "MultiEdit", "NotebookEdit"].includes(name)) return false;
  return !opts.allowed.some((rule) => {
    if (rule === name) return true;
    const m = rule.match(/^(\w+)\((.*)\)$/);
    if (!m || m[1] !== name || name !== "Bash") return false;
    const prefix = m[2].replace(/:?\*$/, "").trim();
    return (input.command || "").startsWith(prefix);
  });
}

let toolCounter = 0;
// One tool call: the tool_use, the permission prompt if the CLI would ask,
// `hold` × FAKE_TURN_DELAY_MS of "running" (so the live card shows it), then
// the result. `run(input)` does the work and returns the result text.
async function tool(name, input, run, { hold = 1 } = {}) {
  const id = `toolu_fake_${sid.slice(0, 8)}_${++toolCounter}`;
  modelCall([{ type: "tool_use", id, name, input }], "tool_use");
  let decision = { behavior: "allow", updatedInput: input };
  if (needsPermission(name, input)) {
    const reply = await mcpCall(opts.promptTool?.replace(/^mcp__[^_]+__/, "") || "permission", { tool_name: name, input, tool_use_id: id });
    decision = reply.error ? { behavior: "deny", message: reply.error } : JSON.parse(reply.text);
  }
  if (decision.behavior !== "allow") {
    out({ type: "user", session_id: sid, message: { role: "user", content: [{ type: "tool_result", tool_use_id: id, content: decision.message || "denied", is_error: true }] } });
    return { denied: true, message: decision.message };
  }
  const started = Date.now();
  let result;
  let error = false;
  try {
    result = await run(decision.updatedInput || input);
  } catch (e) {
    result = String(e.message || e);
    error = true;
  }
  await sleep(Math.max(0, TURN_DELAY * hold - (Date.now() - started)));
  out({ type: "user", session_id: sid, message: { role: "user", content: [{ type: "tool_result", tool_use_id: id, content: result, is_error: error }] } });
  foldQueued();
  return { result, input: decision.updatedInput || input, error };
}

// ---- messages steered into the turn ---------------------------------------------------
const queued = []; // stdin lines after the prompt, not read yet
const consumed = []; // the uuids of the ones read, for the result
const foldedTexts = [];
const textOf = (content) =>
  typeof content === "string" ? content : (content || []).filter((b) => b.type === "text").map((b) => b.text).join("\n");

function foldQueued() {
  while (queued.length) {
    try {
      const msg = JSON.parse(queued.shift());
      if (msg.uuid) consumed.push(msg.uuid);
      foldedTexts.push(textOf(msg.message?.content));
    } catch {
      // not a message
    }
  }
}

// ---- tools ---------------------------------------------------------------------------
const abs = (rel) => path.join(cwd, rel);
const read = (rel) => tool("Read", { file_path: abs(rel) }, () => fs.readFileSync(abs(rel), "utf8"), { hold: 1 });
const edit = (rel, oldString, newString, hold = 1) =>
  tool("Edit", { file_path: abs(rel), old_string: oldString, new_string: newString }, (input) => {
    const text = fs.readFileSync(input.file_path, "utf8");
    if (!text.includes(input.old_string)) throw new Error(`old_string not found in ${rel}`);
    fs.writeFileSync(input.file_path, text.replace(input.old_string, input.new_string));
    return `The file ${input.file_path} has been updated successfully.`;
  }, { hold });
const bash = (command, output, hold = 1) => tool("Bash", { command }, () => (typeof output === "function" ? output() : output), { hold });

function grepFiles(pattern) {
  const hits = [];
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (entry.name.startsWith(".")) continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else
        fs.readFileSync(full, "utf8")
          .split("\n")
          .forEach((line, i) => line.includes(pattern) && hits.push(`${path.relative(cwd, full)}:${i + 1}:${line}`));
    }
  };
  walk(cwd);
  return hits.join("\n") || "No matches found";
}
const grep = (pattern, hold = 1) => tool("Grep", { pattern, output_mode: "content", "-n": true }, () => grepFiles(pattern), { hold });

// Canopy's own tools, through the real MCP server. Quick: they are not the show.
const canopy = (name, args = {}) =>
  tool(`mcp__canopy__${name}`, args, async () => {
    const reply = await mcpCall(name, args);
    if (reply.error) throw new Error(reply.error);
    return reply.text;
  }, { hold: 0.3 });

function finish(text, extra = {}) {
  for (const folded of foldedTexts) {
    const body = folded.match(/Message text:\n([\s\S]*?)\n(?:Attachments on this message:|canopy_messages_read returns)/)?.[1]?.trim();
    if (body) text = `${text}\n\nRe your message: “${body}”`;
  }
  modelCall([{ type: "text", text }], "end_turn");
  out({
    type: "result",
    subtype: "success",
    is_error: false,
    duration_ms: Date.now() - startedAt,
    num_turns: steps,
    result: text,
    session_id: sid,
    total_cost_usd: Number(cost.toFixed(6)),
    usage,
    user_message_uuids: consumed,
    ...extra,
  });
}

// ---- the site story (e2e/tests/site-shots.spec.ts, site-video.spec.ts) ---------------------
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

// Turn 1: read the code, post the root cause, delegate the caller list.
async function rootCause(body, state) {
  state.story = { mode: /\bfix it\b/i.test(body) ? "build" : "plan", phase: "delegated" };
  saveState(state);
  await read("acme/billing/payments.py");
  await read("acme/billing/retry_worker.py");
  await grep("enqueue_charge");
  // three tools done: the live card holds on "researching" for the ST-2 still
  await tool("Read", { file_path: abs("acme/billing/webhooks.py") }, () => fs.readFileSync(abs("acme/billing/webhooks.py"), "utf8"), { hold: 2.5 });
  await canopy("message_send", { text: ROOT_CAUSE });
  await canopy("delegate_task", {
    to: "researcher",
    task: "List every code path in acme-billing that can call enqueue_charge, with file and line and the guard each one relies on.",
  });
  finish("Posted the root cause; the researcher is tracing every caller of enqueue_charge.");
}

// Turn 2, once the researcher is back: propose and ask (stills), or build (recording).
async function afterResearch(state) {
  if (state.story.mode === "build") return build(state, "the invoice only");
  state.story.phase = "planned";
  saveState(state);
  await canopy("message_send", { text: PLAN });
  await canopy("task_update", { status: "working" });
  finish("Proposed an idempotent enqueue_charge; waiting for a go-ahead.");
}

// Turn 3 (stills): ask about the key, then build.
async function goAhead(state) {
  const question = "Should the claim key include the attempt number?";
  const asked = await tool("AskUserQuestion", {
    questions: [{
      question,
      header: "Claim key",
      multiSelect: false,
      options: [
        { label: "Invoice only (Recommended)", description: "One claim per invoice: every retry path competes for it, so a charge lands at most once." },
        { label: "Invoice + attempt", description: "A fresh claim per attempt; the worker has to dedupe retries itself." },
      ],
    }],
  }, (input) => `User has answered your questions: "${question}"="${input.answers?.[question] ?? ""}". You can now continue with the user's answers in mind.`, { hold: 0.2 });
  const answer = asked.denied ? "" : asked.input.answers?.[question] || "";
  const key = /attempt/i.test(answer) ? "the invoice and the attempt number" : "the invoice only";
  return build(state, key);
}

async function build(state, key) {
  state.story.phase = "built";
  saveState(state);
  await read("acme/billing/payments.py");
  const edited = await edit("acme/billing/payments.py", PAYMENTS_OLD, PAYMENTS_NEW);
  if (edited.denied) {
    await canopy("message_send", { text: "Stopped before changing anything: the edit to `payments.py` was not approved. Tell me how you'd like to proceed." });
    return finish("The edit was not approved; nothing changed.");
  }
  await edit("tests/test_payments.py", TEST_OLD, TEST_NEW, 0.6);
  await bash("pytest tests/test_payments.py -q", "...............                                                          [100%]\n15 passed in 2.1s", 1.2);
  await canopy("message_send", { text: doneMessage(key) });
  await canopy("handoff_task", {
    to: "reviewer",
    summary: `Idempotent enqueue_charge via invoices.claim_charge, keyed on ${key}; 15 tests pass.`,
    reason: "needs a second pair of eyes before the PR",
    suggested_next_step: "Review the diff, then ask @test for a load test if the claim query looks hot.",
  });
  finish("Fix and test in the working tree; handed to @reviewer.");
}

// The reviewer takes the handoff, reads the diff and approves.
async function review(handoffId) {
  const packet = await canopy("handoff_get", { handoff_id: handoffId });
  await canopy("handoff_accept", { handoff_id: handoffId });
  if (!/claim_charge/.test(packet.result || "")) {
    await canopy("message_send", { text: "Took over the task; reading the handoff and the working tree now." });
    return finish("Accepted the handoff.");
  }
  await bash("git diff", () => execFileSync("git", ["diff"], { cwd, encoding: "utf8" }) || "(no changes)");
  await read("tests/test_payments.py");
  await canopy("message_send", { text: APPROVAL });
  finish("Reviewed the diff; approved with two non-blocking notes.");
}

// "every weekday at 09:00, <instruction>" → a cron schedule.
async function schedule(body) {
  const m = body.match(/every (weekday|day) at (\d{1,2}):(\d{2}),?\s*(.*)$/is);
  const [, days, hh, mm, rest] = m;
  const cron = `${Number(mm)} ${Number(hh)} * * ${days.toLowerCase() === "weekday" ? "1-5" : "*"}`;
  const what = (rest.charAt(0).toUpperCase() + rest.slice(1)).trim().replace(/\.?$/, ".");
  const created = await canopy("schedule_create", { when: cron, what });
  if (created.error) {
    await canopy("message_send", { text: `I couldn't schedule that: ${created.result}` });
    return finish("Scheduling failed.");
  }
  const clock = `${hh.padStart(2, "0")}:${mm}`;
  await canopy("message_send", { text: `Scheduled: every ${days.toLowerCase()} at ${clock}. I'll ${rest.replace(/\.$/, "").replace(/post here if/, "post here only if")}.` });
  // not "09:00 check": site-shots waits for that text from the scheduled run itself
  finish(`Scheduled the weekday queue check for ${clock}.`);
}

async function scheduledCheck(instruction) {
  if (!/failed-charge queue/i.test(instruction)) {
    await canopy("message_send", { text: "Ran the scheduled check: all green." });
    return finish("Scheduled check done.");
  }
  await grep("failed_charges", 0.6);
  await canopy("message_send", {
    text: "**09:00 check:** the failed-charge queue is at 63, above the threshold of 50. 58 of them are `card_declined` for a single merchant, each on a different invoice, so these are genuine declines rather than duplicate retries; the claim fix is holding. Worth a word with support about that merchant.",
  });
  finish("Posted the 09:00 queue check.");
}

// ---- questions (e2e/tests/questions.spec.ts) --------------------------------------------
// "…ask me what to call the release" asks a question with no options (only a
// typed answer can answer it); "…ask me which colour" one with options. The
// answer comes back in the same turn, or, once the agent stopped waiting, as a
// channel message from the user: "@agent Answer to your question "…": …".
async function askUser(question, options) {
  const asked = await tool("AskUserQuestion", {
    questions: [{ question, header: "Question", multiSelect: false, options }],
  }, (input) => `User has answered your questions: "${question}"="${input.answers?.[question] ?? ""}".`, { hold: 0.2 });
  if (asked.denied) {
    if (/hasn't answered yet/.test(asked.message || "")) return finish("Waiting for the user's answer.");
    await canopy("message_send", { text: "Skipped the question." });
    return finish("The question was declined.");
  }
  await canopy("message_send", { text: `Going with **${asked.input.answers?.[question] || "nothing"}**.` });
  finish("Answered.");
}

async function lateAnswer(body) {
  const answer = body.match(/Answer to your question "[^"]*": ([^\n(]*)/)?.[1]?.trim() || "nothing";
  await canopy("message_send", { text: `Going with **${answer}** (answered later).` });
  finish("Picked up the late answer.");
}

// ---- dispatch ----------------------------------------------------------------------------
const startedAt = Date.now();

async function turn(prompt) {
  const state = loadState();
  const story = state.story || {};
  const messageFrom = prompt.match(/new Canopy message in #\S+ from (\S+)\./)?.[1];
  const body = prompt.match(/Message text:\n([\s\S]*?)\n(?:Attachments on this message:|canopy_messages_read returns)/)?.[1]?.trim() || "";

  let m;
  if ((m = prompt.match(/Handoff ID: (ho_\S+)/))) return review(m[1]);
  if (/accepted your handoff/.test(prompt)) {
    await canopy("pass", {});
    return finish("Nothing to do: the handoff was accepted.");
  }
  if ((m = prompt.match(/Delegation ID: (dl_\S+)/))) {
    await read("README.md");
    await canopy("task_update", { status: "completed", result: "Done: see README.md." });
    return finish("Delegated work finished.");
  }
  if (/A scheduled task of yours is due/.test(prompt)) {
    const instruction = prompt.match(/Instruction[^\n]*:\n([^\n]*)/)?.[1] || "";
    return scheduledCheck(instruction);
  }
  // The researcher's report and the delegation's completion both wake the
  // owner; whichever arrives first continues the story, the other is a pass.
  const research = /Your delegated subtask .* was completed/.test(prompt) || messageFrom === "@researcher";
  if (research && story.phase === "delegated") return afterResearch(state);
  if (/Your delegated subtask/.test(prompt)) {
    await canopy("pass", {});
    return finish("Already continued after the delegation.");
  }
  if (messageFrom) {
    if (messageFrom.startsWith("@")) {
      // another agent's post that needs nothing from this one
      await canopy("pass", {});
      return finish("Nothing to add.");
    }
    if (/Answer to your question "/.test(body)) return lateAnswer(body);
    if (/charged twice/i.test(body)) return rootCause(body, state);
    if (/ask me what to call the release/i.test(body)) return askUser("What should the release be called?", []);
    if (/ask me which colou?r/i.test(body))
      return askUser("Which colour should the banner be?", [
        { label: "Green", description: "Calm." },
        { label: "Orange", description: "Loud." },
      ]);
    if (/\bgo ahead\b/i.test(body) && story.phase === "planned") return goAhead(state);
    if (/every (weekday|day) at \d{1,2}:\d{2}/i.test(body)) return schedule(body);
    await read("README.md");
    await canopy("message_send", { text: "Acknowledged: looking into it now." });
    return finish("Replied.");
  }
  finish("Nothing to do.");
}

// Abort is SIGINT: Claude Code ends the turn with an error result and exits 0.
process.on("SIGINT", () => {
  out({ type: "result", subtype: "error_during_execution", is_error: true, num_turns: steps, result: "", session_id: sid, total_cost_usd: Number(cost.toFixed(6)), usage });
  process.exit(0);
});

// The first line is the prompt; later ones wait in `queued` for a tool round.
function readPrompt() {
  return new Promise((resolve) => {
    let buf = "";
    let first = true;
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => {
      buf += chunk;
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        if (first) {
          first = false;
          resolve(line);
        } else queued.push(line);
      }
    });
    process.stdin.on("end", () => first && resolve(buf));
  });
}

const line = await readPrompt();
let prompt = "";
try {
  prompt = textOf(JSON.parse(line).message?.content);
} catch {
  prompt = line;
}

// The repository's servers are never started here: they report "pending".
const configured = (() => {
  try {
    return Object.keys(JSON.parse(fs.readFileSync(opts.mcpConfig, "utf8")).mcpServers || {}).filter((n) => n !== "canopy");
  } catch {
    return [];
  }
})();
const mcpServers = [{ name: "canopy", status: mcp ? "connected" : "failed" }, ...configured.map((name) => ({ name, status: "pending" }))];
const tools = ["Read", "Edit", "Bash", ...(mcp ? ["mcp__canopy__message_send", "mcp__canopy__messages_read", "mcp__canopy__pass", "mcp__canopy__permission"] : [])];
out({ type: "system", subtype: "init", session_id: sid, cwd, model, permissionMode: opts.mode || "default", claude_code_version: process.env.FAKE_CLAUDE_VERSION || "2.1.283", mcp_servers: mcpServers, tools });

try {
  if (prompt.trim() === "/compact") {
    out({ type: "system", subtype: "compact_boundary", session_id: sid, compact_metadata: { trigger: "manual", pre_tokens: context } });
    finish("Compacted.");
  } else {
    await turn(prompt);
  }
} catch (e) {
  process.stderr.write(`[fake-claude] ${e.stack || e}\n`);
  out({ type: "result", subtype: "error_during_execution", is_error: true, num_turns: steps, result: String(e.message || e), session_id: sid, total_cost_usd: cost, usage });
}
process.stdout.write("", () => process.exit(0));
