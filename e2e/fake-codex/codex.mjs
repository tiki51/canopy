// A deterministic stand-in for `codex app-server` in the browser tests, the way
// e2e/fake-claude/claude.mjs stands in for `claude -p`. Canopy spawns it once
// per turn exactly as it spawns Codex (see Canopy.Codex.Command): newline-
// delimited JSON-RPC on stdin/stdout, initialize → thread/start | thread/resume
// → turn/start → notifications until turn/completed, then stdin closes and it
// exits 0. Like Codex, its own messages omit "jsonrpc", and its server requests
// (approvals) carry ids counting from 0.
//
// It is also an MCP client: it calls Canopy's real MCP server at the url from
// `-c mcp_servers.canopy.url=…`, with the bearer token from the variable named
// by `-c mcp_servers.canopy.bearer_token_env_var=…`, so canopy_message_send and
// the other tools go through the same code a real agent uses. Each call is
// reported as an `mcpToolCall` item. An unreachable server is not fatal: the
// startup status says "failed", and the turn goes on (as Codex's does).
//
// The story is driven by whole words in the message text, the more specific
// first: "slow" streams its answer for ~5 s; "chain" asks to run `git status;
// ls`; "protect" asks to update <repo>/.codex/config.toml; "inrepo" asks to add
// <repo>/lib/x.ex; "both", "files" and "net" ask for more access (network and/or
// writing ~/.cache/tool); "run `cmd`" asks to run cmd (before "git", so "run
// `git push origin main`" runs that); "git" asks to run `git status`; "run" asks
// to run a command (with a network context, so the card shows the network badge); "edit"
// asks to change ~/.npmrc (outside the repo, an `update` diff); anything else is
// a short reply. Nothing is really run or written. Per-thread state (token
// totals, turns, who the agent is) lives in the OS temp dir, standing in for
// the rollout Codex keeps between processes.
//
//   FAKE_TURN_DELAY_MS   pause per step (default 50; the site specs use 2500)
//   FAKE_CODEX_VERSION   what --version prints and the thread reports (default 0.163.0)
//   FAKE_CODEX_ACCOUNT   chatgpt-pro (default) | chatgpt-plus | api_key | none
//   FAKE_CODEX_MODELS    "fail" answers model/list with a JSON-RPC error
//   FAKE_CODEX_DELAY_MS  delay before answering initialize, account/read and model/list
//   FAKE_CODEX_RESUME    "not_found" fails every thread/resume like a thread with no rollout
//   FAKE_CODEX_LOG       a file to append to, in test/support/fake_codex.sh's format: ARGV, ENV
//                        (names only), TOKEN_SHA256, CODEX_HOME, then "STDIN <line>" for every
//                        line Canopy sends, verbatim; also "STDOUT <json>" and "PROMPT <json>"
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";

const VERSION = process.env.FAKE_CODEX_VERSION || "0.163.0";
const ACCOUNT = process.env.FAKE_CODEX_ACCOUNT || "chatgpt-pro";
const TURN_DELAY = Number(process.env.FAKE_TURN_DELAY_MS || 50);
const REPLY_DELAY = Number(process.env.FAKE_CODEX_DELAY_MS || 0);
const LOG = process.env.FAKE_CODEX_LOG;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// One line per entry, "<TAG> <text>", as test/support/fake_codex.sh writes it.
const log = (tag, text) => {
  if (!LOG) return;
  try {
    fs.appendFileSync(LOG, `${tag} ${text}\n`);
  } catch {
    // debugging aid only
  }
};
const warn = (text) => process.stderr.write(`[fake-codex] ${text}\n`);

// ---- command line ------------------------------------------------------------
// `-c key=value` values are TOML; the ones read here are strings.
function tomlValue(raw) {
  if (raw.startsWith('"')) {
    try {
      return JSON.parse(raw);
    } catch {
      return raw.slice(1, -1);
    }
  }
  if (raw.startsWith("'") && raw.endsWith("'")) return raw.slice(1, -1);
  return raw;
}

function parseArgs(args) {
  const opts = { positional: [], config: {} };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "-c" || a === "--config") {
      const kv = args[++i] || "";
      const eq = kv.indexOf("=");
      if (eq > 0) opts.config[kv.slice(0, eq).trim()] = tomlValue(kv.slice(eq + 1).trim());
    } else if (a === "--listen") opts.listen = args[++i];
    else if (a.startsWith("--listen=")) opts.listen = a.slice(9);
    else if (!a.startsWith("-")) opts.positional.push(a);
  }
  return opts;
}

const argv = process.argv.slice(2);

if (argv[0] === "--version" || argv[0] === "-V") {
  console.log(`codex-cli ${VERSION}`);
  process.exit(0);
}
const opts = parseArgs(argv);
const [command, sub] = opts.positional;

if (command === "login" && sub === "status") {
  if (ACCOUNT === "none") {
    console.log("Not logged in");
    process.exit(1);
  }
  console.log(ACCOUNT === "api_key" ? "Logged in using an API key - sk-proj-***FAKE" : "Logged in using ChatGPT");
  process.exit(0);
}
if (command !== "app-server") {
  warn(`unsupported command: ${argv.join(" ")}`);
  process.exit(2);
}
if (opts.listen && opts.listen !== "stdio://") {
  warn(`only --listen stdio:// is faked, got ${opts.listen}`);
  process.exit(2);
}

const CODEX_HOME = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");

