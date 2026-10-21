import { test, expect, Page, Locator } from "@playwright/test";
import fs from "node:fs";
import { clickHeader, createChannel, gotoLive, send, timeline, uniq } from "./helpers";
import { sql } from "./site-helpers";

// An engine that hits a usage or billing limit pauses on its own: its agents
// move to their fallback model, or wait for the reset with a nudge after it.
// The fake Claude Code (e2e/fake-claude/claude.mjs) hits a session limit on a
// prompt with `[limit]` (resetting in FAKE_RESETS_IN_S, default 2 h) and a
// billing limit on `[limit:billing]`, once per session. e2e's default engine
// is OpenCode, so the limited agents are put on Claude Code here; the
// fallback is the fake OpenCode.
//
// ENGINE_FALLBACK_SHOTS=<dir> also saves the screens the designer checks.

const OPENCODE_FALLBACK = "opencode:opencode/gpt-5-nano";
const shotsDir = process.env.ENGINE_FALLBACK_SHOTS;

async function snap(target: Page | Locator, name: string) {
  if (!shotsDir) return;
  fs.mkdirSync(shotsDir, { recursive: true });
  await target.screenshot({ path: `${shotsDir}/${name}.png`, animations: "disabled" });
}

/** Creates an active Claude Code agent; `fallback` is its Fallback model value ("" = Default). */
async function claudeAgent(page: Page, prefix: string, fallback = ""): Promise<string> {
  const name = uniq(prefix).replace(/[^a-z0-9-]/g, "");
  await gotoLive(page, "/agents/new");
  await page.getByLabel("Name (slug, used as @name)").fill(name);
  await page.getByLabel("Display name").fill(prefix);
  await page.getByLabel("Role (one line)").fill("Works on Claude Code");
  await page.locator("#agent-engine-select").selectOption("claude_code");
  await page.locator("#claude-model").selectOption({ index: 1 });
  await page.locator("#claude-effort").selectOption("low");
  await page.locator("#agent-fallback").selectOption(fallback);
  await page.locator("#save-agent").click();
  await expect(page).toHaveURL(/\/agents\/agt_/);
  return name;
}

async function setClaudeFallback(page: Page, value: string) {
  await gotoLive(page, "/settings");
  await page.locator("#claude-fallback").selectOption(value);
  await page.locator("#save-claude").click();
  await expect.poll(() => sql("SELECT ifnull(claude_fallback, '') FROM settings")).toBe(value);
}

const line = (page: Page, text: string | RegExp) =>
  timeline(page).locator('[id^="line-"]').filter({ hasText: text });

const banner = (page: Page, engine = "claude_code") => page.locator(`#engine-pause-${engine}`);

/** A system line's icon, text and time share one centre line; its text shows once, unclipped. */
async function expectOneRow(l: Locator) {
  const r = await l.evaluate((el) => {
    const mid = (e: Element | null) => (e ? (e.getBoundingClientRect().top + e.getBoundingClientRect().bottom) / 2 : null);
    const text = el.querySelector("[data-line-text]")!;
    const icon = el.querySelector('[class*="hero-"]');
    const time = el.querySelector("time");
    const t = (text as HTMLElement).innerText.trim();
    return {
      texts: el.querySelectorAll("[data-line-text]").length,
      iconOff: Math.abs(mid(icon)! - mid(text)!),
      timeOff: time ? Math.abs(mid(time)! - mid(text)!) : 0,
      clipped: text.scrollWidth > text.clientWidth + 1 || el.scrollWidth > el.clientWidth + 1 || text.getBoundingClientRect().right > innerWidth,
      doubled: t.length > 24 && t.indexOf(t.slice(0, 24), 1) > 0,
      leading: (text as HTMLElement).innerText !== (text as HTMLElement).innerText.trimStart(),
    };
  });
  expect(r).toEqual({ texts: 1, iconOff: expect.any(Number), timeOff: expect.any(Number), clipped: false, doubled: false, leading: false });
  expect(r.iconOff).toBeLessThanOrEqual(2);
  expect(r.timeOff).toBeLessThanOrEqual(2);
}

