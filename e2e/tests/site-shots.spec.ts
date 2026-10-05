// Captures the stills for the canopy_site homepage and docs (design review
// §9.3: ST-1…ST-7, F-1…F-7, D-1, D-2) at 2x, in dark and light, into
// canopy_site/src/assets/shots. Only runs when SITE=1:
//
//   SITE=1 CANOPY_SEED=e2e/bin/seed-acme.exs FAKE_TURN_DELAY_MS=2500 npx playwright test site-shots
//
// With SITE=1 the acme seed leaves #payment-retries out; this spec creates it
// in the browser and plays the whole story live. @backend and @reviewer run on
// the fake Claude Code (e2e/fake-claude), @researcher and @test on the fake
// OpenCode (e2e/fake-opencode.mjs), so every card, line and diff is the app's
// own rendering of a real turn. playwright.config.ts moves the server's clock
// to mid-morning so the timestamps read like a workday.
import { clickHeader } from "./helpers";
import { test, expect, Locator, Page } from "@playwright/test";
import {
  around,
  bottom,
  dismissFlash,
  iso,
  localAt,
  park,
  prepare,
  send,
  shot,
  sidebarChannel,
  sql,
  waitUntilLocal,
  wanted,
} from "./site-helpers";

const enabled = process.env.SITE === "1" && process.env.CANOPY_SEED !== undefined;
const timeline = (page: Page) => page.locator("#timeline");
const full = { x: 0, y: 0, width: 1440, height: 900 };
// The channel pane: everything right of the sidebar.
const pane = { x: 312, y: 0, width: 1128, height: 900 };
// A window that leaves the channel pane 720px wide, for docs crops whose text should wrap.
const narrow = { width: 1032, height: 900 };
const wide = { width: 1440, height: 900 };

/** Runs `capture` at the 1440 window (for crops that predate the narrow story), then goes back. */
async function atWide(page: Page, target: Locator, capture: () => Promise<void>) {
  await page.setViewportSize(wide);
  await target.scrollIntoViewIfNeeded();
  await park(page);
  await capture();
  await page.setViewportSize(narrow);
}

/** A card with 20px of background either side and 8px above and below, so no neighbour shows. */
async function cardCrop(target: Locator) {
  const clip = await around(target, 20);
  const box = (await target.boundingBox())!;
  const y = Math.floor(box.y - 8);
  return { ...clip, y, height: Math.ceil(box.y + box.height + 8) - y };
}

/** The channel pane from 16px above `first` to the bottom of `last`. */
async function fromTo(page: Page, first: Locator, last: Locator) {
  // The timeline may still be scrolling after a resize: wait until the anchor stops moving.
  let top = (await first.boundingBox())!;
  for (let i = 0; i < 30; i++) {
    await page.waitForTimeout(100);
    const next = (await first.boundingBox())!;
    if (next.y === top.y) break;
    top = next;
  }
  const end = (await last.boundingBox())!;
  const y = Math.max(0, Math.floor(top.y - 16));
  const width = page.viewportSize()!.width - pane.x;
  return { x: pane.x, y, width, height: Math.ceil(end.y + end.height) - y };
}

const agentId = (page: Page, name: string) =>
  page
    .locator(`#sidebar a[href^="/agents/"]`, { hasText: `@${name}` })
    .first()
    .getAttribute("href")
    .then((href) => href!.split("/agents/")[1]);

