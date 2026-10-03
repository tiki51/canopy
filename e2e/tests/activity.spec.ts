import { test, expect, Page } from "@playwright/test";
import { createChannel, send, timeline } from "./helpers";

// The fake agent's "activity demo" turn (e2e/fake-opencode.mjs): narration,
// two steps, a failing `mix test` (exit 1), an edit to activity-demo.txt with
// line counts, and a passing command with 300 lines of output.

const liveCard = (page: Page) => page.locator('section[id^="telemetry-"]').first();
const lastTurn = (page: Page) => timeline(page).locator('section[id^="turn-"]').last();

/** Shows the finished turns (the compact timeline hides clean ones) and opens the last. */
async function openLastTurn(page: Page) {
  await page.locator("#toggle-activity").click();
  const turn = lastTurn(page);
  await turn.locator('[id^="turn-toggle-"]').click();
  await expect(turn).toHaveAttribute("data-open", "true");
  return turn;
}

test.describe("activity cards", () => {
  test("the live card shows the running command with a timer, and stays open into the finished card", async ({ page }) => {
    await createChannel(page);
    await send(page, "Run the activity demo slowly.");

    const card = liveCard(page);
    await expect(card).toContainText("is testing");
    // the header names the command running now and ticks its elapsed time
    await expect(card.locator('[id$="-current"]')).toContainText("mix test test/billing");
    await expect(card.locator('[id$="-elapsed"]').first()).toHaveText(/\d+s/);

    await card.locator('[id^="telemetry-toggle-"]').click();
    const running = card.locator('li[data-row][data-status="running"]');
    await expect(running).toContainText("mix test test/billing");
    await expect(running.locator('[id$="-elapsed"]')).toHaveText(/\d+s/);

    // the turn ends: the card it becomes arrives open, its rows in place
    await expect(timeline(page)).toContainText("Fixed the double charge");
    await expect(card).toBeHidden();
    const turn = lastTurn(page);
    await expect(turn).toHaveAttribute("data-open", "true");
    await expect(turn.locator('li[data-row][data-status="error"]')).toContainText("exit 1");
    await expect(turn.locator('[data-step-divider]')).toHaveCount(2);
  });

  test("Errors filters to the failing row, whose detail shows the exit code and the output; Copy copies the command", async ({ page, context }) => {
    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    await createChannel(page);
    await send(page, "Run the activity demo.");
    await expect(timeline(page)).toContainText("Fixed the double charge");

    const turn = await openLastTurn(page);
    const rows = turn.locator("li[data-row]");
    await expect(rows.filter({ visible: true })).toHaveCount(5);

    await turn.locator('[id$="-filter-errors"]').click();
    await expect(rows.filter({ visible: true })).toHaveCount(1);
    const failing = rows.filter({ hasText: "exit 1" });
    await expect(failing).toContainText("mix test test/billing");

    // the text filter narrows within the chip, and Esc clears it
    await turn.locator('[id$="-filter-all"]').click();
    const search = turn.locator('input[type="search"]');
    await search.fill("payments_test");
    await expect(rows.filter({ visible: true })).toHaveCount(1);
    await search.press("Escape");
    await expect(search).toHaveValue("");
    await expect(rows.filter({ visible: true })).toHaveCount(5);

    await failing.locator('button[id$="-toggle"]').click();
    const detail = failing.locator('[id$="-detail"]');
    await expect(detail).toContainText("42 tests, 1 failure");
    await expect(detail).toContainText("exit 1");

    await detail.locator('[id$="-command-copy"]').click();
    await expect(detail.locator('[id$="-command-copy"]')).toContainText("Copied");
    expect(await page.evaluate(() => navigator.clipboard.readText())).toBe("mix test test/billing");

    // the long output is an excerpt with its head and tail
    const passing = rows.filter({ hasText: "payments_test.exs:42" });
    await passing.locator('button[id$="-toggle"]').click();
    await expect(passing.locator('[id$="-output-text"]')).toContainText("lines omitted");
    await expect(passing.locator('[id$="-output-text"]')).toContainText("test 300 ok");
    await expect(passing.locator('[id$="-output-copy"]')).toContainText("Copy (excerpt)");
  });

  test("a file chip opens Changes on that file", async ({ page }) => {
    await createChannel(page);
    await send(page, "Run the activity demo.");
    await expect(timeline(page)).toContainText("Fixed the double charge");

    const turn = await openLastTurn(page);
    const chip = turn.locator('[id$="-files"] button[phx-value-path="activity-demo.txt"]');
    await expect(chip).toContainText("+2");
    await chip.click();
    await expect(page.locator("#changes-modal")).toBeVisible();
    await expect(page.locator("#file-diff")).toContainText("claim first");
    await page.locator("#close-changes").click();
  });

  test("Follow keeps the newest row in view; scrolling up shows a new-rows pill", async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 700 });
    await createChannel(page);
    await send(page, "Run the long activity demo.");

    const card = liveCard(page);
    await expect(card).toBeVisible();
    await card.locator('[id^="telemetry-toggle-"]').click();
    const scroll = card.locator('[id$="-scroll"]');
    await expect.poll(() => scroll.evaluate((el) => el.scrollHeight > el.clientHeight + 40), { timeout: 30_000 }).toBe(true);

    // pinned to the newest row while rows arrive
    await expect.poll(() => scroll.evaluate((el) => el.scrollHeight - el.scrollTop - el.clientHeight < 30)).toBe(true);

    const pill = card.locator('[id$="-pill"]');
    await expect
      .poll(async () => {
        await scroll.evaluate((el) => el.scrollTo({ top: 0 }));
        return pill.isVisible();
      })
      .toBe(true);
    await expect(pill).toContainText(/new rows?/);
    await expect(card.locator('[id$="-follow"]')).toHaveAttribute("aria-pressed", "false");

    await pill.click();
    await expect(pill).toBeHidden();
    await expect(card.locator('[id$="-follow"]')).toHaveAttribute("aria-pressed", "true");
    await expect.poll(() => scroll.evaluate((el) => el.scrollHeight - el.scrollTop - el.clientHeight < 30)).toBe(true);

    await expect(timeline(page)).toContainText("Fixed the double charge", { timeout: 30_000 });
  });

  test("the side panel opens from a card, survives a reload, and Esc closes it", async ({ page }) => {
    await createChannel(page);
    await send(page, "Run the activity demo.");
    await expect(timeline(page)).toContainText("Fixed the double charge");

    // in the compact timeline, the agent's message links to what it ran
    const receipt = timeline(page).locator('[id^="message-receipt-"]').last();
    await expect(receipt).toContainText("tools");
    await receipt.click();
    await expect(page).toHaveURL(/\?activity=evt_/);
    const panel = page.locator("#activity-panel");
    await expect(panel).toBeVisible();
    await expect(panel.locator("li[data-row]").filter({ hasText: "exit 1" })).toBeVisible();

    await page.reload();
    await expect(panel).toBeVisible();
    await expect(panel).toContainText("mix test test/billing");
    // (Esc is the panel's hook: wait for the page to be live)
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();

    await panel.locator("li[data-row] button").first().focus();
    await page.keyboard.press("Escape");
    await expect(panel).toBeHidden();
    await expect(page).not.toHaveURL(/activity=/);
  });

  test("keyboard only: Tab reaches a row and Enter opens it", async ({ page }) => {
    await createChannel(page);
    await send(page, "Run the activity demo.");
    await expect(timeline(page)).toContainText("Fixed the double charge");

    const turn = await openLastTurn(page);
    await turn.locator('[id^="turn-toggle-"]').focus();
    let id = "";
    for (let i = 0; i < 20 && !/^turn-evt_.+-toggle$/.test(id); i++) {
      await page.keyboard.press("Tab");
      id = await page.evaluate(() => document.activeElement?.id || "");
    }
    expect(id).toMatch(/^turn-evt_.+-toggle$/);
    await page.keyboard.press("Enter");
    await expect(page.locator(`#${id}`)).toHaveAttribute("aria-expanded", "true");
    await expect(page.locator(`#${id.replace(/-toggle$/, "-detail")}`)).toBeVisible();
  });

  test("at phone width the panel is an overlay and nothing scrolls sideways", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await createChannel(page);
    await send(page, "Run the activity demo.");
    await expect(timeline(page)).toContainText("Fixed the double charge");

    await page.locator("#toggle-activity").click();
    const turn = lastTurn(page);
    await turn.locator('[id^="turn-toggle-"]').click();
    await expect(turn).toHaveAttribute("data-open", "true");
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);

    await turn.locator('[id$="-panel"]').first().click();
    const panel = page.locator("#activity-panel");
    await expect(panel).toBeVisible();
    // (it slides in)
    await expect.poll(async () => (await panel.boundingBox())!.x).toBe(0);
    expect(Math.round((await panel.boundingBox())!.width)).toBe(390);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.locator("#activity-panel-back").click();
    await expect(panel).toBeHidden();
  });
});