/** Checks each line at desktop width, then again at phone width (and shoots it there). */
async function expectLinesFit(page: Page, lines: [Locator, string][]) {
  for (const [l] of lines) await expectOneRow(l);
  await page.setViewportSize({ width: 390, height: 844 });
  for (const [l, name] of lines) {
    await expectOneRow(l);
    await snap(l, `${name}-phone`);
  }
  await page.setViewportSize({ width: 1440, height: 900 });
}

test.describe("engine pauses and fallbacks", () => {
  test.use({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: shotsDir ? 2 : 1 });

  test.afterEach(async () => {
    // no pause carries into the next test; the server may hold the write lock a moment
    await expect(() => {
      sql(`UPDATE engine_pauses SET lifted_at = '${new Date().toISOString()}', lifted_by = 'user' WHERE lifted_at IS NULL`);
      sql("UPDATE settings SET claude_fallback = NULL");
    }).toPass({ timeout: 10_000 });
  });

  test("Settings and the agent form offer a fallback, and the agent page says which", async ({ page }) => {
    await gotoLive(page, "/settings");
    const select = page.locator("#claude-fallback");
    await expect(select).toHaveValue("");
    await expect(select.locator("option:checked")).toHaveText("No fallback");
    await expect(page.locator("#claude-fallback-help")).toContainText("then go back to their own model");
    // grouped by engine; Claude Code's own models pause with it
    await expect(select.locator("optgroup")).toHaveCount(3);
    await expect(select.locator('optgroup[label="Claude Code"] option').first()).toContainText("(pauses with Claude Code)");
    await expect(select.locator(`option[value="${OPENCODE_FALLBACK}"]`)).toHaveCount(1);
    await setClaudeFallback(page, OPENCODE_FALLBACK);
    await page.reload();
    await expect(page.locator("#claude-fallback")).toHaveValue(OPENCODE_FALLBACK);
    await snap(page.locator("#claude-panel"), "S7-settings-claude-fallback");

    // the agent form: Default follows Settings for the form's engine
    await gotoLive(page, "/agents/new");
    await page.locator("#agent-engine-select").selectOption("claude_code");
    const agentSelect = page.locator("#agent-fallback");
    await expect(agentSelect.locator('option[value=""]')).toHaveText("Default (OpenCode › opencode/gpt-5-nano)");
    await expect(agentSelect.locator('option[value="none"]')).toHaveText("None: wait for the reset");
    await expect(page.locator("#agent-fallback-help")).toContainText("when Claude Code reports a usage limit");
    await snap(page.locator("#agent-fallback").locator("xpath=ancestor::div[contains(@class,'flex-col')][1]"), "S9-agent-form-fallback");

    // switching the form's engine keeps the choice; OpenCode has no default fallback
    await agentSelect.selectOption("none");
    await page.locator("#agent-engine-select").selectOption("opencode");
    await expect(page.locator("#agent-fallback")).toHaveValue("none");
    await expect(page.locator('#agent-fallback option[value=""]')).toHaveText("Default (none: wait for the reset)");
    await expect(page.locator("#agent-fallback-help")).toContainText("when OpenCode reports a usage limit");

    // each choice on the agent page
    const byDefault = await claudeAgent(page, "deflt");
    await expect(page.locator("#agent-fallback-value")).toHaveText("OpenCode › opencode/gpt-5-nano (default)");
    await snap(page.locator("#agent-fallback-value").locator("xpath=ancestor::dl[1]"), "S10a-agent-page-default");
    await claudeAgent(page, "waits", "none");
    await expect(page.locator("#agent-fallback-value")).toHaveText("None: waits for the reset");
    await snap(page.locator("#agent-fallback-value").locator("xpath=ancestor::dl[1]"), "S10b-agent-page-none");
    await claudeAgent(page, "own", "opencode:opencode/claude-haiku-4-5");
    await expect(page.locator("#agent-fallback-value")).toHaveText("OpenCode › opencode/claude-haiku-4-5");
    await snap(page.locator("#agent-fallback-value").locator("xpath=ancestor::dl[1]"), "S10c-agent-page-own");
    expect(sql(`SELECT ifnull(fallback, 'nil') FROM agents WHERE name = '${byDefault}'`)).toBe("nil");
  });

  test("a limit moves the agent to its fallback; another Claude Code agent follows (hit: false); Resume now brings them back", async ({ page }) => {
    await setClaudeFallback(page, OPENCODE_FALLBACK);
    const lim = await claudeAgent(page, "lim");
    const lim2 = await claudeAgent(page, "limtwo");
    await createChannel(page);

    await send(page, `@${lim} [limit] summarise the brief`);
    const hit = line(page, `@${lim} hit the Claude Code usage limit`);
    await expect(hit).toContainText(/\(resets \d{1,2}:\d{2}\) and carried on with OpenCode › opencode\/gpt-5-nano in a new session\. Back to \S+ at \d{1,2}:\d{2}\./, { timeout: 20_000 });
    await expect(banner(page)).toHaveAttribute("data-tone", "warning");
    await expect(banner(page)).toContainText("Claude Code is paused: usage limit.");
    await expect(banner(page)).toContainText(/Resets at\s+\d{1,2}:\d{2}\s+\(in (2h 0m|1h 59m)\s*\)\./);
    // no space between the countdown and its bracket
    await expect(banner(page)).toContainText(/\(in (2h 0m|1h 59m)\)/);
    await expect(banner(page)).toContainText("1 agent on a fallback.");

    // the fallback turn's reply carries the chip
    const chip = timeline(page).locator('[id*="-fallback-msg_"]').first();
    await expect(chip).toContainText("OpenCode · fallback", { timeout: 20_000 });
    await expect(chip).toHaveAttribute("title", /OpenCode › opencode\/gpt-5-nano.*Claude Code was paused/);
    await snap(hit, "S11-line-engine-fallback-hit");
    const chipId = (await chip.getAttribute("id"))!;
    await snap(page.locator(`[id="${chipId.replace("-fallback-", "-")}"]`), "S17-message-fallback-chip");

    // another Claude Code agent woken while the engine is paused moves without hitting the limit
    await send(page, `@${lim2} take a look too`);
    const routed = line(page, `so @${lim2} is working on OpenCode › opencode/gpt-5-nano`);
    await expect(routed).toContainText(/Claude Code is paused \(usage limit, resets \d{1,2}:\d{2}\), so/, { timeout: 20_000 });
    await expect(banner(page)).toContainText("2 agents on a fallback.");
    // its fallback reply lands before Resume, so the chip count below is settled
    await expect(timeline(page).locator('[id*="-fallback-msg_"]')).toHaveCount(2, { timeout: 20_000 });
    await snap(routed, "S12-line-engine-fallback-hit-false");
    await snap(page.locator("#engine-pauses"), "S1-banner-amber");

    // Resume now: both go back to their own models, nobody is nudged
    const primary = sql(`SELECT s.engine_session_id FROM agent_sessions s JOIN agents a ON a.id = s.agent_id WHERE a.name = '${lim}' AND s.fallback_of IS NULL AND s.parent_session_id IS NULL`);
    await page.locator("#resume-engine-claude_code").click();
    await expect(page.locator("#flash-info, [role=alert]").filter({ hasText: "Claude Code resumed." })).toBeVisible();
    const resumed = line(page, "You resumed Claude Code.");
    await expect(resumed).toContainText(`@${lim} is back on`);
    await expect(resumed).toContainText(`@${lim2} is back on`);
    await expect(resumed).not.toContainText("nudged");
    await expect(page.locator("#engine-pauses")).toHaveCount(0);
    await snap(resumed, "S15a-line-engine-resumed-returned");
    await expectLinesFit(page, [[hit, "S11"], [routed, "S12"], [resumed, "S15a"]]);

    // the next turn runs on the primary session again, with no chip
    const chips = await timeline(page).locator('[id*="-fallback-msg_"]').count();
    await send(page, `@${lim} anything else?`);
    await expect.poll(() => sql(`SELECT count(*) FROM timeline_events e JOIN agents a ON a.id = e.agent_id WHERE a.name = '${lim}' AND e.event_type = 'agent_turn_completed'`), { timeout: 20_000 }).toBe("3");
    await expect(timeline(page).locator('[id*="-fallback-msg_"]')).toHaveCount(chips);
    expect(sql(`SELECT s.engine_session_id FROM agent_sessions s JOIN agents a ON a.id = s.agent_id WHERE a.name = '${lim}' AND s.fallback_of IS NULL AND s.parent_session_id IS NULL`)).toBe(primary);
  });

  test("with no fallback the agent waits: countdown, a dropped wake, an Auto nudge; Resume now nudges it", async ({ page }) => {
    const waiter = await claudeAgent(page, "waiter", "none");
    await createChannel(page);
    // an OpenCode agent in the same channel (the default engine)
    await send(page, `@${waiter} [limit] start on the migration`);

    const paused = line(page, `@${waiter} hit the Claude Code usage limit and has no fallback.`);
    await expect(paused).toContainText(/It waits for the reset; a nudge is scheduled for \d{1,2}:\d{2}\./, { timeout: 20_000 });
    await expect(banner(page)).toContainText("1 agent waiting.");
    await expect(banner(page).locator("[phx-hook$=Countdown]")).toHaveText(/in (2h 0m|1h 59m)/);
    const auto = line(page, `Canopy scheduled a nudge for @${waiter}`);
    await expect(auto).toContainText("Your Claude Code usage limit has reset.");
    // the time the nudge runs at, as the design has it
    await expect(auto).toContainText(/once at \d{1,2}:\d{2}/);
    const turns = (name: string) => sql(`SELECT count(*) FROM timeline_events e JOIN agents a ON a.id = e.agent_id WHERE a.name = '${name}' AND e.event_type = 'agent_turn_completed'`);
    await expect.poll(() => turns(waiter)).toBe("1");
    await snap(paused, "S13-line-engine-paused");
    await snap(auto, "S16-line-auto-nudge");

    // the limited turn isn't an error: hidden in the compact feed, a muted line in full
    await expect(timeline(page)).not.toContainText("stopped with an error");
    await clickHeader(page, "toggle-activity");
    const limitTurn = line(page, `@${waiter} hit the usage limit ·`);
    await expect(limitTurn).toHaveCount(1);
    await expect(limitTurn.locator(".text-error")).toHaveCount(0);
    await expect(timeline(page)).not.toContainText("stopped with an error");
    await snap(limitTurn, "S18-turn-limit-muted");
    await expectLinesFit(page, [[limitTurn, "S18"]]);
    await clickHeader(page, "toggle-activity");

    // two mentions while it waits: one line
    await send(page, `@${waiter} are you there?`);
    await send(page, `@${waiter} hello?`);
    const dropped = line(page, `Didn't wake @${waiter}: Claude Code is paused until`);
    await expect(dropped).toHaveCount(1);
    await expect(dropped).toContainText(/The \d{1,2}:\d{2} nudge will pick this up\./);
    await page.waitForTimeout(1500);
    await expect(dropped).toHaveCount(1);
    await snap(dropped, "S14-line-engine-wake-dropped");
    await expectLinesFit(page, [[paused, "S13"], [auto, "S16"], [dropped, "S14"]]);

    // other engines carry on: the OpenCode owner answers
    const backendTurns = () => Number(sql("SELECT count(*) FROM timeline_events e JOIN agents a ON a.id = e.agent_id WHERE a.name = 'backend' AND e.event_type = 'agent_turn_completed'"));
    const before = backendTurns();
    await send(page, "@backend status?");
    await expect.poll(backendTurns, { timeout: 20_000 }).toBeGreaterThan(before);
    await expect(timeline(page)).not.toContainText("Didn't wake @backend");

    // the agent page lists the Auto nudge
    const agentId = sql(`SELECT id FROM agents WHERE name = '${waiter}'`);
    await gotoLive(page, `/agents/${agentId}`);
    const badge = page.locator('[id$="-auto"]').filter({ hasText: "Auto" });
    await expect(badge).toHaveCount(1);
    await snap(badge.locator("xpath=ancestor::*[self::li or self::tr][1]"), "S19-schedules-auto");
    await page.goBack();
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();

    // the countdown runs out: "resuming…" until the lift
    sql(`UPDATE engine_pauses SET resets_at = '${new Date(Date.now() - 20_000).toISOString()}' WHERE lifted_at IS NULL`);
    await page.reload();
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
    await expect(banner(page).locator("[phx-hook$=Countdown]")).toHaveText("resuming…");
    await snap(page.locator("#engine-pauses"), "S2-banner-resuming");
    sql(`UPDATE engine_pauses SET resets_at = '${new Date(Date.now() + 2 * 86_400_000 + 3 * 3_600_000 + 30_000).toISOString()}', reason = 'weekly usage limit' WHERE lifted_at IS NULL`);
    await page.reload();
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
    await expect(banner(page).locator("[phx-hook$=Countdown]")).toHaveText("in 2d 3h");
    await snap(page.locator("#engine-pauses"), "S3-banner-weekly");

    // Resume now: the nudge wakes it, and its turn goes through
    await page.locator("#resume-engine-claude_code").click();
    await expect(page.getByText("Claude Code resumed. Agents that waited were nudged.")).toBeVisible();
    const resumed = line(page, "You resumed Claude Code.");
    await expect(resumed).toContainText(`@${waiter} was nudged to continue.`);
    await expect(page.locator("#engine-pauses")).toHaveCount(0);
    await expect.poll(() => turns(waiter), { timeout: 20_000 }).toBe("2");
    await snap(resumed, "S15b-line-engine-resumed-nudged");
    await expectLinesFit(page, [[resumed, "S15b"]]);
    expect(sql(`SELECT group_concat(status) FROM schedules s JOIN agents a ON a.id = s.agent_id WHERE a.name = '${waiter}' AND s.source = 'auto'`)).toBe("done");
  });

  test("a billing limit with no reset is red until Release", async ({ page }) => {
    const payer = await claudeAgent(page, "payer", "none");
    await createChannel(page);
    await send(page, `@${payer} [limit:billing] ship it`);

    const paused = line(page, `Claude Code is paused (insufficient balance) and @${payer} has no fallback.`);
    await expect(paused).toContainText("It waits until you release Claude Code.", { timeout: 20_000 });
    await snap(paused, "S13b-line-engine-paused-billing");
    await clickHeader(page, "toggle-activity");
    const limitTurn = line(page, `@${payer} stopped: insufficient balance ·`);
    await expect(limitTurn).toHaveCount(1);
    await expect(timeline(page)).not.toContainText("stopped with an error");
    await snap(limitTurn, "S18b-turn-billing-muted");
    await expectLinesFit(page, [[paused, "S13b"], [limitTurn, "S18b"]]);
    await clickHeader(page, "toggle-activity");
    await expect(banner(page)).toHaveAttribute("data-tone", "error");
    await expect(banner(page)).toContainText("Claude Code is paused: insufficient balance. Agents on Claude Code wait until you release it. 1 agent waiting.");
    await expect(page.locator("#resume-engine-claude_code")).toHaveText("Release");
    expect(sql(`SELECT count(*) FROM schedules s JOIN agents a ON a.id = s.agent_id WHERE a.name = '${payer}' AND s.source = 'auto'`)).toBe("0");
    await snap(page.locator("#engine-pauses"), "S4-banner-red");

    // a second engine paused with a reset: red first, then amber
    sql(`INSERT INTO engine_pauses (id, engine, kind, reason, detail, resets_at, schedule_reason, paused_at, inserted_at, updated_at) VALUES ('ep_e2e_${Date.now()}', 'codex', 'usage', 'usage limit', 'limit', '${new Date(Date.now() + 5_400_000).toISOString()}', 'paused: Codex usage limit', '${new Date().toISOString()}', '${new Date().toISOString()}', '${new Date().toISOString()}')`);
    await page.reload();
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
    await expect(page.locator("#engine-pauses > div").first()).toHaveId("engine-pause-claude_code");
    await expect(page.locator("#engine-pauses > div").nth(1)).toHaveId("engine-pause-codex");
    await snap(page.locator("#engine-pauses"), "S5-banners-stacked");
    await page.setViewportSize({ width: 390, height: 844 });
    await snap(page, "S6-banners-narrow");
    await page.setViewportSize({ width: 1440, height: 900 });

    await page.locator("#resume-engine-claude_code").click();
    await expect(banner(page)).toHaveCount(0);
    await expect(line(page, "You resumed Claude Code.")).toContainText(`@${payer} was nudged to continue.`);
    await expect.poll(() => sql(`SELECT count(*) FROM timeline_events e JOIN agents a ON a.id = e.agent_id WHERE a.name = '${payer}' AND e.event_type = 'agent_turn_completed'`), { timeout: 20_000 }).toBe("2");
  });
});
