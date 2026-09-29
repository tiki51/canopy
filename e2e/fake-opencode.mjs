// A deterministic stand-in for `opencode serve`, just enough of the HTTP + SSE
// contract for Canopy's adapter (verified against OpenCode 1.18 in Phase 0).
// It also acts as an MCP client: when a prompt looks like a delegation or a
// handoff wake-up, it calls Canopy's real MCP tools, the way the plugin-stamped
// agent would, so browser tests exercise the whole loop.
import http from "node:http";

const PORT = Number(process.env.FAKE_OPENCODE_PORT || 4396);
// Pause between the steps of a turn; raise it (FAKE_TURN_DELAY_MS=2500) to
// keep an agent visibly "working" long enough for a screenshot.
const TURN_DELAY = Number(process.env.FAKE_TURN_DELAY_MS || 50);
const streams = new Set(); // SSE clients on GET /event
const sessions = new Map(); // id -> {parentID}
const pendingPermissions = new Map(); // per_id -> resume fn
const aborted = new Set(); // session ids aborted mid-turn (long turns stop early)
let dialogue = 0; // lines spoken in the load-test back-and-forth (site screenshots)
const pendingQuestions = new Map(); // que_id -> {request, resume}
let mcp = null; // {url, headers} learned from POST /mcp
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
  "Two load test runs, then. I'll use the seeded carts from `fixtures/carts.json`; the big ones are where priceCart hurts.",
  "Good. For the load test, report p50, p95 and the pricing service's own latency, per run.",
  "Will do. I'll post the load test numbers as a table once both runs finish.",
  "Thanks. I'll draft the cache change while the load test runs.",
];

// ---- a scripted agent turn -----------------------------------------------------
async function runTurn(sessionID, text) {
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
    await mcpCall("message_send", { canopy_session_id: sessionID, text: `${other}, ${line}` });
    return finishTurn(sessionID, messageID, part, "Replied about the load test.", 0.0004);
  }

  // one read tool, pending -> running -> completed
  const callID = nextId("call");
  const toolID = nextId("prt");
  emit("message.part.updated", { sessionID, part: { id: toolID, sessionID, messageID, type: "tool", callID, tool: "read", state: { status: "pending", input: {} } } });
  emit("message.part.updated", { sessionID, part: { id: toolID, sessionID, messageID, type: "tool", callID, tool: "read", state: { status: "running", input: { filePath: "README.md" }, time: { start: Date.now() } } } });
  await sleep(TURN_DELAY);
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
      await mcpCall("message_send", { canopy_session_id: sessionID, text: choice ? `Going with **${choice}**.` : "Skipped the question; keeping the current key." });
      reply = "Answered.";
    } else {
      await mcpCall("message_send", { canopy_session_id: sessionID, text: "Acknowledged: looking into it now.\n\n1. Read `README.md`\n2. Check the queue\n\n```python\nqueue.add(invoice_id)\n```" });
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
      return json(res, 200, { providers: [{ id: "opencode", name: "OpenCode Zen", models: { "gpt-5-nano": { cost: { input: 0.05, output: 0.4, cache: { read: 0.005, write: 0 } } }, "claude-haiku-4-5": { cost: { input: 1, output: 5, cache: { read: 0.1, write: 1.25 } } } } }], default: { opencode: "gpt-5-nano" } });
    if (req.method === "GET" && p === "/agent") return json(res, 200, [{ name: "build", mode: "primary" }, { name: "plan", mode: "primary" }]);
    if (req.method === "GET" && p === "/mcp") return json(res, 200, mcp ? { canopy: { status: "connected" } } : {});
    if (req.method === "POST" && p === "/instance/dispose") { mcp = null; mcpSession = null; return json(res, 200, true); }
    if (req.method === "POST" && p === "/mcp") {
      const body = await readBody(req);
      mcp = { url: body.config.url, headers: body.config.headers || {} };
      mcpSession = null;
      console.log(`[fake-opencode] MCP registered -> ${mcp.url}`);
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
    if (req.method === "POST" && (m = p.match(/^\/session\/([^/]+)\/prompt_async$/))) {
      const body = await readBody(req);
      const text = (body.parts || []).map((x) => x.text || "").join("\n");
      res.writeHead(204); res.end();
      runTurn(m[1], text).catch((e) => console.error("[fake-opencode] turn failed", e));
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
      if (resume) resume();
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