log("ARGV", argv.join(" "));
if (LOG) {
  log("ENV", Object.keys(process.env).filter((k) => /^(CANOPY_[A-Z_]*|CODEX_HOME)$/.test(k)).sort().join(" "));
  const token = process.env[opts.config["mcp_servers.canopy.bearer_token_env_var"] || "CANOPY_MCP_TOKEN"];
  if (token) log("TOKEN_SHA256", crypto.createHash("sha256").update(token).digest("hex"));
  if (process.env.CODEX_HOME) log("CODEX_HOME", process.env.CODEX_HOME);
}

// ---- JSON-RPC on stdio -----------------------------------------------------------
const send = (obj) => {
  log("STDOUT", JSON.stringify(obj));
  process.stdout.write(JSON.stringify(obj) + "\n");
};
const notify = (method, params) => send({ method, params, emittedAtMs: Date.now() });
const reply = (id, result) => send({ id, result });
const replyError = (id, code, message) => send({ error: { code, message }, id });

// Server requests (approvals): ids from 0, as Codex's are.
let serverRequestId = 0;
const waiting = new Map(); // id → resolve(result | {__error} | {__withdrawn})
function serverRequest(method, params) {
  const id = serverRequestId++;
  send({ method, id, params });
  return { id, answer: new Promise((resolve) => waiting.set(id, resolve)) };
}

// ---- ids ------------------------------------------------------------------------
function uuidv7() {
  const b = crypto.randomBytes(16);
  const ms = Date.now();
  b.writeUIntBE(ms, 0, 6);
  b[6] = (b[6] & 0x0f) | 0x70;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = b.toString("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}
const execId = () => `exec-${crypto.randomUUID()}`;
const msgId = () => `msg_fake_${crypto.randomBytes(16).toString("hex")}`;
const secs = () => Math.floor(Date.now() / 1000);

// ---- per-thread state -------------------------------------------------------------
const stateDir = path.join(os.tmpdir(), "canopy-fake-codex");
const stateFile = (threadId) => path.join(stateDir, `${threadId.replace(/[^\w-]/g, "_")}.json`);
const loadState = (threadId) => {
  try {
    return JSON.parse(fs.readFileSync(stateFile(threadId), "utf8"));
  } catch {
    return null;
  }
};
const saveState = (threadId, st) => {
  try {
    fs.mkdirSync(stateDir, { recursive: true });
    fs.writeFileSync(stateFile(threadId), JSON.stringify(st));
  } catch (e) {
    warn(`could not save thread state: ${e.message}`);
  }
};

const zeroUsage = () => ({ totalTokens: 0, inputTokens: 0, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0 });
const addUsage = (a, b) => Object.fromEntries(Object.keys(a).map((k) => [k, a[k] + b[k]]));
const CONTEXT_WINDOW = 258_400;

// Who this thread is for, from the collaboration prompt's first line ("… (@name), an AI coworker …").
const whoIn = (text) => (text || "").match(/\(@([\w-]+)\), an AI coworker/)?.[1] || null;

// ---- models and account ----------------------------------------------------------------
const EFFORTS = {
  low: "Fast responses with lighter reasoning",
  medium: "Balances speed and reasoning depth for everyday tasks",
  high: "Greater reasoning depth for complex problems",
  xhigh: "Extra high reasoning depth for complex problems",
  max: "Maximum reasoning depth for the hardest problems",
};
const model = (id, displayName, description, efforts, isDefault) => ({
  id,
  model: id,
  upgrade: null,
  upgradeInfo: null,
  availabilityNux: null,
  displayName,
  description,
  modelSpecialty: null,
  hidden: false,
  supportedReasoningEfforts: efforts.map((e) => ({ reasoningEffort: e, description: EFFORTS[e] })),
  defaultReasoningEffort: "medium",
  inputModalities: ["text", "image"],
  supportsPersonality: false,
  multiAgentVersion: null,
  additionalSpeedTiers: [],
  serviceTiers: [],
  defaultServiceTier: null,
  availableAccessPrograms: null,
  isDefault,
});
const MODELS = [
  model("gpt-5-codex", "GPT-5-Codex", "Optimized for agentic coding.", ["low", "medium", "high", "xhigh"], true),
  model("gpt-5", "GPT-5", "Broad world knowledge with strong general reasoning.", ["low", "medium", "high", "xhigh", "max"], false),
  model("gpt-5-codex-mini", "GPT-5-Codex-Mini", "Smaller, faster and cheaper coding model.", ["low", "medium", "high"], false),
];
const DEFAULT_MODEL = "gpt-5-codex";

function account() {
  if (ACCOUNT === "none") return { account: null, requiresOpenaiAuth: true };
  if (ACCOUNT === "api_key") return { account: { type: "apiKey" }, requiresOpenaiAuth: true };
  const planType = ACCOUNT === "chatgpt-plus" ? "plus" : "pro";
  return { account: { type: "chatgpt", email: "dev@example.com", planType }, requiresOpenaiAuth: true };
}

// ---- minimal MCP client (Streamable HTTP) -------------------------------------------
// node:http rather than fetch, as in fake-claude: a tool call can block for long.
const mcpUrl = opts.config["mcp_servers.canopy.url"] || null;
const tokenVar = opts.config["mcp_servers.canopy.bearer_token_env_var"];
const mcpToken = tokenVar ? process.env[tokenVar] : null;
let mcpSession = null;
let mcpRpcId = 0;
let mcpReady = null; // the initialize handshake, started at thread/start like Codex's

function mcpPost(body) {
  return new Promise((resolve, reject) => {
    const headers = { "content-type": "application/json", accept: "application/json, text/event-stream" };
    if (mcpToken) headers.authorization = `Bearer ${mcpToken}`;
    if (mcpSession) headers["mcp-session-id"] = mcpSession;
    const req = http.request(mcpUrl, { method: "POST", headers }, (res) => {
      const sessionHeader = res.headers["mcp-session-id"];
      if (sessionHeader) mcpSession = sessionHeader;
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8");
        if (res.statusCode >= 400) reject(new Error(`MCP HTTP ${res.statusCode}: ${text.slice(0, 200)}`));
        else resolve(text);
      });
      res.on("error", reject);
    });
    req.on("error", reject);
    req.end(JSON.stringify(body));
  });
}

