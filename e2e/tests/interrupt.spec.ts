import { test, expect, Page } from "@playwright/test";
import { createChannel, send, timeline, clickHeader, openDetails } from "./helpers";

// Agent Interrupt (experimental, off by default): with "Mentioning a working
// agent interrupts it" on, a mention of @backend while it runs the slow
// checkout suite (e2e/fake-opencode.mjs: a six-second k6 run first) goes into
// its turn; the fake reads it after the running call, as OpenCode is believed
// to, and quotes it in its reply.

const STORY = "Run the checkout suite slowly.";
const NUDGE = "@backend skip the payment tests";

async function setInterrupt(page: Page, on: boolean) {
  await page.goto("/settings");
  const box = page.locator("#chatter-form input[type=checkbox][name='setting[interrupt_on_mention]']");
  if (on) await box.check();
  else await box.uncheck();
  await page.locator("#save-chatter").click();
  await expect(page.locator("#flash-info")).toBeVisible();
}

/** A channel where @backend is busy on the k6 run. */
async function backendWorking(page: Page) {
  await createChannel(page);
  await send(page, STORY);
  const card = page.locator('section[id^="telemetry-"]').first();
  await expect(card.locator('[id$="-current"]')).toContainText("k6 run");
  return card;
}

test.describe("interrupting a working agent", () => {
  test.beforeEach(async ({ page }) => setInterrupt(page, true));
  test.afterAll(async ({ browser }) => {
    const page = await browser.newPage();
    await setInterrupt(page, false);
    await page.close();
  });

  test("a mention reaches the agent after its current step, within the same turn", async ({ page }) => {
    const card = await backendWorking(page);

    // the composer says what will happen before sending
    await page.locator("#composer-input").fill(NUDGE);
    await expect(page.locator("#composer-awaiting-hint")).toContainText("@backend is working; it will read this after its current step");
    await page.locator("#composer-input").press("Enter");

    await expect(card.locator('[id^="steer-chip-"]')).toContainText("Interrupting after current step");
    // no step timer left dangling on the chip
    await expect(card.locator('[id^="steer-elapsed-"]')).toHaveCount(0);
    await openDetails(page);
    await expect(page.locator('[id$="-steers"]')).toContainText("1 message waiting");
    // the message itself says it has not been read yet
    const nudge = timeline(page).locator("article", { hasText: NUDGE }).first();
    await expect(nudge.locator('[id^="message-queued-"]')).toHaveText("Queued · delivered after the current step");

    // the agent quotes it in the reply of the turn it was working on
    await expect(timeline(page)).toContainText(`Re your message: “${NUDGE}”`);
    // the turn is over: no longer queued
    await expect(nudge.locator('[id^="message-queued-"]')).toHaveCount(0);
    await clickHeader(page, "toggle-activity");
    await expect(timeline(page)).toContainText("will read your message after its current step");
    await expect(timeline(page)).toContainText("took 1 message mid-turn");
    await expect(timeline(page).getByText("@backend started working")).toHaveCount(1);
  });

  test("Alt+Enter sends without interrupting: the message waits for the turn", async ({ page }) => {
    const card = await backendWorking(page);

    await page.locator("#composer-input").fill(NUDGE);
    await page.locator("#composer-input").press("Alt+Enter");
    await expect(timeline(page)).toContainText(NUDGE);
    // the k6 run ends and the suite goes on: nothing was handed to the turn
    await expect(card.locator('[id$="-current"]')).not.toContainText("k6 run", { timeout: 10_000 });
    await expect(card.locator('[id^="steer-chip-"]')).toHaveCount(0);
    await expect(timeline(page)).not.toContainText("Re your message");

    // the turn ends (Abort): the message starts the next one
    await openDetails(page);
    await page.locator('#members li:has-text("@backend") [id^="abort-"]').click();
    await expect(timeline(page)).toContainText("Acknowledged: looking into it now.");
  });

  test("Interrupt now stops the running step and starts a turn with the message", async ({ page }) => {
    const card = await backendWorking(page);
    await send(page, NUDGE);

    const chip = card.locator('[id^="steer-chip-"]');
    await expect(chip).toContainText("Interrupting after current step");
    await chip.locator('[id^="interrupt-now-"]').click();

    await expect(timeline(page)).toContainText("interrupted @backend");
    await expect(timeline(page)).toContainText("@backend was interrupted by");
    // a new turn reads it at once
    await expect(timeline(page)).toContainText("Acknowledged: looking into it now.");
    await expect(timeline(page)).not.toContainText("Re your message");
  });
});
