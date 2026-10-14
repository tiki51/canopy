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
// The site story (e2e/tests/site-*.spec.ts, a Feature build run from
// e2e/bin/seed-reports.exs) and the older billing story are scripted below; anything else
// gets a short generic turn. Per-session story state lives in the OS temp dir,
// standing in for the transcript Claude Code would keep between turns.
//
//   FAKE_TURN_DELAY_MS   pause per tool call (default 50; the site specs use 2500)
//   FAKE_CLAUDE_VERSION  what --version prints and system/init reports
//   FAKE_CLAUDE_PROMPT_LOG  a file to append every turn's prompt to (debugging a story)
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
    else if (a === "--append-system-prompt-file") opts.systemFile = next();
    else if (a === "--permission-mode") opts.mode = next();
    else if (a === "--permission-prompt-tool") opts.promptTool = next();
    else if (a === "--allowedTools") while (args[i + 1] && !args[i + 1].startsWith("--")) opts.allowed.push(next());
  }
  return opts;
}
const opts = flags(argv);
const sid = opts.sid || "fake-session";
const cwd = process.cwd();
// Who this turn is for, from the collaboration prompt's first line ("… (@name), an AI coworker …").
const me = (() => {
  try {
    return fs.readFileSync(opts.systemFile, "utf8").match(/\(@([\w-]+)\), an AI coworker/)?.[1] || null;
  } catch {
    return null;
  }
})();
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
// Like Claude Code, `total_cost_usd` is the session's running total: the CLI
// restores it from the transcript on --resume (a `cost-state` line), and
// Canopy subtracts where the turn started. Kept beside the story state.
const costFile = path.join(os.tmpdir(), "canopy-fake-claude", `${sid}.cost`);
let cost = (() => {
  try {
    return Number(fs.readFileSync(costFile, "utf8")) || 0;
  } catch {
    return 0;
  }
})();
const saveCost = () => {
  try {
    fs.mkdirSync(path.dirname(costFile), { recursive: true });
    fs.writeFileSync(costFile, String(cost));
  } catch {
    // the next turn just starts over, as the real CLI does without a cost-state
  }
};
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
const write = (rel, content, hold = 1) =>
  tool("Write", { file_path: abs(rel), content }, (input) => {
    fs.mkdirSync(path.dirname(input.file_path), { recursive: true });
    fs.writeFileSync(input.file_path, input.content);
    return `File created successfully at: ${input.file_path}`;
  }, { hold });

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
const canopy = (name, args = {}, hold = 0.3) =>
  tool(`mcp__canopy__${name}`, args, async () => {
    const reply = await mcpCall(name, args);
    if (reply.error) throw new Error(reply.error);
    return reply.text;
  }, { hold });