async function mcpRpc(method, params, id) {
  const body = { jsonrpc: "2.0", method, params };
  if (id !== undefined) body.id = id;
  const text = await mcpPost(body);
  const lines = text.split("\n").filter((l) => l.startsWith("data:"));
  const messages = lines.length ? lines.map((l) => JSON.parse(l.slice(5))) : text.trim() ? [JSON.parse(text)] : [];
  return messages.find((m) => m.id === id);
}

function mcpConnect() {
  if (!mcpUrl) return Promise.reject(new Error("no mcp_servers.canopy.url"));
  mcpReady ||= (async () => {
    await mcpRpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "codex-mcp-client", version: VERSION } }, ++mcpRpcId);
    await mcpRpc("notifications/initialized", {});
  })().catch((e) => {
    mcpReady = null;
    throw e;
  });
  return mcpReady;
}

async function mcpCall(name, args = {}) {
  try {
    await mcpConnect();
    const res = await mcpRpc("tools/call", { name, arguments: args }, ++mcpRpcId);
    const text = (res?.result?.content || []).map((c) => c.text || "").join("\n");
    return { text, content: res?.result?.content || [], error: res?.error?.message || (res?.result?.isError ? text : null) };
  } catch (e) {
    warn(`MCP ${name} failed: ${e.message}`);
    return { text: "", content: [], error: e.message };
  }
}

// ---- threads ------------------------------------------------------------------------
let clientName = "codex_cli_rs";
let initialized = false;
const threads = new Map(); // id → { id, st, cwd, model, effort, approvalPolicy, approvalsReviewer, sandbox }
let activeTurn = null;

function sandboxPolicy(mode, cwd) {
  if (mode === "danger-full-access") return { type: "dangerFullAccess" };
  if (mode === "workspace-write")
    return { type: "workspaceWrite", writableRoots: [cwd], networkAccess: false, excludeTmpdirEnvVar: false, excludeSlashTmp: false };
  return { type: "readOnly", networkAccess: false };
}

