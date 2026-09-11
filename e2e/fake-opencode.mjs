// A deterministic stand-in for `opencode serve`, just enough of the HTTP + SSE
// contract for Canopy's adapter (verified against OpenCode 1.18 in Phase 0).
// It also acts as an MCP client: when a prompt looks like a delegation or a
// handoff wake-up, it calls Canopy's real MCP tools, the way the plugin-stamped
// agent would, so browser tests exercise the whole loop.
import http from "node:http";

const PORT = Number(process.env.FAKE_OPENCODE_PORT || 4396);
const streams = new Set(); // SSE clients on GET /event
const sessions = new Map(); // id -> {parentID}
const pendingPermissions = new Map(); // per_id -> resume fn
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

// ---- a scripted agent turn -----------------------------------------------------
async function runTurn(sessionID, text) {
  const messageID = nextId("msg");
  const part = (extra) => ({ id: nextId("prt"), sessionID, messageID, ...extra });
  emit("session.status", { sessionID, status: { type: "busy" } });
  await sleep(50);

  // one read tool, pending -> running -> completed
  const callID = nextId("call");
  const toolID = nextId("prt");
  emit("message.part.updated", { sessionID, part: { id: toolID, sessionID, messageID, type: "tool", callID, tool: "read", state: { status: "pending", input: {} } } });
  emit("message.part.updated", { sessionID, part: { id: toolID, sessionID, messageID, type: "tool", callID, tool: "read", state: { status: "running", input: { filePath: "README.md" }, time: { start: Date.now() } } } });
  await sleep(50);
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
    if (/schedule/i.test(body)) {
      const created = await mcpCall("schedule_create", { canopy_session_id: sessionID, when: "3s", what: "Run the scheduled check and report." });
      await mcpCall("message_send", { canopy_session_id: sessionID, text: "Scheduled it: " + created.split(".")[0] + "." });
      reply = "Scheduled.";
    } else {
      await mcpCall("message_send", { canopy_session_id: sessionID, text: "Acknowledged: looking into it now.\n\n1. Read `README.md`\n2. Check the queue\n\n```python\nqueue.add(invoice_id)\n```" });
    }
  }

  const textID = nextId("prt");
  emit("message.part.updated", { sessionID, part: part({ id: textID, type: "text", text: "", time: { start: Date.now() } }) });
  emit("message.part.delta", { sessionID, messageID, partID: textID, field: "text", delta: reply });
  emit("message.part.updated", { sessionID, part: part({ id: textID, type: "text", text: reply, time: { start: Date.now() - 10, end: Date.now() } }) });
  emit("message.updated", { info: { id: messageID, sessionID, role: "assistant", cost: 0.0012, tokens: { input: 100, output: 20 }, finish: "stop", time: { created: Date.now(), completed: Date.now() } } });
  emit("session.status", { sessionID, status: { type: "idle" } });
  emit("session.idle", { sessionID });
  void channel;
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
    if (req.method === "GET" && (m = p.match(/^\/session\/([^/]+)\/(children|message|diff)$/))) return json(res, 200, []);
    if (req.method === "GET" && (m = p.match(/^\/session\/([^/]+)$/))) return json(res, 200, { id: m[1], ...(sessions.get(m[1]) || {}) });
    json(res, 404, { error: `fake-opencode: no route for ${req.method} ${p}` });
  } catch (e) {
    console.error("[fake-opencode]", e);
    json(res, 500, { error: String(e) });
  }
});

server.listen(PORT, "127.0.0.1", () => console.log(`[fake-opencode] listening on http://127.0.0.1:${PORT}`));
