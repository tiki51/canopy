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
import { test, expect, Page } from "@playwright/test";
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
} from "./site-helpers";

const enabled = process.env.SITE === "1" && process.env.CANOPY_SEED !== undefined;
const timeline = (page: Page) => page.locator("#timeline");
const full = { x: 0, y: 0, width: 1440, height: 900 };
// The channel pane: everything right of the sidebar.
const pane = { x: 312, y: 0, width: 1128, height: 900 };

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

    // -- D-1: Settings → Claude Code, after a successful check ------------------------
    await page.goto("/settings");
    await page.locator("#check-claude").click();
    await expect(page.locator("#claude-check-result")).toContainText(/logged in/i);
    await park(page);
    const claudePanel = page.locator("#claude-panel");
    await shot(page, "settings-claude-code", () => around(claudePanel, 24));

    // -- F-5: a mixed team on the Agents page -----------------------------------------
    await page.goto("/agents");
    const roster = page.locator("section", { has: page.locator("#active-agents") }).first();
    await expect(roster).toContainText("sonnet");
    await park(page);
    await shot(page, "agents-mixed-engines", () => around(roster, 24));

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
    // From the Engine field to the permissions help text: the Claude Code part of the form.
    const engine = page.locator("#agent-engine-select");
    await expect(engine).toHaveValue("claude_code");
    await engine.evaluate((el) => el.scrollIntoView({ block: "center" }));
    // Show every allowed tool rather than a scrolled box.
    await form.locator("textarea[name='agent[allowed_tools]']").evaluate((el: HTMLTextAreaElement) => {
      el.style.height = `${el.scrollHeight + 4}px`;
    });
    await park(page);
    await shot(page, "agent-edit-claude", async () => {
      const card = (await form.boundingBox())!;
      const top = (await page.locator('label[for="agent-engine-select"], label:has(#agent-engine-select)').first().boundingBox())!;
      const help = (await form.getByText(/Model aliases/).first().boundingBox())!;
      const y = top.y - 24;
      return { x: card.x - 24, y, width: card.width + 48, height: help.y + help.height + 16 - y };
    });

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
    await page.getByLabel(/Spend limit/).fill("5");
    await page.getByLabel(/Spend limit/).blur();
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
    await page.locator("#composer-library").click();
    await page.locator('#library-documents button', { hasText: "support-ticket-4821.png" }).click();
    await page.locator("#close-library").click().catch(() => {});
    await send(
      page,
      "Support has three reports this week of an invoice charged twice, always after a failed webhook. Here is the retry log from ticket #4821. Read `payments.py` and `retry_worker.py` and post a root-cause summary. Don't change any files yet.",
    );
    const card = page.locator(`#telemetry-${backend}`);
    await expect(card).toBeVisible({ timeout: 30_000 });
    const image = page.locator('[id^="attachment-"][data-kind="image"] img').first();
    await image.evaluate((el: HTMLImageElement) => el.complete || new Promise((r) => (el.onload = r)));
    await park(page);
    await shot(page, "first-message", full);

    // -- ST-2: the live card, three tools in, researching --------------------------------
    await page.locator(`#telemetry-toggle-${backend}`).click();
    await expect(card).toContainText("3 tools", { timeout: 30_000 });
    await expect(card).toContainText("is researching");
    await card.scrollIntoViewIfNeeded();
    await park(page);
    await shot(page, "story-02-working", full);

    // -- ST-3: delegated to @researcher, who reports back with a Markdown file ------------
    await expect(timeline(page)).toContainText("Shall I go ahead?", { timeout: 120_000 });
    const report = page.locator('[id^="attachment-"]', { hasText: "enqueue-paths.md" }).first();
    await expect(report).toBeVisible();
    await report.scrollIntoViewIfNeeded();
    await page.locator("#timeline-scroll").evaluate((el) => (el.scrollTop = el.scrollTop + 160));
    await park(page);
    await shot(page, "story-03-delegate", full);

    // -- F-2: @backend asks a question before building ------------------------------------
    await bottom(page);
    await send(page, "Go ahead with the claim approach. Keep the PR small.");
    const question = page.locator('section[id^="question-"]').first();
    await expect(question).toContainText("attempt number", { timeout: 60_000 });
    await question.scrollIntoViewIfNeeded();
    await park(page);
    await shot(page, "question-card", () => around(question, 20));
    await question.getByLabel("Invoice only (Recommended)").check();
    await question.locator('[id$="-send"]').click();
    await expect(question).toBeHidden({ timeout: 30_000 });

    // -- ST-4: the permission card with the real diff ------------------------------------
    const perm = page.locator('section[id^="permission-"]').first();
    await expect(perm).toContainText("claim_charge", { timeout: 60_000 });
    await perm.scrollIntoViewIfNeeded();
    await park(page);
    await shot(page, "story-04-permission", full);
    await shot(page, "story-04-permission-card", () => around(perm, 20));
    await page.locator('[id^="permission-"][id$="-always"]').first().click();
    await expect(perm).toBeHidden({ timeout: 30_000 });

    // -- ST-5: the handoff to @reviewer, with the Task panel open --------------------------
    await expect(page.locator("#owner-badge")).toContainText("reviewer", { timeout: 120_000 });
    await expect(timeline(page)).toContainText(/accepted/i);
    await page.locator("#edit-task").click();
    await expect(page.locator("#task-panel")).toBeVisible();
    await bottom(page);
    await park(page);
    await shot(page, "story-05-handoff", full);
    await page.locator("#edit-task").click();

    // -- ST-6: the review, the receipt, and the diff -------------------------------------
    await expect(timeline(page)).toContainText("Approving with two small notes", { timeout: 120_000 });
    await expect(page.locator(`#telemetry-${reviewer}`)).toBeHidden({ timeout: 60_000 });
    await page.locator("#toggle-activity").click();
    const lastTurn = page.locator('#timeline details[id^="turn-"]').last();
    await expect(lastTurn).toContainText(/finished/);
    await lastTurn.locator("summary").click();
    await lastTurn.scrollIntoViewIfNeeded();
    await park(page);
    await shot(page, "story-06-receipt", async () => {
      const box = (await lastTurn.boundingBox())!;
      return { x: pane.x, y: Math.max(56, box.y - 260), width: pane.width, height: Math.min(900 - Math.max(56, box.y - 260), box.height + 300) };
    });
    await page.locator("#toggle-activity").click();

    await page.locator("#open-changes").click();
    await expect(page.locator("#changes-modal")).toBeVisible();
    await page.locator('[id^="changed-file-"]', { hasText: "payments.py" }).first().click();
    await expect(page.locator("#file-diff")).toContainText("claim_charge");
    await park(page);
    const modal = page.locator("#changes-modal .modal-box, #changes-modal [role=dialog], #changes-modal > div").first();
    await shot(page, "story-06-changes", () => around(modal, 0));
    await shot(page, "story-06-changes-full", full);
    await page.locator("#close-changes").click();

    // -- F-6: a weekday schedule -----------------------------------------------------------
    await send(page, "@backend every weekday at 09:00, check the failed-charge queue depth and post here if it is above 50.");
    await expect(timeline(page)).toContainText("Scheduled: every weekday at 09:00", { timeout: 60_000 });
    await page.locator("#edit-schedules").click();
    const schedules = page.locator("#schedules-panel");
    await expect(schedules).toContainText("failed-charge queue");
    await park(page);
    await shot(page, "schedule-weekday", () => around(schedules, 0));
    await page.locator("#edit-schedules").click();

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

    // -- F-3: an agent at work and one waiting, then Stop all --------------------------------------------
    await sidebarChannel(page, "checkout-latency").click();
    await expect(timeline(page)).toContainText("priceCart");
    await send(page, "@researcher profile `createSession` under load, and @test run the checkout suite against staging while it does.");
    const researcher = await agentId(page, "researcher");
    const tester = await agentId(page, "test");
    // One turn runs per channel at a time: @researcher works while @test waits its turn.
    await expect(page.locator(`#telemetry-${researcher}`)).toContainText("tools", { timeout: 30_000 });
    await expect(page.locator('main [data-status="queued"]').first()).toBeVisible({ timeout: 30_000 });
    await bottom(page);
    await page.locator("#stop-all").hover();
    await shot(page, "stop-all", pane);
    await page.locator("#stop-all").click();
    await expect(page.locator("#paused-bar")).toContainText("Stopped", { timeout: 30_000 });
    await expect(page.locator(`#telemetry-${researcher}`)).toBeHidden({ timeout: 30_000 });
    await expect(page.locator(`#telemetry-${tester}`)).toBeHidden({ timeout: 30_000 });
    await dismissFlash(page);
    await bottom(page);
    await park(page);
    await shot(page, "stop-all-after", pane);

    // -- F-4: agents talk among themselves until the chatter limit holds them -------------
    await send(page, "@researcher agree a load-test plan with @test, then post it here.");
    await expect(page.locator("#paused-bar")).toContainText("Paused after", { timeout: 180_000 });
    await expect(page.locator(`#telemetry-${researcher}`)).toBeHidden({ timeout: 30_000 });
    await expect(page.locator(`#telemetry-${tester}`)).toBeHidden({ timeout: 30_000 });
    await bottom(page);
    await park(page);
    await shot(page, "chatter-hold", pane);
  });
});
