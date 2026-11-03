// The e2e fake `gh`: answers exactly the calls Canopy.Playbooks.Sharing.Remote.GH
// makes (`gh --version`, `gh auth status`, `gh api -i ...`), from a repository
// kept in a plain directory, so a spec arranges GitHub by writing files.
//
// $FAKE_GH_REPO_DIR is the repository, for any owner/name, on branch `main`:
// `<dir>/<folder>/*.md` are its files. Without it every `gh api` call is a 404.
// State lives in `<dir>/.fake-gh/`:
//   config.json  read on every call, so a spec can flip it per test:
//                {"push": false, "fail": "auth" | "repo" | "pulls" | <step>,
//                 "delay": {<step>: ms}, "default_branch": "main"}
//                (FAKE_GH_PUSH=0 and FAKE_GH_FAIL=<step> are the defaults)
//   prs.json     the opened pull requests, numbered from 1:
//                [{number, title, head, base, body, files: {path: text}, state}]
//                A spec merges one by setting `state` to "merged"; the next read
//                of that PR writes its files into the directory, as GitHub would.
//   git.json     trees, commits and refs that exports created; `deleted` lists
//                the refs Canopy deleted after a failed export.
// Steps (for "fail" and "delay"): user, repo, contents, branches, blobs,
// commits, ref, git-commit, trees, git-commits, refs, pulls, pull, delete-ref.
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

const args = process.argv.slice(2);
const repoDir = process.env.FAKE_GH_REPO_DIR || "";
const stateDir = repoDir && path.join(repoDir, ".fake-gh");

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return fallback;
  }
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2));
  fs.renameSync(tmp, file);
}

function config() {
  const env = {
    push: process.env.FAKE_GH_PUSH !== "0",
    fail: process.env.FAKE_GH_FAIL || null,
    delay: {},
    default_branch: "main",
  };
  return { ...env, ...(stateDir ? readJson(path.join(stateDir, "config.json"), {}) : {}) };
}

const sha1 = (text) => crypto.createHash("sha1").update(text).digest("hex");
const blobSha = (text) => sha1(Buffer.concat([Buffer.from(`blob ${Buffer.byteLength(text)}\0`), Buffer.from(text)]));

// synchronous, so process.exit never cuts a long answer short (stdout to a
// pipe is asynchronous on macOS)
function out(text, code = 0) {
  const buffer = Buffer.from(text);
  let offset = 0;
  while (offset < buffer.length) {
    try {
      offset += fs.writeSync(1, buffer, offset);
    } catch (e) {
      if (e.code !== "EAGAIN") throw e;
    }
  }
  process.exit(code);
}

const signedOut =
  "You are not logged into any GitHub hosts. To log in, run: gh auth login\n";

// -- gh --version / gh auth status -----------------------------------------------

if (args[0] === "--version" || args[0] === "version") {
  out("gh version 2.62.0 (2024-11-14)\nhttps://github.com/cli/cli/releases/tag/v2.62.0\n");
}

if (args[0] === "auth" && args[1] === "status") {
  if (config().fail === "auth") out(signedOut, 1);
  out(
    "github.com\n  ✓ Logged in to github.com account e2e-user (keyring)\n  - Active account: true\n  - Git operations protocol: https\n",
  );
}

if (args[0] !== "api") out(`unknown command "${args[0]}" for "gh" (e2e fake)\n`, 1);

// -- gh api -i [-X M] [-H h] [--input f] path ---------------------------------------

let method = "GET";
let input = null;
const headers = {};
let target = null;
for (let i = 1; i < args.length; i++) {
  const a = args[i];
  if (a === "-X" || a === "--method") method = args[++i].toUpperCase();
  else if (a === "-H" || a === "--header") {
    const [k, ...v] = args[++i].split(":");
    headers[k.trim().toLowerCase()] = v.join(":").trim();
  } else if (a === "--input") input = JSON.parse(fs.readFileSync(args[++i], "utf8"));
  else if (a.startsWith("-")) continue;
  else target = a;
}