function rolloutPath(id, createdAt) {
  const d = new Date(createdAt * 1000);
  const pad = (n) => String(n).padStart(2, "0");
  const day = `${d.getFullYear()}/${pad(d.getMonth() + 1)}/${pad(d.getDate())}`;
  const stamp = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}-${pad(d.getMinutes())}-${pad(d.getSeconds())}`;
  return path.join(CODEX_HOME, "sessions", day, `rollout-${stamp}-${id}.jsonl`);
}

function threadObject(t, { status = { type: "idle" }, turns = [] } = {}) {
  return {
    id: t.id,
    environments: [{ environmentId: "local", cwd: t.cwd, runtimeWorkspaceRoots: [t.cwd] }],
    extra: null,
    sessionId: t.id,
    forkedFromId: null,
    parentThreadId: null,
    preview: t.st.preview || "",
    ephemeral: false,
    section: null,
    sectionEnteredAt: null,
    projectId: null,
    historyMode: "paginated",
    modelProvider: "openai",
    model: t.model,
    reasoningEffort: t.effort || null,
    createdAt: t.st.createdAt,
    updatedAt: t.st.updatedAt || t.st.createdAt,
    recencyAt: t.st.createdAt,
    status,
    path: rolloutPath(t.id, t.st.createdAt),
    cwd: t.cwd,
    cliVersion: VERSION,
    originator: clientName,
    source: "vscode",
    canAcceptDirectInput: true,
    threadSource: null,
    agentNickname: null,
    agentRole: null,
    gitInfo: null,
    name: null,
    daybreakEnabled: null,
    turns,
  };
}

function threadResponse(t, extra = {}) {
  return {
    thread: threadObject(t),
    model: t.model,
    modelProvider: "openai",
    serviceTier: null,
    disabledPluginIds: [],
    cwd: t.cwd,
    runtimeWorkspaceRoots: [t.cwd],
    instructionSources: [],
    approvalPolicy: t.approvalPolicy,
    approvalsReviewer: t.approvalsReviewer,
    sandbox: sandboxPolicy(t.sandbox, t.cwd),
    activePermissionProfile: null,
    reasoningEffort: t.effort || null,
    multiAgentMode: "explicitRequestOnly",
    ...extra,
  };
}

function openThread(id, st, params) {
  const t = {
    id,
    st,
    cwd: params.cwd || process.cwd(),
    model: params.model || st.model || DEFAULT_MODEL,
    effort: params.effort || null,
    approvalPolicy: params.approvalPolicy || "on-request",
    approvalsReviewer: params.approvalsReviewer || "user",
    sandbox: params.sandbox || "read-only",
  };
  st.model = t.model;
  const me = whoIn(params.developerInstructions);
  if (me) st.me = me;
  threads.set(id, t);
  saveState(id, st);
  return t;
}

// Like Codex: the configured MCP servers start once the thread exists.
function startMcp(t) {
  if (!mcpUrl) return;
  const status = (s, error = null) =>
    notify("mcpServer/startupStatus/updated", { threadId: t.id, name: "canopy", status: s, error, failureReason: null });
  status("starting");
  mcpConnect().then(
    () => status("ready"),
    (e) => {
      warn(`MCP startup failed: ${e.message}`);
      status("failed", e.message);
    },
  );
}

// ---- turns -------------------------------------------------------------------------
class Ended extends Error {}

class Turn {
  constructor(thread, params) {
    this.thread = thread;
    this.params = params;
    this.id = uuidv7();
    this.startedAt = secs();
    this.startedMs = Date.now();
    this.ended = false;
    this.items = []; // every completed item, for thread/turns/list
    this.steered = [];
    this.openRequest = null; // { id, resolve }
    this.wake = null;
    this.duplicated = false;
    const st = thread.st;
    this.context = st.context || 15_000 + Math.floor(Math.random() * 1_000);
  }

  object(status = "inProgress", extra = {}) {
    return { id: this.id, rootTurnId: this.id, items: [], itemsView: "notLoaded", status, error: null, startedAt: this.startedAt, completedAt: null, durationMs: null, ...extra };
  }

  // Everything the story emits goes through here, so nothing leaks after an interrupt.
  emit(method, params) {
    if (this.ended) throw new Ended();
    notify(method, { ...params, threadId: this.thread.id, turnId: this.id });
  }

  started(item) {
    this.emit("item/started", { item, startedAtMs: Date.now() });
  }

  completed(item) {
    this.emit("item/completed", { item, completedAtMs: Date.now() });
    this.items.push(item);
  }

  step(factor = 1) {
    return this.pause(TURN_DELAY * factor);
  }

  // A pause a turn/interrupt cuts short (the story then stops with Ended).
  async pause(ms) {
    if (this.ended) throw new Ended();
    await new Promise((resolve) => {
      const timer = setTimeout(resolve, ms);
      this.wake = () => {
        clearTimeout(timer);
        resolve();
      };
    });
    this.wake = null;
    if (this.ended) throw new Ended();
  }

  // One model call's usage: `total` is the thread's running total, `last` this call.
  usage(produced = 60 + Math.floor(Math.random() * 240)) {
    const fresh = 200 + Math.floor(Math.random() * 400);
    const input = this.context + fresh;
    const reasoning = ["high", "xhigh", "max"].includes(this.params.effort || this.thread.effort) ? Math.floor(produced / 3) : 0;
    const last = {
      totalTokens: input + produced,
      inputTokens: input,
      cachedInputTokens: Math.floor(this.context / 128) * 128,
      cacheWriteInputTokens: 0,
      outputTokens: produced,
      reasoningOutputTokens: reasoning,
    };
    const st = this.thread.st;
    st.total = addUsage(st.total || zeroUsage(), last);
    st.last = last;
    st.lastTurnId = this.id;
    st.context = this.context = input + produced;
    st.updatedAt = secs();
    saveState(this.thread.id, st);
    const params = { tokenUsage: { total: st.total, last, modelContextWindow: CONTEXT_WINDOW } };
    this.emit("thread/tokenUsage/updated", params);
    // Codex sends the same update twice now and then (seen on a first turn).
    if (!this.duplicated) {
      this.duplicated = true;
      this.emit("thread/tokenUsage/updated", params);
    }
  }

  // A server request, then our client's answer (the result object).
  async ask(method, params) {
    if (this.ended) throw new Ended();
    const req = serverRequest(method, { threadId: this.thread.id, turnId: this.id, ...params });
    this.openRequest = req;
    const answer = await req.answer;
    this.openRequest = null;
    if (answer?.__withdrawn) throw new Ended();
    notify("serverRequest/resolved", { threadId: this.thread.id, requestId: req.id });
    if (answer?.__error) {
      warn(`${method} answered with an error: ${JSON.stringify(answer.__error)}`);
      return null;
    }
    return answer;
  }

  // An approval: the decision, "decline" when the answer has none.
  async decide(method, params) {
    const answer = await this.ask(method, params);
    return typeof answer?.decision === "string" ? answer.decision : "decline";
  }

  // item/permissions/requestApproval: more access for the rest of the turn or session.
  // Granted when the answer's `permissions` has anything in it.
  async permissions(permissions, reason) {
    const answer = await this.ask("item/permissions/requestApproval", {
      itemId: `call_${crypto.randomBytes(12).toString("hex")}`,
      environmentId: "local",
      startedAtMs: Date.now(),
      cwd: this.thread.cwd,
      reason,
      permissions,
    });
    const granted = answer?.permissions || {};
    await this.step();
    this.usage();
    return { granted: Object.values(granted).some((v) => v !== null && v !== undefined), answer };
  }

  async agentMessage(text, phase = "final_answer") {
    const item = { type: "agentMessage", id: msgId(), text: "", phase, memoryCitation: null, delivery: null, questions: null };
    this.started(item);
    for (const delta of text.match(/[\s\S]{1,80}/g) || []) {
      this.emit("item/agentMessage/delta", { itemId: item.id, delta });
    }
    this.completed({ ...item, text });
    this.usage();
    return item;
  }

  // A final answer streamed a word at a time, `every` ms apart (the "slow" story).
  async streamedMessage(words, every) {
    const item = { type: "agentMessage", id: msgId(), text: "", phase: "final_answer", memoryCitation: null, delivery: null, questions: null };
    this.started(item);
    let text = "";
    for (const [i, word] of words.entries()) {
      await this.pause(every);
      const delta = i === 0 ? word : ` ${word}`;
      text += delta;
      this.emit("item/agentMessage/delta", { itemId: item.id, delta });
    }
    this.completed({ ...item, text });
    this.usage();
  }

  // One of Canopy's own tools, through the real MCP server. Canopy's never ask.
  async canopy(tool, args = {}) {
    const item = {
      type: "mcpToolCall",
      id: execId(),
      server: "canopy",
      tool,
      status: "inProgress",
      arguments: args,
      appContext: null,
      mcpAppUi: null,
      pluginId: null,
      readOnlyHint: false,
      result: null,
      error: null,
      durationMs: null,
    };
    this.started(item);
    const t0 = Date.now();
    const res = await mcpCall(tool, args);
    await this.step(0.3);
    const done = res.error
      ? { ...item, status: "failed", error: { message: res.error }, durationMs: Date.now() - t0 }
      : { ...item, status: "completed", result: { content: res.content, structuredContent: null, _meta: null }, durationMs: Date.now() - t0 };
    this.completed(done);
    this.usage();
    return res;
  }

  // A shell command that asks first, as every command does under `untrusted`.
  async command(cmd, { output = "", reason = null, network = null, amendment = cmd.split(/\s+/).slice(0, 2) } = {}) {
    const item = {
      type: "commandExecution",
      id: execId(),
      pluginId: null,
      scriptPath: null,
      command: `/bin/zsh -lc '${cmd}'`,
      cwd: this.thread.cwd,
      processId: null,
      source: "agent",
      status: "inProgress",
      commandActions: [{ type: "unknown", command: cmd }],
      aggregatedOutput: null,
      exitCode: null,
      durationMs: null,
    };
    this.started(item);
    const params = {
      kind: "command",
      itemId: item.id,
      startedAtMs: Date.now(),
      environmentId: "local",
      reason,
      command: item.command,
      cwd: item.cwd,
      commandActions: item.commandActions,
      proposedExecpolicyAmendment: amendment,
      availableDecisions: amendment ? ["accept", { acceptWithExecpolicyAmendment: { execpolicy_amendment: amendment } }, "cancel"] : ["accept", "cancel"],
    };
    if (network) {
      params.networkApprovalContext = network;
      params.proposedNetworkPolicyAmendments = [{ host: network.host, action: "allow" }];
      params.availableDecisions.splice(2, 0, { applyNetworkPolicyAmendment: { network_policy_amendment: { host: network.host, action: "allow" } } });
    }
    const decision = await this.decide("item/commandExecution/requestApproval", params);
    if (decision === "accept" || decision === "acceptForSession") {
      const t0 = Date.now();
      await this.step();
      this.completed({ ...item, processId: String(10_000 + Math.floor(Math.random() * 50_000)), source: "unifiedExecStartup", status: "completed", aggregatedOutput: output, exitCode: 0, durationMs: Date.now() - t0 });
      this.usage();
      return { ran: true, decision };
    }
    this.completed({ ...item, status: "declined" });
    this.usage();
    return { ran: false, decision };
  }

  // A file change: the diff is on the item, the approval request carries none.
  async fileChange(changes, { reason = null } = {}) {
    const item = { type: "fileChange", id: execId(), changes, status: "inProgress" };
    this.started(item);
    const decision = await this.decide("item/fileChange/requestApproval", { itemId: item.id, startedAtMs: Date.now(), reason, grantRoot: null });
    const applied = decision === "accept" || decision === "acceptForSession";
    if (applied) await this.step();
    this.completed({ ...item, status: applied ? "completed" : "declined" });
    this.usage();
    return { applied, decision };
  }

  // The final answer, with any message steered in folded into it, then turn/completed.
  async finish(text, status = "completed") {
    for (const steered of this.steered) {
      const body = bodyOf(steered) || steered.trim();
      if (body) text = `${text}\n\nRe your message: “${body}”`;
    }
    if (text) await this.agentMessage(text);
    this.complete(status);
  }

  complete(status) {
    if (this.ended) throw new Ended();
    this.ended = true;
    const completedAt = secs();
    const final = this.items.filter((i) => i.type === "agentMessage" && i.phase === "final_answer").slice(-1);
    const turn = this.object(status, { items: final, itemsView: "summary", completedAt, durationMs: Date.now() - this.startedMs });
    notify("thread/status/changed", { threadId: this.thread.id, status: { type: "idle" } });
    notify("turn/completed", { threadId: this.thread.id, turn });
    const st = this.thread.st;
    st.turns = [...(st.turns || []), { ...turn, items: this.items }];
    st.updatedAt = completedAt;
    saveState(this.thread.id, st);
    if (activeTurn === this) activeTurn = null;
  }

  // turn/interrupt: a last usage update, the reply, then turn/completed "interrupted".
  interrupt(requestId) {
    if (this.openRequest) {
      notify("serverRequest/resolved", { threadId: this.thread.id, requestId: this.openRequest.id });
      const resolve = waiting.get(this.openRequest.id);
      waiting.delete(this.openRequest.id);
      resolve?.({ __withdrawn: true });
    }
    try {
      this.usage(10 + Math.floor(Math.random() * 30));
    } catch {
      // already ended
    }
    reply(requestId, {});
    this.complete("interrupted");
    this.wake?.();
  }
}

// ---- the story ----------------------------------------------------------------------
const bodyOf = (prompt) =>
  prompt.match(/Message text:\n([\s\S]*?)\n(?:Attachments on this message:|canopy_messages_read returns)/)?.[1]?.trim() ||
  prompt.match(/Message text:\n([\s\S]*?)\n\n/)?.[1]?.trim() ||
  "";
const textOf = (input) => (input || []).filter((i) => i.type === "text").map((i) => i.text).join("\n");

const NPMRC = path.join(os.homedir(), ".npmrc");
const NPMRC_DIFF = `@@ -1,2 +1,3 @@
 registry=https://registry.npmjs.org/
 fund=false
