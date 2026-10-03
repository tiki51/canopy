import { test, expect } from "@playwright/test";
// The palette's matcher has no DOM access, so it runs here in Node: the repo
// has no JS unit runner (see composer-tokens.spec.ts).
import { score, rank, tokenScore, EXACT, PREFIX, BOUNDARY, SUBSTRING, SUBSEQUENCE } from "../../assets/js/command_palette/match.js";
import { commands } from "../../assets/js/command_palette/commands.js";

const channel = (id: string, name: string, repo: string, extra: Record<string, unknown> = {}) => ({
  key: `channel:${id}`,
  channelId: id,
  repoId: repo,
  fields: [name, repo, `${repo}/${name}`],
  name,
  ...extra,
});

test.describe("command palette matcher", () => {
  test("exact beats prefix beats word start beats substring beats letters in order", () => {
    expect(tokenScore("pay", "pay")).toBe(EXACT);
    expect(tokenScore("pay", "payments")).toBe(PREFIX);
    expect(tokenScore("pay", "card-payments")).toBe(BOUNDARY);
    expect(tokenScore("pay", "repay")).toBe(SUBSTRING);
    const loose = tokenScore("pay", "p-a-y")!;
    expect(loose).toBeGreaterThanOrEqual(SUBSEQUENCE);
    expect(loose).toBeLessThan(SUBSTRING);
    // letters that sit together score higher than scattered ones
    expect(tokenScore("pay", "pa-y")!).toBeGreaterThan(loose);
    expect(score("PAY", ["Payments"])).toBe(PREFIX);
    // letters in order count in the name only, not in a role or keywords
    expect(score("pay", ["copywriter", "Writes product, marketing, and interface copy"])).toBeNull();
    expect(score("pay", ["p-a-y", "anything"])).toBe(SUBSEQUENCE);
    expect(score("eng", ["backend", "Backend engineer"])).toBe(BOUNDARY);
  });

  test("no match is null, and every token must match some field", () => {
    expect(tokenScore("xyz", "payments")).toBeNull();
    expect(score("xyz", ["payments", "acme"])).toBeNull();

    const items = [channel("1", "payment-retries", "acme"), channel("2", "payments-api", "billing")];
    expect(rank(items, "acme pay").map(r => r.item.name)).toEqual(["payment-retries"]);
    expect(rank(items, "pay").map(r => r.item.name)).toEqual(["payment-retries", "payments-api"]);
    expect(rank(items, "acme/pay").map(r => r.item.name)).toEqual(["payment-retries"]);
  });

  test("a recent item outranks a slightly better match; archived and the current channel sink", () => {
    const items = [channel("1", "card-payments", "acme"), channel("2", "repay-flow", "acme")];
    // word start (600) beats substring (400)...
    expect(rank(items, "pay")[0].item.name).toBe("card-payments");
    // ...until the substring match was visited last
    expect(rank(items, "pay", { recents: ["channel:2"] })[0].item.name).toBe("repay-flow");

    // a prefix match (800) that is archived falls below a word-start one (600)
    const archived = [channel("3", "pay-v1", "acme", { archived: true }), channel("4", "card-pay", "acme")];
    expect(rank(archived, "pay")[0].item.name).toBe("card-pay");

    const here = [channel("5", "payments", "acme"), channel("6", "payroll", "acme")];
    expect(rank(here, "pay", { context: { channel_id: "5" } })[0].item.name).toBe("payroll");

    // cards waiting and the current repository lift a row
    const busy = [channel("7", "pay-a", "acme"), channel("8", "pay-b", "other")];
    expect(rank(busy, "pay", { badges: { "8": [0, 0, 1] } })[0].item.name).toBe("pay-b");
    expect(rank(busy, "pay", { context: { repo_id: "other" } })[0].item.name).toBe("pay-b");
  });

  test("an empty query keeps every item, recents first, then in order", () => {
    const items = [channel("1", "a", "r"), channel("2", "b", "r"), channel("3", "c", "r")];
    expect(rank(items, "").map(r => r.item.name)).toEqual(["a", "b", "c"]);
    expect(rank(items, "  ", { recents: ["channel:3"] }).map(r => r.item.name)).toEqual(["c", "a", "b"]);
  });

  test("2,000 items rank in under 10 ms", () => {
    const words = ["payment", "retries", "api", "onboarding", "billing", "search", "cache", "login"];
    const items = Array.from({ length: 2000 }, (_, i) =>
      channel(String(i), `${words[i % 8]}-${words[(i * 3) % 8]}-${i}`, `repo-${i % 17}`),
    );
    rank(items, "warm up");
    const runs = 5;
    const start = performance.now();
    for (let i = 0; i < runs; i++) rank(items, "pay ret");
    expect((performance.now() - start) / runs).toBeLessThan(10);
  });

  test("commands are listed only where they can run", () => {
    const ids = (ctx: Record<string, unknown>) => commands({ path: "/agents", repos: [], playbooks: [], ...ctx }).map(c => c.id);

    const outside = ids({});
    expect(outside).toContain("go-settings");
    expect(outside).not.toContain("go-agents");
    expect(outside).not.toContain("stop-all");
    expect(outside).not.toContain("release-hold");
    expect(ids({ hold: true })).toContain("release-hold");

    const inChannel = ids({ path: "/channels/ch_1", channel: { id: "ch_1", kind: "channel", archived: false } });
    expect(inChannel).toEqual(expect.arrayContaining(["stop-all", "members", "brief", "library"]));

    const inDm = ids({ path: "/channels/ch_2", channel: { id: "ch_2", kind: "dm", archived: false } });
    expect(inDm).toContain("stop-all");
    expect(inDm).not.toContain("members");

    // the desktop notifications switch: the wording follows this browser's state
    expect(ids({ notify: "on" })).toContain("notify-off");
    expect(ids({ notify: "on" })).not.toContain("notify-on");
    expect(ids({ notify: "off" })).toContain("notify-on");
    expect(ids({ notify: "blocked" })).toContain("notify-on");
    expect(ids({ notify: "unsupported" })).not.toContain("notify-on");
    expect(outside.filter(id => id.startsWith("notify-"))).toEqual([]);

    const archived = ids({ path: "/channels/ch_3", channel: { id: "ch_3", kind: "channel", archived: true } });
    expect(archived).not.toContain("stop-all");
    expect(archived).toContain("changes");

    const perRepo = commands({
      path: "/agents",
      repoId: "r2",
      repos: [{ id: "r1", name: "acme" }, { id: "r2", name: "billing" }],
      playbooks: [{ id: "pb1", name: "bug-fix" }],
    });
    const labels = perRepo.map(c => c.label);
    expect(labels.indexOf("New channel in billing")).toBeLessThan(labels.indexOf("New channel in acme"));
    expect(perRepo.find(c => c.label === "Start playbook: bug-fix")!.action).toEqual({ navigate: "/playbooks/pb1/start" });
  });
});