const url = new URL(target, "https://api.github.com/");
const route = url.pathname.replace(/^\//, "");
const query = url.searchParams;

const reasons = { 200: "OK", 201: "Created", 204: "No Content", 304: "Not Modified", 404: "Not Found", 422: "Unprocessable Entity", 502: "Bad Gateway" };

function respond(status, body, extra = {}) {
  const head = [`HTTP/2.0 ${status} ${reasons[status] || ""}`, "Content-Type: application/json; charset=utf-8"];
  for (const [k, v] of Object.entries(extra)) head.push(`${k}: ${v}`);
  let text = `${head.join("\n")}\n\n`;
  if (body !== undefined) text += JSON.stringify(body);
  if (status >= 300) {
    const message = (body && body.message) || `HTTP ${status}`;
    text += status === 304 ? "\ngh: HTTP 304\n" : `\ngh: ${message} (HTTP ${status})\n`;
    out(text, 1);
  }
  out(`${text}\n`);
}

const notFound = () => respond(404, { message: "Not Found", status: "404" });

if (!repoDir) notFound();

const cfg = config();
const git = readJson(path.join(stateDir, "git.json"), { trees: {}, commits: {}, refs: {}, deleted: [] });
const saveGit = () => writeJson(path.join(stateDir, "git.json"), git);
const prsFile = path.join(stateDir, "prs.json");
const mainSha = sha1("commit main");

// the files on main: every file under the directory but .fake-gh, by path
function mainFiles() {
  const files = {};
  const walk = (dir, prefix) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (entry.name === ".fake-gh") continue;
      const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.isDirectory()) walk(path.join(dir, entry.name), rel);
      else if (entry.isFile()) files[rel] = fs.readFileSync(path.join(dir, entry.name), "utf8");
    }
  };
  if (fs.existsSync(repoDir)) walk(repoDir, "");
  return files;
}

function branchFiles(branch) {
  if (branch === cfg.default_branch) return mainFiles();
  const commit = git.refs[`refs/heads/${branch}`];
  if (!commit) return null;
  return { ...mainFiles(), ...git.trees[git.commits[commit].tree].files };
}

// which step a request is, for "fail" and "delay"
function step() {
  const r = route.replace(/^repos\/[^/]+\/[^/]+/, "");
  if (route === "user") return "user";
  if (r === "") return "repo";
  if (r.startsWith("/contents")) return "contents";
  if (r.startsWith("/branches/")) return "branches";
  if (r.startsWith("/git/blobs/")) return "blobs";
  if (r === "/commits") return "commits";
  if (r.startsWith("/git/ref/heads/")) return "ref";
  if (r.startsWith("/git/commits/")) return "git-commit";
  if (r === "/git/trees") return "trees";
  if (r === "/git/commits") return "git-commits";
  if (r === "/git/refs") return "refs";
  if (method === "DELETE" && r.startsWith("/git/refs/")) return "delete-ref";
  if (r === "/pulls") return "pulls";
  if (r.startsWith("/pulls/")) return "pull";
  return "other";
}

const current = step();
const delay = (cfg.delay || {})[current];
if (delay) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, delay);

if (cfg.fail === "auth") out(`To get started with GitHub CLI, please run:  gh auth login\n`, 4);
if (cfg.fail === current) {
  if (current === "repo") notFound();
  if (current === "pulls")
    respond(422, {
      message: "Validation Failed",
      errors: [{ resource: "PullRequest", code: "custom", message: "The e2e fake was told to fail pulls." }],
      status: "422",
    });
  respond(502, { message: `The e2e fake was told to fail ${current}.`, status: "502" });
}

const m = route.match(/^repos\/([^/]+\/[^/]+)(\/.*)?$/);
if (!m && current !== "user") notFound();
const repo = m && m[1];
const rest = (m && m[2]) || "";

