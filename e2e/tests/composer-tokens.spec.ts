import { test, expect } from "@playwright/test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
// The tokenizer has no DOM access, so it runs here in Node: the repo has no
// JS unit runner, and this one module doesn't justify adding one.
import { tokenize } from "../../assets/js/composer_tokens.js";

// Shared with test/canopy_web/composer_token_parity_test.exs, which derives the
// same expectations from the server.
const fixture = JSON.parse(
  readFileSync(fileURLToPath(new URL("../../test/support/composer_token_cases.json", import.meta.url)), "utf8"),
);

type Case = { name: string; text: string; expect: { kind: string; text: string }[]; [key: string]: unknown };

function context(kase: Case) {
  const get = (key: string) => (key in kase ? kase[key] : fixture.context[key]) as any;
  const inactive = new Set<string>(fixture.context.inactive);
  // the form's data-team-members lists active members only
  const teams = new Map<string, string[]>(
    Object.entries(get("teams") as Record<string, string[]>).map(([name, members]) => [
      name,
      members.filter(m => !inactive.has(m)),
    ]),
  );
  return {
    agents: new Set<string>(get("agents")),
    members: new Set<string>(get("members")),
    teams,
    channels: new Set<string>(get("channels")),
    commands: new Set<string>(get("commands")),
    thread: get("thread") as boolean,
  };
}

test.describe("composer tokenizer", () => {
  for (const kase of fixture.cases as Case[]) {
    test(`${kase.name}: ${JSON.stringify(kase.text)}`, () => {
      const tokens = tokenize(kase.text, context(kase));
      expect(tokens.map(t => t.text).join("")).toBe(kase.text);
      expect(tokens.filter(t => t.kind !== "plain")).toEqual(kase.expect);
    });
  }

  test("a 100 KB paste tokenizes quickly and round-trips", () => {
    const ctx = context({ name: "big", text: "", expect: [] });
    const chunk = "@backend see #payments, not `@reviewer` ```\n@designer\n``` & a ` stray @b-@a\n";
    const text = chunk.repeat(Math.ceil(100_000 / chunk.length));
    tokenize(text, ctx); // warm up the JIT
    const started = performance.now();
    const tokens = tokenize(text, ctx);
    const elapsed = performance.now() - started;
    expect(tokens.map(t => t.text).join("")).toBe(text);
    expect(elapsed).toBeLessThan(50);
  });
});