function finish(text, extra = {}) {
  for (const folded of foldedTexts) {
    const body = folded.match(/Message text:\n([\s\S]*?)\n(?:Attachments on this message:|canopy_messages_read returns)/)?.[1]?.trim();
    if (body) text = `${text}\n\nRe your message: “${body}”`;
  }
  modelCall([{ type: "text", text }], "end_turn");
  saveCost();
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

// ---- the site's playbook story (e2e/bin/seed-reports.exs) ---------------------------------
// One Feature build run, "Add a CSV export to the Reports page", coordinated
// by @project-manager. The coordinator reads where the run is from the note
// Canopy appends to its every prompt ("step N of M … Delegations: x of y
// done"), so a wake that arrives late or twice finds the run already moved on
// and passes. The delegates know their part from the step line of their
// delegation ("This is step `build` of the feature-build playbook").
const FB_STEPS = ["intake", "design", "design-approval", "tech-design", "tech-review", "build", "verify", "design-check", "sign-off"];

const PAGE_TOOLBAR_OLD = `      toolbar={<FilterChips value={filters} onChange={setFilters} />}`;
const PAGE_TOOLBAR_NEW = `      toolbar={
        <>
          <FilterChips value={filters} onChange={setFilters} />
          <ExportMenu reportId={reportId} filters={filters} />
        </>
      }`;
const PAGE_IMPORT_OLD = `import { useReport } from "../api/reports";`;
const PAGE_IMPORT_NEW = `import { Menu, MenuItem } from "../components/Menu";
import { exportUrl, useReport, type Filters } from "../api/reports";`;
const PAGE_END_OLD = `  );
}
`;
const PAGE_END_NEW = `  );
}

function ExportMenu({ reportId, filters }: { reportId: string; filters: Filters }) {
  return (
    <Menu label="Export">
      <MenuItem href={exportUrl(reportId, filters)} hint="Filters and sort as shown">
        CSV, current view
      </MenuItem>
      <MenuItem href={exportUrl(reportId, {})} hint="Ignores the filters">
        CSV, all rows
      </MenuItem>
    </Menu>
  );
}
`;
const API_TS_OLD = "const query = (filters: Filters) => new URLSearchParams(filters).toString();";
const API_TS_NEW = `${API_TS_OLD}

/** The CSV download for a report, with the filters the table shows. */
export const exportUrl = (reportId: string, filters: Filters) =>
  \`/api/reports/\${reportId}/export.csv?\${query(filters)}\`;`;

const REPORTS_OLD = "    return Report(id=report_id, title=spec.title, columns=spec.columns, rows=rows)";
const EMPTY_GUARD = `    if not report.rows:
        return ""
`;
const REPORTS_NEW = `${REPORTS_OLD}


def export_csv(report: Report) -> str:
    """The report as CSV: a header row, then one line per row."""
${EMPTY_GUARD}    out = io.StringIO()
    writer = csv.writer(out)
    writer.writerow(report.columns)
    writer.writerows(report.rows)
    return out.getvalue()`;
const IMPORTS_OLD = "from dataclasses import dataclass\n";
const IMPORTS_NEW = `import csv
import io
${IMPORTS_OLD}`;
const ROUTE_IMPORT_OLD = "from flask import Blueprint, jsonify, request";
const ROUTE_IMPORT_NEW = "from flask import Blueprint, Response, jsonify, request";
const ROUTE_OLD = `    return jsonify(title=report.title, columns=report.columns, rows=report.rows)
`;
const ROUTE_NEW = `${ROUTE_OLD}

@bp.get("/<report_id>/export.csv")
def export(report_id: str):
    report = reports.build_report(report_id, request.args.to_dict())
    return Response(
        reports.export_csv(report),
        mimetype="text/csv",
        headers={"Content-Disposition": f'attachment; filename="{report_id}.csv"'},
    )
`;
const TESTS_OLD = `    assert report.columns == ["Week", "Region", "Signups", "Activated", "Rate"]
`;
const TESTS_NEW = `${TESTS_OLD}


def test_export_csv_has_a_header_and_one_line_per_row(signups_store):
    report = reports.build_report("weekly-signups", {})
    lines = reports.export_csv(report).splitlines()
    assert lines[0] == "Week,Region,Signups,Activated,Rate"
    assert len(lines) == len(report.rows) + 1
`;
const TESTS_EMPTY = `${TESTS_NEW}

def test_export_csv_of_an_empty_report_is_the_header_only(empty_store):
    report = reports.build_report("weekly-signups", {})
    assert reports.export_csv(report) == "Week,Region,Signups,Activated,Rate\\r\\n"
`;

const DESIGN_POST = `Three designs for the CSV export, all built from the shared \`DataTable\`:

- **A · Export button in the page header.** One click, exports what the table shows. Simple, but it sits away from the filters it depends on.
- **B · Export menu in the table toolbar.** Next to the filters it respects, with "current view" and "all rows". Room for more formats later. **My pick.**
- **C · Export dialog with a column picker.** The most control, but an extra step for everyone who just wants the numbers.`;

const TECH_FRONTEND = `# CSV export: frontend

- \`web/src/pages/ReportsPage.tsx\`: an \`ExportMenu\` in the \`DataTable\` toolbar slot, beside \`FilterChips\` (design B).
- \`web/src/api/reports.ts\`: \`exportUrl(reportId, filters)\` builds \`/api/reports/<id>/export.csv?<filters>\`.
- Menu items are plain links, so the browser handles the download; no blob handling in React.
- Contract with backend: \`GET /api/reports/<id>/export.csv\`, the same filter query params as \`GET /api/reports/<id>\`.
- Tests: \`ReportsPage.test.tsx\` checks both menu items' hrefs.`;

const TECH_BACKEND = `# CSV export: backend

- \`acme/reports/reports.py\`: \`export_csv(report) -> str\`, a header row then one line per row (\`csv.writer\`).
- \`acme/reports/api.py\`: \`GET /api/reports/<id>/export.csv\`, same filters as \`GET /api/reports/<id>\`, \`text/csv\` with a \`Content-Disposition\` filename.
- No new queries: it reuses \`build_report\`, so the read-only runner and its limits still apply.
- Tests: \`tests/test_reports.py\` covers the header, the row count and the route.`;

const TEST_PLAN = `# CSV export: test plan

| # | Case | Kind |
|---|---|---|
| 1 | Header row matches the report's columns | unit |
| 2 | One line per row, in table order | unit |
| 3 | Values with commas and quotes are escaped | unit |
| 4 | An empty report exports the header row only | unit |
| 5 | Filters in the query string reach \`build_report\` | unit |
| 6 | \`Content-Disposition\` names the file \`<report>.csv\` | unit |
| 7 | Export menu shows "CSV, current view" and "CSV, all rows" | e2e |
| 8 | "Current view" keeps the filters; "all rows" drops them | e2e |
| 9 | The downloaded file opens with the expected header | e2e |

Screens: the toolbar with the menu open, light and dark.`;

const TEST_REPORT = `# CSV export: test report

Run on the working tree after the empty-report fix.

| Suite | Result |
|---|---|
| \`pytest tests/test_reports.py\` | 16 passed |
| \`npx playwright test reports-export\` | 5 passed |

All 9 plan cases pass, including #4 (an empty report exports the header row only), which failed in the first run.

Screens: the Export menu open in the toolbar, light and dark.`;

const SUMMARY = `- **Design:** Option B, an Export menu in the table toolbar ("CSV, current view" and "CSV, all rows").
- **Changes, 5 files:** \`ReportsPage.tsx\`, \`api/reports.ts\`, \`reports.py\`, \`api.py\`, \`test_reports.py\`.
- **Review:** sent back once (empty reports exported nothing); fixed, then approved.
- **Tests:** 16 unit and 5 e2e pass; the report is attached.`;

const docIds = (text) => [...new Set((text || "").match(/doc_[A-Za-z0-9]+/g) || [])];
// What the run's agents share beyond the channel (the design doc ids), per repository.
const storyFile = path.join(os.tmpdir(), "canopy-fake-claude", `story-${cwd.replace(/\W+/g, "_").slice(-80)}.json`);
const loadStory = () => {
  try {
    return JSON.parse(fs.readFileSync(storyFile, "utf8"));
  } catch {
    return {};
  }
};
const saveStory = (story) => {
  fs.mkdirSync(path.dirname(storyFile), { recursive: true });
  fs.writeFileSync(storyFile, JSON.stringify(story));
};

// The coordinator: where the run is comes from Canopy's note on every prompt.
async function coordinate(prompt, body) {
  const note = prompt.match(/Playbook in progress here: feature-build \(run \S+\), step (\d+) of \d+ "[^"]*"( is waiting for the user's approval)?(?: \(round (\d+)\))?/);
  const started = /You are coordinating the feature-build playbook/.test(prompt);
  // Priya accepted the sign-off: the run completed with it, so this wake carries no step note.
  if (/The user approved "User sign-off" \(sign-off\) of feature-build/.test(prompt)) {
    await canopy("task_update", { status: "completed", result: "CSV export on the Reports page: design B, 5 files, signed off." });
    return finish("Signed off; the run is complete.");
  }
  if ((!note && !started) || note?.[2]) {
    await canopy("pass", {});
    return finish("Nothing to do: the run is waiting for Priya, or done.");
  }
  const step = note ? FB_STEPS[Number(note[1]) - 1] : "intake";
  const round = Number(note?.[3] || 1);
  const counted = /Delegations for this step: \d+ of \d+ done\.|All delegations for this step are done\./.test(prompt);
  const allDone = /All delegations for this step are done\./.test(prompt);

  if (step === "intake") {
    await canopy("task_update", {
      title: "Feature: CSV export on the Reports page",
      description: "Add a CSV export to the Reports page, for people who take report numbers into a spreadsheet. Likely touches the frontend (ReportsPage, the DataTable toolbar) and the backend (a CSV endpoint beside the report API).",
      status: "working",
    });
    await read("web/src/pages/ReportsPage.tsx");
    await read("acme/reports/api.py");
    await canopy("playbook_advance", {
      result: "Feature: export the report on screen as CSV from the Reports page. For: anyone who takes report numbers into a spreadsheet. Source: Priya's brief. Layers: frontend (`ReportsPage.tsx`, `DataTable` toolbar) and backend (`acme/reports/api.py`).",
    });
    await canopy("delegate_task", {
      to: "designer",
      task: "Propose 3 distinct designs for exporting a report as CSV from the Reports page (`web/src/pages/ReportsPage.tsx`, built on the shared `DataTable`). One mockup per design, shared as a document, with a short rationale each and your recommendation.",
    });
    return finish("Captured the request; the designer is on three designs.");
  }

  if (step === "design" && allDone) {
    const ids = loadStory().designs || [];
    await canopy("playbook_advance", { result: "Three designs shared, A to C. @designer recommends B, the Export menu in the table toolbar." });
    await canopy("playbook_advance", {
      result: "Three designs for the CSV export. @designer recommends B: it sits with the filters it respects.",
      question: "Which design should we build?",
      options: [
        { label: "A · Header button", description: "One click, away from the filters." },
        { label: "B · Toolbar menu", description: "Beside the filters; current view or all rows.", recommended: true },
        { label: "C · Export dialog", description: "Pick the columns; one more step." },
      ],
      attachments: ids.join(","),
    });
    return finish("Design approval is with Priya.");
  }

  if (step === "tech-design" && !counted) {
    const choice = prompt.match(/They chose: "([^"]+)"/)?.[1] || "B · Toolbar menu";
    await canopy("task_update", { description: `Add a CSV export to the Reports page. Approved design: ${choice}.` });
    await canopy("delegate_task", {
      to: "frontend",
      task: `Write the frontend technical design for the CSV export, design ${choice}: files, the contract with backend (\`GET /api/reports/<id>/export.csv\`, same filters), tests. Backend writes its side in parallel.`,
    });
    await canopy("delegate_task", {
      to: "backend",
      task: "Write the backend technical design for the CSV export: `export_csv` in `acme/reports/reports.py` and `GET /api/reports/<id>/export.csv`, same filters as the report API, tests. Frontend writes its side in parallel.",
    });
    return finish("Technical design is with frontend and backend.");
  }

  if (step === "tech-design" && allDone) {
    await canopy("playbook_advance", { result: "Both docs shared (tech-design-frontend.md, tech-design-backend.md); they name the same contract, `GET /api/reports/<id>/export.csv`." });
    await canopy("delegate_task", { to: "reviewer", task: "Review the frontend and backend technical design docs for the CSV export (shared in the channel). Approve, or request changes with reasons." });
    return finish("Technical review is with the reviewer.");
  }

  if (step === "tech-review" && allDone) {
    await canopy("playbook_advance", { result: "@reviewer approved both docs; the contract matches." });
    await canopy("delegate_task", {
      to: "frontend",
      task: "Build design B: an Export menu in the `DataTable` toolbar on the Reports page, per your tech doc. The CSV endpoint is backend's side of the contract; coordinate it with them. Report files changed and passing tests.",
    });
    await canopy("delegate_task", { to: "test", task: "Write the test plan for the CSV export from the approved design and both tech docs: cases, edge cases, e2e flows, and the screens to capture. Share it as a document." });
    return finish("Build is under way: frontend on the feature, test on the plan.");
  }

  if (step === "build" && allDone) {
    await canopy("playbook_advance", {
      result: round > 1 ? "@backend fixed the empty export: a header row only, with a test." : "Frontend and backend done, unit tests pass; test plan shared.",
    });
    await canopy("delegate_task", { to: "reviewer", task: "Review `git diff` for the CSV export against the approved design and tech docs: correctness, edge cases, regressions." });
    await canopy("delegate_task", { to: "test", task: "Run your test plan for the CSV export (unit and e2e) and report the results, with the report as a document." });
    return finish("Verify: the reviewer on the diff, test running the plan.");
  }

  if (step === "verify" && allDone && round === 1) {
    await canopy("playbook_advance", {
      next: "build",
      result: "↩ Sent back to Build: empty reports export a header row only. @reviewer found `export_csv` returns an empty string for an empty report, and @test's case 4 fails the same way.",
    });
    await canopy("delegate_task", {
      to: "backend",
      task: "Sent back from verify: an empty report must export the header row only. `export_csv` returns \"\" when there are no rows (`acme/reports/reports.py:25`). Fix it and add the test for case 4.",
    });
    return finish("Sent Build back for the empty-report case.");
  }

  if (step === "verify" && allDone) {
    await canopy("playbook_advance", { result: "Test plan passes (16 unit, 5 e2e; test-report.md). @reviewer approved." });
    await canopy("delegate_task", { to: "designer", task: "Compare the built Export menu (screens in test-report.md) with design B and approve, or list the differences." });
    return finish("Design check is with the designer.");
  }

  if (step === "design-check" && allDone) {
    await canopy("playbook_advance", { result: "@designer approved: it matches design B." });
    // The sign-off step: the summary is the card's own text, and nothing else is posted.
    await canopy("playbook_advance", {
      result: SUMMARY,
      question: "Accept the CSV export on the Reports page?",
      attachments: ".canopy/out/test-report.md",
    });
    await canopy("pass", {});
    return finish("The CSV export is waiting for Priya's sign-off.");
  }

  await canopy("pass", {});
  return finish("Waiting on the step's delegations.");
}