switch (current) {
  case "user":
    respond(200, { login: "e2e-user" });

  case "repo":
    respond(200, {
      full_name: repo,
      default_branch: cfg.default_branch,
      permissions: { admin: false, maintain: false, push: cfg.push !== false, triage: true, pull: true },
    });

  case "contents": {
    const folder = decodeURIComponent(rest.replace(/^\/contents\/?/, ""));
    const files = branchFiles(query.get("ref") || cfg.default_branch);
    if (!files) notFound();
    const prefix = folder ? `${folder}/` : "";
    const entries = new Map();
    for (const [p, text] of Object.entries(files)) {
      if (!p.startsWith(prefix)) continue;
      const [name, ...deeper] = p.slice(prefix.length).split("/");
      if (deeper.length) entries.set(name, { name, path: prefix + name, sha: sha1(`dir ${prefix}${name}`), size: 0, type: "dir" });
      else entries.set(name, { name, path: p, sha: blobSha(text), size: Buffer.byteLength(text), type: "file" });
    }
    if (folder && entries.size === 0) notFound();
    const listing = [...entries.values()].sort((a, b) => a.path.localeCompare(b.path));
    const etag = `W/"${sha1(JSON.stringify(listing))}"`;
    if (headers["if-none-match"] === etag) respond(304, undefined, { Etag: etag });
    respond(200, listing, { Etag: etag });
  }

  case "branches": {
    const branch = decodeURIComponent(rest.replace(/^\/branches\//, ""));
    if (!branchFiles(branch)) notFound();
    respond(200, { name: branch, commit: { sha: branch === cfg.default_branch ? mainSha : git.refs[`refs/heads/${branch}`] } });
  }

  case "blobs": {
    const sha = rest.replace(/^\/git\/blobs\//, "");
    const texts = [
      ...Object.values(mainFiles()),
      ...Object.values(git.trees).flatMap((t) => Object.values(t.files)),
      ...readJson(prsFile, []).flatMap((pr) => Object.values(pr.files || {})),
    ];
    const text = texts.find((t) => blobSha(t) === sha);
    if (text === undefined) notFound();
    respond(200, { sha, size: Buffer.byteLength(text), encoding: "base64", content: Buffer.from(text).toString("base64") });
  }

  case "commits": {
    const file = path.join(repoDir, query.get("path") || "");
    if (!query.get("path") || !fs.existsSync(file)) respond(200, []);
    const date = fs.statSync(file).mtime.toISOString().replace(/\.\d+Z$/, "Z");
    respond(200, [{ sha: mainSha, commit: { author: { name: "E2E User", date } }, author: { login: "e2e-user" } }]);
  }

  case "ref": {
    const branch = decodeURIComponent(rest.replace(/^\/git\/ref\/heads\//, ""));
    const sha = branch === cfg.default_branch ? mainSha : git.refs[`refs/heads/${branch}`];
    if (!sha) notFound();
    respond(200, { ref: `refs/heads/${branch}`, object: { sha, type: "commit" } });
  }

  case "git-commit": {
    const sha = rest.replace(/^\/git\/commits\//, "");
    const tree = sha === mainSha ? sha1("tree main") : git.commits[sha] && git.commits[sha].tree;
    if (!tree) notFound();
    respond(200, { sha, tree: { sha: tree } });
  }

  case "trees": {
    const files = Object.fromEntries((input.tree || []).map((e) => [e.path, e.content]));
    const sha = sha1(`tree ${input.base_tree} ${JSON.stringify(files)}`);
    git.trees[sha] = { base: input.base_tree, files };
    saveGit();
    respond(201, { sha });
  }

  case "git-commits": {
    if (!git.trees[input.tree]) respond(422, { message: "Tree SHA does not exist", status: "422" });
    const sha = sha1(`commit ${input.tree} ${input.message} ${Date.now()} ${Math.random()}`);
    git.commits[sha] = { tree: input.tree, message: input.message, parents: input.parents };
    saveGit();
    respond(201, { sha });
  }

  case "refs": {
    const exists = input.ref === `refs/heads/${cfg.default_branch}` || git.refs[input.ref];
    if (exists) respond(422, { message: "Reference already exists", status: "422" });
    if (!git.commits[input.sha]) respond(422, { message: "Object does not exist", status: "422" });
    git.refs[input.ref] = input.sha;
    saveGit();
    respond(201, { ref: input.ref, object: { sha: input.sha, type: "commit" } });
  }

  case "delete-ref": {
    const ref = `refs/${decodeURIComponent(rest.replace(/^\/git\/refs\//, ""))}`;
    if (!git.refs[ref]) respond(422, { message: "Reference does not exist", status: "422" });
    delete git.refs[ref];
    git.deleted.push(ref);
    saveGit();
    out("HTTP/2.0 204 No Content\n\n");
  }

  case "pulls": {
    if (method !== "POST") notFound();
    const commit = git.refs[`refs/heads/${input.head}`];
    if (!commit) respond(422, { message: "Validation Failed", errors: [{ message: `No commits between ${input.base} and ${input.head}` }], status: "422" });
    const prs = readJson(prsFile, []);
    if (prs.some((pr) => pr.head === input.head && pr.state === "open"))
      respond(422, { message: "Validation Failed", errors: [{ message: `A pull request already exists for ${input.head}.` }], status: "422" });
    const number = prs.length + 1;
    prs.push({
      number,
      title: input.title,
      head: input.head,
      base: input.base,
      body: input.body,
      files: git.trees[git.commits[commit].tree].files,
      state: "open",
    });
    writeJson(prsFile, prs);
    respond(201, { number, html_url: `https://github.com/${repo}/pull/${number}`, state: "open", merged: false });
  }

  case "pull": {
    const number = Number(rest.replace(/^\/pulls\//, ""));
    const prs = readJson(prsFile, []);
    const pr = prs.find((p) => p.number === number);
    if (!pr) notFound();
    if (pr.state === "merged" && !pr.applied) {
      for (const [p, text] of Object.entries(pr.files || {})) {
        fs.mkdirSync(path.dirname(path.join(repoDir, p)), { recursive: true });
        fs.writeFileSync(path.join(repoDir, p), text);
      }
      pr.applied = true;
      writeJson(prsFile, prs);
    }
    respond(200, {
      number,
      html_url: `https://github.com/${repo}/pull/${number}`,
      state: pr.state === "open" ? "open" : "closed",
      merged: pr.state === "merged",
    });
  }

  default:
    notFound();
}