+save-exact=true
`;
const CONFIG_DIFF = `@@ -1,2 +1,3 @@
 model = "gpt-5-codex"
 approval_policy = "untrusted"
+sandbox_mode = "danger-full-access"
`;
const NPM_OUTPUT = "\nadded 1 package, and audited 214 packages in 2s\n\n38 packages are looking for funding\n  run `npm fund` for details\n\nfound 0 vulnerabilities\n";
const needsNetwork = (cmd) => /^(npm|pnpm|yarn) (install|i|add)\b|^curl\b|^pip install\b|^git (fetch|pull|push)\b/.test(cmd);

async function story(turn, prompt) {
  const me = turn.thread.st.me;
  const messageFrom = prompt.match(/new Canopy message in #\S+ from (.+?)\.\n/)?.[1];
  const body = bodyOf(prompt);
  log("PROMPT", JSON.stringify({ me, thread: turn.thread.id, prompt }));

  let m;
  if ((m = prompt.match(/Handoff ID: (ho_\S+)/))) {
    await turn.canopy("handoff_get", { handoff_id: m[1] });
    await turn.canopy("handoff_accept", { handoff_id: m[1] });
    await turn.canopy("message_send", { text: "Took over the task; reading the handoff and the working tree now." });
    return turn.finish("Accepted the handoff.");
  }
  if (/accepted your handoff/.test(prompt) || /Your delegated subtask/.test(prompt)) {
    await turn.canopy("pass", {});
    return turn.finish("Nothing to do.");
  }
  if (prompt.match(/Delegation ID: (dl_\S+)/)) {
    await turn.step();
    await turn.canopy("task_update", { status: "completed", result: "Done: see README.md." });
    return turn.finish("Delegated work finished.");
  }
  if (/A scheduled task of yours is due/.test(prompt)) {
    await turn.canopy("message_send", { text: "Ran the scheduled check: all green." });
    return turn.finish("Scheduled check done.");
  }
  if (!messageFrom) return turn.finish("Nothing to do.");
  if (messageFrom.startsWith("@")) {
    // another agent's post that needs nothing from this one
    await turn.canopy("pass", {});
    return turn.finish("Nothing to add.");
  }

  const word = (w) => new RegExp(`\\b${w}\\b`, "i").test(body);

  // The more specific keywords first, so "chain" never also counts as "git".
  // "slow": the answer streams for about 5 s, so a spec can stop it midway.
  if (word("slow")) {
    const words = "Working through it slowly: reading the code, checking each caller, and writing up what I find so you can stop me at any point along the way.".split(" ");
    await turn.streamedMessage(words, 5000 / words.length);
    return turn.complete("completed");
  }

  // "chain" and "git": `git status; ls` always gets a card; `git status` is
  // the read-only git Canopy answers itself in ask-first mode.
  const gitStory = async (cmd, amendment) => {
    const ran = await turn.command(cmd, { output: "On branch main\nnothing to commit, working tree clean\n", amendment });
    if (ran.decision === "cancel") return turn.complete("interrupted");
    await turn.canopy("message_send", { text: ran.ran ? `Ran ${cmd}` : `Didn't run ${cmd}` });
    return turn.finish(ran.ran ? "Ran the command." : "The command was declined.");
  };
  if (word("chain")) return gitStory("git status; ls", null);

  // "protect" and "inrepo": file changes inside the repository, one to a
  // protected path (always a card), one Canopy accepts itself in ask-first mode.
  const fileStory = async (rel, kind, diff) => {
    const changed = await turn.fileChange([{ path: path.join(turn.thread.cwd, rel), kind, diff }]);
    if (changed.decision === "cancel") return turn.complete("interrupted");
    await turn.canopy("message_send", { text: changed.applied ? `Changed ${rel}` : `Left ${rel} alone` });
    return turn.finish(changed.applied ? `Changed ${rel}.` : "The change was declined.");
  };
  if (word("protect")) return fileStory(".codex/config.toml", { type: "update", move_path: null }, CONFIG_DIFF);
  if (word("inrepo")) return fileStory("lib/x.ex", { type: "add" }, "defmodule X do\nend\n");

  // "both", "files", "net": more access through item/permissions/requestApproval.
  const accessStory = async (permissions, reason) => {
    const { granted } = await turn.permissions(permissions, reason);
    await turn.canopy("message_send", { text: granted ? "Got access" : "No access" });
    return turn.finish(granted ? "Got the access I asked for." : "The access was refused.");
  };
  const CACHE = path.join(os.homedir(), ".cache", "tool");
  if (word("both")) return accessStory({ network: { enabled: true }, fileSystem: { read: null, write: [CACHE] } }, "needs network and write access to ~/.cache/tool");
  if (word("files")) return accessStory({ network: null, fileSystem: { read: null, write: [CACHE] } }, "needs write access to ~/.cache/tool");
  if (word("net")) return accessStory({ network: { enabled: true }, fileSystem: null }, "needs network");

  // "run" (optionally "run `cmd`"): a command that asks first, with a network context.
  const runStory = async (cmd) => {
    const network = needsNetwork(cmd) ? { host: "registry.npmjs.org", protocol: "https" } : null;
    await turn.agentMessage(`I'll run \`${cmd}\`.`, "commentary");
    const ran = await turn.command(cmd, { output: needsNetwork(cmd) ? NPM_OUTPUT : "ok\n", reason: network ? "needs network access" : null, network });
    if (ran.decision === "cancel") return turn.complete("interrupted");
    await turn.canopy("message_send", { text: ran.ran ? `Ran \`${cmd}\`.` : `Didn't run \`${cmd}\`.` });
    return turn.finish(ran.ran ? "Ran the command." : "The command was declined.");
  };
  // "run `cmd`" names its command, so it wins over "git": "run `git push
  // origin main`" is a git command no Always can cover (a card without Always).
  const named = body.match(/\brun `([^`]+)`/i)?.[1];
  if (named) return runStory(named);

  if (word("git")) return gitStory("git status", ["git", "status"]);

  if (/\brun\b/i.test(body)) return runStory("npm install csv-stringify");

  // "edit": a change to ~/.npmrc, outside the repository.
  if (/\bedit\b/i.test(body)) {
    await turn.agentMessage("I'll add `save-exact=true` to `~/.npmrc`.", "commentary");
    const changed = await turn.fileChange([{ path: NPMRC, kind: { type: "update", move_path: null }, diff: NPMRC_DIFF }], {
      reason: "needs to write outside the workspace",
    });
    if (changed.decision === "cancel") return turn.complete("interrupted");
    await turn.canopy("message_send", {
      text: changed.applied ? "Updated `~/.npmrc`: added `save-exact=true`." : "Left `~/.npmrc` alone: the edit was not approved.",
    });
    return turn.finish(changed.applied ? "Edited ~/.npmrc." : "The edit was declined.");
  }

  await turn.step();
  await turn.canopy("message_send", { text: "Acknowledged: looking into it now." });
  return turn.finish("Replied.");
}

async function runTurn(turn) {
  const prompt = textOf(turn.params.input);
  const st = turn.thread.st;
  if (!st.preview) st.preview = prompt.slice(0, 200);
  try {
    // Codex sends turn/started and the user's message before the model starts.
    notify("thread/status/changed", { threadId: turn.thread.id, status: { type: "active", activeFlags: [] } });
    notify("turn/started", { threadId: turn.thread.id, turn: turn.object() });
    const user = { type: "userMessage", id: uuidv7(), clientId: turn.params.clientUserMessageId ?? null, content: turn.params.input || [] };
    turn.started(user);
    turn.completed(user);
    await turn.step();
    await story(turn, prompt);
  } catch (e) {
    if (e instanceof Ended) return;
    warn(e.stack || String(e));
    if (!turn.ended) {
      turn.ended = true;
      const error = { message: String(e.message || e), codexErrorInfo: "other", additionalDetails: null, misalignment: null };
      notify("error", { threadId: turn.thread.id, turnId: turn.id, error, willRetry: false });
      notify("turn/completed", { threadId: turn.thread.id, turn: turn.object("failed", { error, completedAt: secs() }) });
      if (activeTurn === turn) activeTurn = null;
    }
  }
}

// ---- request handlers ---------------------------------------------------------------
const handlers = {
  async initialize(params) {
    clientName = params?.clientInfo?.name || clientName;
    initialized = true;
    if (REPLY_DELAY) await sleep(REPLY_DELAY);
    const version = params?.clientInfo?.version || "0";
    return {
      userAgent: `${clientName}/${VERSION} (Mac OS 15.5.0; arm64) vscode/1.108.1 (${clientName}; ${version})`,
      codexHome: CODEX_HOME,
      platformFamily: "unix",
      platformOs: "macos",
    };
  },

  async "account/read"() {
    if (REPLY_DELAY) await sleep(REPLY_DELAY);
    return account();
  },

  async "model/list"(params) {
    if (REPLY_DELAY) await sleep(REPLY_DELAY);
    if (process.env.FAKE_CODEX_MODELS === "fail") throw { code: -32603, message: "failed to load models: fake failure" };
    const start = Number(params?.cursor || 0);
    const limit = params?.limit || MODELS.length;
    const data = MODELS.slice(start, start + limit);
    return { data, nextCursor: start + limit < MODELS.length ? String(start + limit) : null };
  },

  "thread/start"(params, id) {
    const threadId = uuidv7();
    const t = openThread(threadId, { createdAt: secs(), total: zeroUsage(), turns: [] }, params || {});
    reply(id, threadResponse(t));
    notify("thread/started", { thread: threadObject(t) });
    startMcp(t);
  },

  "thread/resume"(params, id) {
    const threadId = params?.threadId;
    if (!threadId) throw { code: -32600, message: "threadId is required" };
    if (process.env.FAKE_CODEX_RESUME === "not_found") throw { code: -32600, message: `no rollout found for thread id ${threadId}` };
    // No disk state across machines: any id resumes, with invented earlier totals if unknown.
    let st = loadState(threadId);
    if (!st) {
      const restored = { totalTokens: 15_931, inputTokens: 15_926, cachedInputTokens: 12_544, cacheWriteInputTokens: 0, outputTokens: 5, reasoningOutputTokens: 0 };
      st = { createdAt: secs() - 600, total: restored, last: restored, lastTurnId: uuidv7(), context: restored.totalTokens, turns: [] };
    }
    const t = openThread(threadId, st, params);
    reply(id, threadResponse(t, { collaborationMode: null, turnsBackwardsCursor: null, itemsBackwardsCursor: null }));
    // Right after resume Codex replays the totals, under the previous turn's id.
    if (st.lastTurnId && st.total) {
      notify("thread/tokenUsage/updated", {
        threadId,
        turnId: st.lastTurnId,
        tokenUsage: { total: st.total, last: st.last || st.total, modelContextWindow: CONTEXT_WINDOW },
      });
    }
    startMcp(t);
  },

  "thread/inject_items"(params) {
    const t = threads.get(params?.threadId);
    if (!t) throw { code: -32600, message: `thread not found: ${params?.threadId}` };
    for (const item of params.items || []) {
      const me = whoIn((item.content || []).map((c) => c.text || "").join("\n"));
      if (me) t.st.me = me;
    }
    saveState(t.id, t.st);
    return {};
  },

  "turn/start"(params, id) {
    const t = threads.get(params?.threadId);
    if (!t) throw { code: -32600, message: `thread not found: ${params?.threadId}` };
    if (activeTurn && !activeTurn.ended) throw { code: -32600, message: "a turn is already in progress" };
    if (params.model) t.model = t.st.model = params.model;
    if (params.effort) t.effort = params.effort;
    if (params.approvalPolicy) t.approvalPolicy = params.approvalPolicy;
    const turn = new Turn(t, params);
    activeTurn = turn;
    reply(id, { turn: turn.object("inProgress", { startedAt: null }) });
    runTurn(turn);
  },

  "turn/interrupt"(params, id) {
    const turn = activeTurn;
    if (!turn || turn.ended || turn.id !== params?.turnId) {
      // Codex gives no response at all to an interrupt after the turn ended.
      warn(`turn/interrupt for ${params?.turnId}: no active turn; not answering`);
      return;
    }
    turn.interrupt(id);
  },

  "turn/steer"(params, id) {
    const turn = activeTurn;
    if (!turn || turn.ended) throw { code: -32600, message: "no active turn to steer" };
    if (params?.expectedTurnId !== turn.id) throw { code: -32600, message: `expected active turn id \`${params?.expectedTurnId}\` but found \`${turn.id}\`` };
    reply(id, { turnId: turn.id });
    const item = { type: "userMessage", id: uuidv7(), clientId: params.clientUserMessageId ?? null, content: params.input || [] };
    turn.started(item);
    turn.completed(item);
    turn.steered.push(textOf(params.input));
  },

  "thread/read"(params) {
    const id = params?.threadId;
    const st = threads.get(id)?.st || loadState(id);
    if (!st) throw { code: -32600, message: `no rollout found for thread id ${id}` };
    const t = threads.get(id) || { id, st, cwd: process.cwd(), model: st.model || DEFAULT_MODEL };
    return { thread: threadObject(t, { status: { type: threads.has(id) ? "idle" : "notLoaded" }, turns: params.includeTurns ? t.st.turns || [] : [] }) };
  },

  "thread/turns/list"(params) {
    const st = threads.get(params?.threadId)?.st || loadState(params?.threadId) || { turns: [] };
    const view = params.itemsView || "summary";
    let turns = (st.turns || []).map((turn) => {
      if (view === "notLoaded") return { ...turn, items: [], itemsView: "notLoaded" };
      if (view === "full") return { ...turn, itemsView: "full" };
      const summary = turn.items.filter((i) => i.type === "userMessage" || (i.type === "agentMessage" && i.phase === "final_answer"));
      return { ...turn, items: summary, itemsView: "summary" };
    });
    if ((params.sortDirection || "desc") === "desc") turns = turns.reverse();
    const start = Number(params.cursor || 0);
    const limit = params.limit || 25;
    const data = turns.slice(start, start + limit);
    return { data, nextCursor: start + limit < turns.length ? String(start + limit) : null, backwardsCursor: data.length ? String(start) : null };
  },

  "thread/items/list"(params) {
    const st = threads.get(params?.threadId)?.st || loadState(params?.threadId) || { turns: [] };
    let entries = (st.turns || []).flatMap((turn) => turn.items.map((item) => ({ turnId: turn.id, item, startedAtMs: turn.startedAt * 1000, completedAtMs: (turn.completedAt || turn.startedAt) * 1000 })));
    if (params.sortDirection === "desc") entries = entries.reverse();
    const start = Number(params.cursor || 0);
    const limit = params.limit || 50;
    const data = entries.slice(start, start + limit);
    return { data, nextCursor: start + limit < entries.length ? String(start + limit) : null, backwardsCursor: data.length ? String(start) : null };
  },
};