// A delegate's part, by who it is and which step it is for.
async function delegateTurn(prompt, state) {
  const step = prompt.match(/This is step `([\w-]+)` of the feature-build playbook/)?.[1];
  const delegation = prompt.match(/Delegation ID: (dl_\S+)/)?.[1];
  const done = (result) => canopy("task_update", { status: "completed", result, delegation });

  if (me === "designer" && step === "design") {
    await read("web/src/pages/ReportsPage.tsx");
    await read("web/src/components/DataTable.tsx");
    const ids = [];
    for (const [key, caption] of [["a", "Option A · Export button in the page header"], ["b", "Option B · Export menu in the table toolbar"], ["c", "Option C · Export dialog with a column picker"]]) {
      const shared = await canopy("document_share", { path: `.canopy/out/designs/csv-export-option-${key}.png`, caption });
      ids.push(docIds(shared.result)[0]);
    }
    saveStory({ ...loadStory(), designs: ids });
    await canopy("message_send", { text: DESIGN_POST, attachments: ids.join(",") });
    await done("3 designs shared: A, B (recommended), C.");
    return finish("Shared three designs; B is my pick.");
  }
  if (me === "designer" && step === "design-check") {
    await read("web/src/pages/ReportsPage.tsx");
    await canopy("message_send", { text: "Design check: the Export menu matches B, in the toolbar beside the filters, with both items and their hints. Approved." });
    await done("Approved: matches design B.");
    return finish("Approved the build against design B.");
  }

  if ((me === "frontend" || me === "backend") && step === "tech-design") {
    await read(me === "frontend" ? "web/src/pages/ReportsPage.tsx" : "acme/reports/reports.py");
    const shared = await canopy("document_share", { content: me === "frontend" ? TECH_FRONTEND : TECH_BACKEND, filename: `tech-design-${me}.md` });
    if (shared.error) throw new Error(shared.result);
    await done(`Tech design shared: tech-design-${me}.md.`);
    return finish("Tech design shared.");
  }

  if (me === "reviewer" && step === "tech-review") {
    await canopy("message_send", { text: "Both tech docs approved. The contract matches on both sides: `GET /api/reports/<id>/export.csv` with the report's own filters, and no new queries." });
    await done("Approved both docs.");
    return finish("Approved the technical designs.");
  }

  if (me === "frontend" && step === "build") {
    state.buildDelegation = delegation;
    saveState(state);
    await read("web/src/pages/ReportsPage.tsx");
    await read("web/src/components/DataTable.tsx");
    await edit("web/src/pages/ReportsPage.tsx", PAGE_TOOLBAR_OLD, PAGE_TOOLBAR_NEW, 1.2);
    await edit("web/src/pages/ReportsPage.tsx", PAGE_IMPORT_OLD, PAGE_IMPORT_NEW, 0.4);
    await edit("web/src/pages/ReportsPage.tsx", PAGE_END_OLD, PAGE_END_NEW, 0.8);
    await edit("web/src/api/reports.ts", API_TS_OLD, API_TS_NEW, 0.8);
    await canopy("delegate_task", {
      to: "backend",
      task: "Add the CSV endpoint the Export menu links to: `GET /api/reports/<id>/export.csv` with the same filters as `GET /api/reports/<id>`, built on a new `export_csv(report)` in `acme/reports/reports.py` (a header row, then one line per row). Tests in `tests/test_reports.py`.",
    });
    await canopy("memory_write", {
      text: `## ${new Date().toISOString().slice(0, 10)}\n- Reports use the shared DataTable component (\`web/src/components/DataTable.tsx\`); put report actions in its \`toolbar\` slot, not the page header.`,
    }, 3);
    return finish("Export menu is in; backend is on the CSV endpoint.");
  }
  if (me === "frontend" && /Your delegated subtask .* was completed by @backend/.test(prompt)) {
    await bash("npm test -- ReportsPage", " ✓ src/pages/ReportsPage.test.tsx (3 tests) 412ms\n\n Test Files  1 passed (1)\n      Tests  3 passed (3)", 1);
    await canopy("message_send", { text: "Build done: the **Export** menu sits in the `DataTable` toolbar beside the filters, with \"CSV, current view\" and \"CSV, all rows\". The backend endpoint is wired in, and `npm test` passes." });
    await canopy("task_update", { status: "completed", result: "Export menu in ReportsPage.tsx and exportUrl in api/reports.ts; backend added export_csv and the route. npm test: 3 passed; pytest: 3 passed.", delegation: state.buildDelegation });
    return finish("Reported the build.");
  }

  if (me === "backend" && !step && /delegated a subtask to you/.test(prompt) && /export\.csv/.test(prompt)) {
    await read("acme/reports/reports.py");
    const edited = await edit("acme/reports/reports.py", REPORTS_OLD, REPORTS_NEW, 1);
    if (edited.denied) {
      await done("Stopped: the edit to reports.py was not approved.");
      return finish("The edit was not approved; nothing changed.");
    }
    await edit("acme/reports/reports.py", IMPORTS_OLD, IMPORTS_NEW, 0.4);
    await edit("acme/reports/api.py", ROUTE_IMPORT_OLD, ROUTE_IMPORT_NEW, 0.4);
    await edit("acme/reports/api.py", ROUTE_OLD, ROUTE_NEW, 0.8);
    await edit("tests/test_reports.py", TESTS_OLD, TESTS_NEW, 0.6);
    await bash("pytest tests/test_reports.py -q", "...                                                                      [100%]\n3 passed in 0.4s", 1);
    await done("`GET /api/reports/<id>/export.csv` and `export_csv` in reports.py; tests in test_reports.py; pytest: 3 passed.");
    return finish("CSV endpoint done.");
  }
  if (me === "backend" && step === "build") {
    await read("acme/reports/reports.py");
    await edit("acme/reports/reports.py", EMPTY_GUARD, "", 1);
    await edit("tests/test_reports.py", TESTS_NEW, TESTS_EMPTY, 0.6);
    await bash("pytest tests/test_reports.py -q", "....                                                                     [100%]\n4 passed in 0.4s", 1);
    await canopy("message_send", { text: "Fixed: an empty report now exports the header row only. The early `return \"\"` is gone, and `test_export_csv_of_an_empty_report_is_the_header_only` covers it." });
    await done("Empty reports export the header row only; new test; pytest: 4 passed.");
    return finish("Fixed the empty export.");
  }

  if (me === "test" && step === "build") {
    await read("acme/reports/api.py");
    const shared = await canopy("document_share", { content: TEST_PLAN, filename: "test-plan.md" });
    if (shared.error) throw new Error(shared.result);
    await done("Test plan shared: test-plan.md (9 cases, 3 e2e).");
    return finish("Test plan shared.");
  }
  if (me === "test" && step === "verify") {
    state.verifyRuns = (state.verifyRuns || 0) + 1;
    saveState(state);
    if (state.verifyRuns === 1) {
      await bash("pytest -q", "..F.........                                                             [100%]\nFAILED tests/test_export.py::test_empty_report_exports_header_only - AssertionError: '' != 'Week,Region,Signups,Activated,Rate\\r\\n'\n1 failed, 11 passed in 0.9s", 1.2);
      await bash("npx playwright test reports-export", "  5 passed (6.1s)", 1);
      await canopy("message_send", { text: "First run of the plan: 11 of 12 unit cases and all 5 e2e pass. **Case 4 fails:** an empty report downloads a 0-byte file instead of the header row." });
      await done("11/12 unit, 5/5 e2e. Case 4 fails: an empty report exports 0 bytes, no header row.");
      return finish("Reported one failing case.");
    }
    await bash("pytest -q", "............                                                             [100%]\n16 passed in 1.0s", 1.2);
    await bash("npx playwright test reports-export", "  5 passed (6.0s)", 1);
    await write(".canopy/out/test-report.md", TEST_REPORT, 0.6);
    await canopy("message_send", { text: "The test plan passes: 16 unit and 5 e2e, including case 4 (empty report, header row only). Report attached.", attachments: ".canopy/out/test-report.md" });
    await done("All 9 cases pass (16 unit, 5 e2e); test-report.md attached.");
    return finish("Test plan passes; report attached.");
  }

  if (me === "reviewer" && step === "verify") {
    state.reviews = (state.reviews || 0) + 1;
    saveState(state);
    await bash("git diff", () => execFileSync("git", ["diff"], { cwd, encoding: "utf8" }) || "(no changes)", 1.2);
    if (state.reviews === 1) {
      await read("acme/reports/reports.py");
      await canopy("message_send", {
        text: "↩ **Changes requested on Build.** `export_csv` returns an empty string for an empty report (`acme/reports/reports.py:25`), so the download has no header row and a spreadsheet opens it with no columns. **Empty reports should export a header row only.** Everything else looks right.",
      });
      await done("Changes requested: empty reports export a header row only (reports.py:25).");
      return finish("Sent the empty-report case back.");
    }
    await canopy("message_send", { text: "Approved. The empty case now exports the header row, and the new test covers it." });
    await done("Approved.");
    return finish("Approved the build.");
  }
  return false;
}

async function reportsStory(prompt, body, state) {
  if (me === "project-manager" && /feature-build/.test(prompt)) {
    await coordinate(prompt, body);
    return true;
  }
  if (/feature-build playbook/.test(prompt) || (me === "backend" && /export\.csv/.test(prompt)) || (me === "frontend" && /completed by @backend/.test(prompt))) {
    return (await delegateTurn(prompt, state)) !== false;
  }
  return false;
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
  const messageFrom = prompt.match(/new Canopy message in #\S+ from (.+?)\.\n/)?.[1];
  const body = prompt.match(/Message text:\n([\s\S]*?)\n(?:Attachments on this message:|canopy_messages_read returns)/)?.[1]?.trim() || "";

  if (process.env.FAKE_CLAUDE_PROMPT_LOG) fs.appendFileSync(process.env.FAKE_CLAUDE_PROMPT_LOG, `\n===== @${me} ${sid}\n${prompt}\n`);
  if (await reportsStory(prompt, body, state)) return;

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
  saveCost();
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
  saveCost();
  out({ type: "result", subtype: "error_during_execution", is_error: true, num_turns: steps, result: String(e.message || e), session_id: sid, total_cost_usd: cost, usage });
}
process.stdout.write("", () => process.exit(0));