test.describe("stills for canopy_site", () => {
  test.skip(!enabled, "set SITE=1 and CANOPY_SEED=e2e/bin/seed-acme.exs to capture");
  test.use({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });

  test("capture the story and the feature shots", async ({ page }) => {
    test.setTimeout(900_000);
    await prepare(page);

    if (wanted("settings-claude-code")) {
      // -- D-1: Settings → Claude Code, after a successful check ------------------------
      await page.goto("/settings");
      await page.locator("#check-claude").click();
      await expect(page.locator("#claude-check-result")).toContainText(/logged in/i);
      // The fake binary lives in this checkout (e2e/fake-claude); show where an install puts it.
      await page.locator("#claude-check-result code").evaluate((el) => (el.textContent = "/Users/priya/.local/bin/claude"));
      await park(page);
      const claudePanel = page.locator("#claude-panel");
      await shot(page, "settings-claude-code", () => around(claudePanel, 24));
    }

    if (wanted("agents-mixed-engines", "agents-bento")) {
      // -- F-5: a mixed team on the Agents page -----------------------------------------
      await page.goto("/agents");
      const roster = page.locator("section", { has: page.locator("#active-agents") }).first();
      await expect(roster).toContainText("sonnet");
      await park(page);
      await shot(page, "agents-mixed-engines", () => around(roster, 24));
      // Homepage bento tile: Researcher (OpenCode) over Reviewer (Claude Code) with the next
      // row bleeding off the bottom, from an 880px panel so Engine sits beside Role.
      await page.locator("#agents-panel").evaluate((el: HTMLElement) => (el.style.width = "880px"));
      await shot(page, "agents-bento", async () => {
        const researcher = page.locator('#active-agents li[id^="agent-"]', { hasText: "@researcher" });
        const row = (await researcher.boundingBox())!;
        const name = (await researcher.getByText("Researcher", { exact: true }).boundingBox())!;
        const engine = (await researcher.locator('[id^="engine-"]').boundingBox())!;
        const x = Math.floor(row.x - 12);
        const y = Math.floor(name.y - 4);
        return { x, y, width: Math.ceil(engine.x + engine.width) - x, height: 190 };
      });
      await page.locator("#agents-panel").evaluate((el: HTMLElement) => el.style.removeProperty("width"));
    }

    if (wanted("memory-panel", "agent-edit-claude")) {
      // -- F-1: @backend's memory -------------------------------------------------------
      await page.locator('#active-agents a[href^="/agents/"]', { hasText: "backend" }).first().click();
      const memory = page.locator("section", { has: page.locator("#agent-memory") }).first();
      await expect(memory).toContainText("idempotent per invoice");
      await park(page);
      await shot(page, "memory-panel", () => around(memory, 24));

      // -- D-2: the agent form on Claude Code ---------------------------------------------
      await page.locator('[id^="edit-agent-"]').click();
      const form = page.locator("#agent-form");
      await expect(form).toBeVisible();
      // From the Engine field to the permissions help text: the Claude Code part of the form,
      // cropped around its panel so the card edge shows.
      const panel = page.locator("#agent-form-panel");
      const engine = page.locator("#agent-engine-select");
      await expect(engine).toHaveValue("claude_code");
      await engine.evaluate((el) => el.scrollIntoView({ block: "center" }));
      await park(page);
      await shot(page, "agent-edit-claude", async () => {
        // Show every allowed tool rather than a scrolled box (re-applied after each theme switch).
        await form.locator("textarea[name='agent[allowed_tools]']").evaluate((el: HTMLTextAreaElement) => {
          el.style.setProperty("height", `${el.scrollHeight + 4}px`, "important");
          el.style.setProperty("max-height", "none", "important");
        });
        // Down to the whole Save button plus 16px, so the crop doesn't cut through it.
        const save = form.getByRole("button", { name: /Save/ }).first();
        await panel.getByText(/Model aliases/).first().evaluate((el) => el.scrollIntoView({ block: "center" }));
        const card = (await panel.boundingBox())!;
        const top = (await page.locator('label[for="agent-engine-select"], label:has(#agent-engine-select)').first().boundingBox())!;
        const button = (await save.boundingBox())!;
        const y = top.y - 24;
        return { x: card.x - 24, y, width: card.width + 48, height: button.y + button.height + 16 - y };
      });
    }

    // -- F-7: the new-channel form with a spend limit -----------------------------------
    await page.goto("/channels/new");
    await page.getByLabel("Repository").selectOption({ label: "acme-billing" });
    await page.getByLabel("Name (slug, shown as #name)").fill("payment-retries");
    await page.getByLabel("Topic").fill("Invoices are occasionally charged twice");
    const finops = page.locator("label", { hasText: "@finops" }).first();
    if (await finops.locator("input").isChecked()) await finops.click();
    const owner = page.getByLabel("Initial owner");
    const backendValue = await owner.locator("option", { hasText: "backend" }).first().getAttribute("value");
    await owner.selectOption(backendValue!);
    const limit = page.getByLabel(/Spend limit/);
    await limit.fill("5");
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    // The re-render after validation shows the cast float (5.0); show what was typed.
    await limit.evaluate((el: HTMLInputElement) => (el.value = "5"));
    await park(page);
    const channelForm = page.locator("section, form", { has: page.getByLabel(/Spend limit/) }).first();
    await shot(page, "new-channel-budget", () => around(channelForm, 24));
    await page.locator("#create-channel").click();
    await expect(page).toHaveURL(/\/channels\/ch_/);
    const channelId = page.url().split("/channels/")[1];
    await dismissFlash(page);

    const backend = await agentId(page, "backend");
    const reviewer = await agentId(page, "reviewer");

    // -- ST-1: Priya posts the task with the retry log; @backend wakes -------------------
    // The story frames are taken in the narrow window: the homepage shows the 720px pane
    // at about 1:1, so the text stays legible and nothing clips at the right edge.
    await page.setViewportSize(narrow);
    await page.locator("#composer-library").click();
    await page.locator('#library-documents button', { hasText: "support-ticket-4821.png" }).click();
    // Picking a file closes the library; without a timeout this click would wait out the test.
    await page.locator("#close-library").click({ timeout: 1_000 }).catch(() => {});
    // Priya posts at 10:42:00 on every run (playwright.config.ts starts the clock at 10:40).
    await waitUntilLocal(page, 10, 42);
    await send(
      page,
      "Support has three reports this week of an invoice charged twice, always after a failed webhook. Here is the retry log from ticket #4821. Read `payments.py` and `retry_worker.py` and post a root-cause summary. Don't change any files yet.",
    );
    const card = page.locator(`#telemetry-${backend}`);
    await expect(card).toBeVisible({ timeout: 30_000 });
    const image = page.locator('[id^="attachment-"][data-kind="image"] img').first();
    await image.evaluate((el: HTMLImageElement) => el.complete || new Promise((r) => (el.onload = r)));
    // The composer refocuses after a send; its focus ring shouldn't be in the frame.
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await park(page);
    await shot(page, "first-message");

    // -- ST-2: the live card, three tools in, researching --------------------------------
    await page.locator(`#telemetry-toggle-${backend}`).click();
    await expect(card).toContainText("3 tools", { timeout: 30_000 });
    await expect(card).toContainText("is researching");
    await card.scrollIntoViewIfNeeded();
    await park(page);
    await shot(page, "story-02-working");

    // -- ST-3: delegated to @researcher, who reports back with a Markdown file ------------
    await expect(timeline(page)).toContainText("Shall I go ahead?", { timeout: 120_000 });
    const report = page.locator('[id^="attachment-"]', { hasText: "enqueue-paths.md" }).first();
    await expect(report).toBeVisible();
    await report.scrollIntoViewIfNeeded();
    await page.locator("#timeline-scroll").evaluate((el) => (el.scrollTop = el.scrollTop + 160));
    await park(page);
    await shot(page, "story-03-delegate");

    // -- F-2: @backend asks a question before building ------------------------------------
    await bottom(page);
    await send(page, "Go ahead with the claim approach. Keep the PR small.");
    const question = page.locator('[id^="question-"][data-detached]').first();
    await expect(question).toContainText("attempt number", { timeout: 60_000 });
    await question.scrollIntoViewIfNeeded();
    await park(page);
    await atWide(page, question, () => shot(page, "question-card", () => cardCrop(question)));
    await question.getByLabel("Invoice only (Recommended)").check();
    await question.locator('[id$="-send"]').click();
    await expect(question).toBeHidden({ timeout: 30_000 });

    // -- ST-4: the permission card with the real diff ------------------------------------
    const perm = page.locator('section[id^="permission-"]').first();
    await expect(perm).toContainText("claim_charge", { timeout: 60_000 });
    await perm.scrollIntoViewIfNeeded();
    await park(page);
    await shot(page, "story-04-permission");
    await atWide(page, perm, () => shot(page, "story-04-permission-card", () => cardCrop(perm)));
    await page.locator('[id^="permission-"][id$="-always"]').first().click();
    await expect(perm).toBeHidden({ timeout: 30_000 });

    // -- ST-5: the handoff to @reviewer: the three handoff lines ----------
    await expect(timeline(page).locator('[id^="line-"]', { hasText: "ownership moved" }).last()).toBeVisible({ timeout: 120_000 });
    await expect(timeline(page)).toContainText(/accepted/i);
    await bottom(page);
    await park(page);
    await shot(page, "story-05-handoff");

    // -- ST-6: the review, the receipt, and the diff -------------------------------------
    await expect(timeline(page)).toContainText("Approving with two small notes", { timeout: 120_000 });
    await expect(page.locator(`#telemetry-${reviewer}`)).toBeHidden({ timeout: 60_000 });
    await clickHeader(page, "toggle-activity");
    // @reviewer's review; @backend's pass on the handoff-accepted note comes after it.
    const lastTurn = page.locator('#timeline section[id^="turn-"]', { hasText: /reviewer.*finished/ }).last();
    await expect(lastTurn).toContainText(/finished/);
    await lastTurn.locator('[id^="turn-toggle-"]').click();
    await lastTurn.scrollIntoViewIfNeeded();
    await park(page);
    // From 16px above the "ownership moved" line (never under the channel header) to 16px
    // below the receipt, above whatever turn starts next.
    const moved = timeline(page).locator('[id^="line-"]', { hasText: "ownership moved" }).last();
    await shot(page, "story-06-receipt", async () => {
      const header = (await page.locator("#channel-header").boundingBox())!;
      const top = (await moved.boundingBox())!;
      const box = (await lastTurn.boundingBox())!;
      const y = Math.ceil(Math.max(header.y + header.height + 1, top.y - 16));
      return { x: pane.x, y, width: narrow.width - pane.x, height: Math.min(900, Math.ceil(box.y + box.height + 16)) - y };
    });
    await clickHeader(page, "toggle-activity");

    await clickHeader(page, "open-changes");
    await expect(page.locator("#changes-modal")).toBeVisible();
    await page.locator('[id^="changed-file-"]', { hasText: "payments.py" }).first().click();
    await expect(page.locator("#file-diff")).toContainText("claim_charge");
    await park(page);
    // The homepage's step 06 frame, narrow like the rest of the story; the modal crop below is wide.
    await shot(page, "story-06-changes-full");
    await page.setViewportSize(wide);
    await park(page);
    const modal = page.locator("#changes-modal .modal-box, #changes-modal [role=dialog], #changes-modal > div").first();
    // The modal from its top to 24px below the last diff line: the empty lower part is left out.
    await shot(page, "story-06-changes", async () => {
      const box = (await modal.boundingBox())!;
      const end = await page.locator("#file-diff").evaluate((el) => {
        const range = document.createRange();
        range.selectNodeContents(el);
        return range.getBoundingClientRect().bottom;
      });
      const y = Math.floor(box.y);
      return { x: Math.floor(box.x), y, width: Math.ceil(box.width), height: Math.min(Math.ceil(box.height), Math.ceil(end + 24) - y) };
    });
    await page.locator("#close-changes").click();

    // -- F-6: a weekday schedule -----------------------------------------------------------
    await send(page, "@backend every weekday at 09:00, check the failed-charge queue depth and post here if it is above 50.");
    await expect(timeline(page)).toContainText("Scheduled: every weekday at 09:00", { timeout: 60_000 });
    await clickHeader(page, "edit-schedules");
    const schedules = page.locator("#schedules-panel");
    await expect(schedules).toContainText("failed-charge queue");
    await park(page);
    await shot(page, "schedule-weekday", () => around(schedules, 0));
    await clickHeader(page, "edit-schedules");
    await page.locator("#toggle-details").click();
    await expect(page.locator("#details-panel")).toBeHidden();

    // -- ST-7: the next morning ---------------------------------------------------------------
    // Fast-forward the schedule's Oban job to now, let @backend post, then
    // restamp that run to 09:00 tomorrow so the timeline reads as the next day.
    const scheduleId = sql(`select id from schedules where channel_id = '${channelId}' and cron is not null limit 1`);
    expect(scheduleId).toMatch(/^sch_/);
    const before = iso(new Date(Date.now() - 1000));
    sql(`update oban_jobs set scheduled_at = '${iso(new Date())}' where state = 'scheduled' and args like '%${scheduleId}%'`);
    await expect(timeline(page)).toContainText("09:00 check", { timeout: 60_000 });
    await expect(page.locator(`#telemetry-${backend}`)).toBeHidden({ timeout: 60_000 });
    const morning = iso(localAt(1, 9, 0));
    for (const table of ["timeline_events", "messages"]) {
      sql(`update ${table} set inserted_at = '${morning}', updated_at = '${morning}' where channel_id = '${channelId}' and inserted_at >= '${before}'`);
    }
    await page.reload();
    await expect(timeline(page)).toContainText("09:00 check");
    await bottom(page);
    await park(page);
    await shot(page, "closed-laptop-record", full);

    // -- F-4: agents talk among themselves until the chatter limit holds them -------------
    // Runs before F-3: the chatter pushes the seeded history (which has an errored turn)
    // out of the Stop all frame.
    await sidebarChannel(page, "checkout-latency").click();
    await expect(timeline(page)).toContainText("priceCart");
    const researcher = await agentId(page, "researcher");
    const tester = await agentId(page, "test");
    await send(page, "@researcher agree a load-test plan with @test, then post it here.");
    await expect(page.locator("#paused-bar")).toContainText("Paused after", { timeout: 180_000 });
    await expect(page.locator(`#telemetry-${researcher}`)).toBeHidden({ timeout: 30_000 });
    await expect(page.locator(`#telemetry-${tester}`)).toBeHidden({ timeout: 30_000 });
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await bottom(page);
    await park(page);
    // From Priya's prompt down: the back-and-forth, the hold line and the Continue bar.
    const prompt = timeline(page).locator('[id^="message-"]', { hasText: "agree a load-test plan" }).last();
    await shot(page, "chatter-hold", async () => {
      const box = (await prompt.boundingBox())!;
      const y = Math.max(0, Math.floor(box.y - 16));
      return { x: pane.x, y, width: pane.width, height: 900 - y };
    });
    // The docs crop: a 720px pane so the messages wrap, from the last three agent
    // messages to the bottom of the Continue bar (no composer).
    await page.setViewportSize(narrow);
    await bottom(page);
    const third = timeline(page).locator('[id^="message-"]', { hasText: "Two load test runs" }).last();
    await shot(page, "chatter-hold-docs", () => fromTo(page, third.locator(":scope > div").first(), page.locator("#paused-bar")));
    await page.setViewportSize(wide);
    await bottom(page);

    // -- F-3: an agent at work and one waiting, then Stop all --------------------------------------------
    await send(page, "@researcher profile `createSession` under load, and @test run the checkout suite against staging while it does.");
    // One turn runs per channel at a time: @researcher works while @test waits its turn.
    await expect(page.locator(`#telemetry-${researcher}`)).toContainText(/\d+ (cmd|read|search)/, { timeout: 30_000 });
    await expect(page.locator('main [data-status="queued"]').first()).toBeVisible({ timeout: 30_000 });
    // Open the live card so the frame shows what @researcher is doing.
    const toggle = page.locator(`#telemetry-toggle-${researcher}`);
    if (await toggle.isVisible()) await toggle.click();
    await expect(page.locator(`#telemetry-${researcher}-rows`)).toBeVisible();
    await bottom(page);
    await page.locator("#stop-all").hover();
    await shot(page, "stop-all", pane);
    // The docs detail: the right end of the header, from the agents button (or the spend
    // button, whichever starts further left) to the edge, so Stop is the focal point.
    await shot(page, "stop-all-toolbar", async () => {
      const header = (await page.locator("#channel-header").boundingBox())!;
      const budget = (await page.locator("#edit-budget").boundingBox())!;
      const members = (await page.locator("#agents-button").boundingBox())!;
      const x = Math.floor(Math.min(budget.x, members.x) - 16);
      return { x, y: header.y, width: 1440 - x, height: header.height };
    });
    await page.locator("#stop-all").click();
    await expect(page.locator("#paused-bar")).toContainText("Stopped", { timeout: 30_000 });
    await expect(page.locator(`#telemetry-${researcher}`)).toBeHidden({ timeout: 30_000 });
    await expect(page.locator(`#telemetry-${tester}`)).toBeHidden({ timeout: 30_000 });
    await dismissFlash(page);
    await bottom(page);
    await park(page);
    await shot(page, "stop-all-after", pane);
    // The docs detail: the Stop all notice and the Stopped… Continue bar, in a 720px pane.
    await page.setViewportSize(narrow);
    await bottom(page);
    const notice = timeline(page).locator('[id^="message-"]', { hasText: "Stopped all agent activity" }).last();
    await shot(page, "stop-all-after-docs", () => fromTo(page, notice, page.locator("#paused-bar")));
  });
});