async function onRequest(msg) {
  const handler = handlers[msg.method];
  if (!handler) return replyError(msg.id, -32601, `method not found: ${msg.method}`);
  if (!initialized && msg.method !== "initialize") return replyError(msg.id, -32600, "Not initialized");
  try {
    const result = await handler(msg.params || {}, msg.id);
    // handlers that answer themselves (to order notifications after the reply) return nothing
    if (result !== undefined) reply(msg.id, result);
  } catch (e) {
    if (e && typeof e.code === "number") replyError(msg.id, e.code, e.message);
    else {
      warn(e?.stack || String(e));
      replyError(msg.id, -32603, String(e?.message || e));
    }
  }
}

let requests = Promise.resolve();
function onLine(line) {
  log("STDIN", line);
  if (!line.trim()) return;
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    warn(`not JSON: ${line.slice(0, 200)}`);
    return;
  }
  // Requests are answered in order (an async handler must not let a later one overtake it).
  if (msg.method && msg.id !== undefined) {
    requests = requests.then(() => onRequest(msg));
    return;
  }
  if (msg.method) return; // a notification, e.g. `initialized`
  if (msg.id !== undefined) {
    // our client's answer to a server request
    const resolve = waiting.get(msg.id);
    waiting.delete(msg.id);
    if (resolve) resolve(msg.error ? { __error: msg.error } : msg.result);
    else warn(`response to unknown server request ${msg.id}`);
  }
}

// ---- stdio loop ----------------------------------------------------------------------
let buf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buf += chunk;
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl);
    buf = buf.slice(nl + 1);
    onLine(line);
  }
});
// stdin closed: exit 0, mid-turn too (Codex does, with no turn/completed).
process.stdin.on("end", () => {
  if (buf.trim()) onLine(buf);
  log("EOF", "stdin closed");
  process.stdout.write("", () => process.exit(0));
});
