import { test, expect, Page } from "@playwright/test";
import { createChannel, send, timeline } from "./helpers";

// Finished turns, as cards (the fake's default turn runs a tool); hidden in the
// compact timeline but still in the DOM.
const turns = (page: Page) => timeline(page).locator('section[id^="turn-"]');
const working = (page: Page) => page.locator('section[id^="telemetry-"]');

/** A channel where the owner (@backend) has answered once and gone idle. */
async function answered(page: Page) {
  await createChannel(page);
  await send(page, "Why are invoices duplicated?");
  await expect(timeline(page)).toContainText("Acknowledged: looking into it now.");
  await expect(turns(page)).toHaveCount(1);
  await expect(working(page)).toHaveCount(0);
  return timeline(page).locator("article", { hasText: "Acknowledged: looking into it now." }).first();
}

async function react(page: Page, article: ReturnType<Page["locator"]>, key: string) {
  await article.hover();
  await article.locator('[id^="react-msg_"]').click();
  const picker = article.locator('[id^="react-picker-"][role="menu"]');
  await expect(picker).toBeVisible();
  await picker.locator(`[id$="-${key}"]`).click();
  await expect(picker).toBeHidden();
}

test.describe("reactions", () => {
  test("the user's ✅ shows as a chip, wakes nobody, toggles off, and survives a reload", async ({ page }) => {
    const post = await answered(page);

    await react(page, post, "check");
    const chip = post.locator('[id^="reaction-msg_"][id$="-check"]');
    await expect(chip).toContainText("✅");
    await expect(chip).toContainText("1");
    await expect(chip).toHaveAttribute("data-mine", "true");
    await expect(chip).toHaveAttribute("title", "You: done / approved");

    // the next message wakes @backend exactly once: the reaction woke nobody
    await send(page, "@backend status?");
    await expect(timeline(page)).toContainText("@backend status?");
    await expect(turns(page)).toHaveCount(2);
    await expect(working(page)).toHaveCount(0);
    await expect(turns(page)).toHaveCount(2);

    await page.reload();
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
    const reloaded = timeline(page).locator("article", { hasText: "Acknowledged: looking into it now." }).first();
    await expect(reloaded.locator('[id^="reaction-msg_"][id$="-check"]')).toContainText("1");

    await reloaded.locator('[id^="reaction-msg_"][id$="-check"]').click();
    await expect(reloaded.locator('[id^="reactions-msg_"]')).toHaveCount(0);
    await page.reload();
    await expect(timeline(page).locator('[id^="reaction-msg_"]')).toHaveCount(0);
  });

  test("a reaction in one window appears in another on the same channel", async ({ page, context }) => {
    const post = await answered(page);
    const other = await context.newPage();
    await other.goto(page.url());
    await expect(other.locator("[data-phx-main].phx-connected")).toBeAttached();
    const mirrored = timeline(other).locator("article", { hasText: "Acknowledged: looking into it now." }).first();
    await expect(mirrored).toBeVisible();

    await react(page, post, "tada");
    await expect(mirrored.locator('[id^="reaction-msg_"][id$="-tada"]')).toContainText("1");
    await other.close();
  });

  test("an agent acknowledges with a reaction: a ✅ from @backend and no reply", async ({ page }) => {
    await createChannel(page);
    await send(page, "@backend react if you saw this");

    const mine = timeline(page).locator("article", { hasText: "react if you saw this" }).first();
    const chip = mine.locator('[id^="reaction-msg_"][id$="-check"]');
    await expect(chip).toContainText("1");
    await expect(chip).toHaveAttribute("title", "@backend: done / approved");
    await expect(chip).not.toHaveAttribute("data-mine", "true");
    await expect(working(page)).toHaveCount(0);

    // it passed: nothing was posted for the turn, and the line says so in words
    await expect(timeline(page)).toContainText("@backend had nothing to add");
    await expect(timeline(page)).not.toContainText("passed");
    await expect(timeline(page).locator("article")).toHaveCount(1);
    await expect(timeline(page)).not.toContainText("Reacted instead of replying.");
  });
});
