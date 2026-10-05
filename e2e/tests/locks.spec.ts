import { test, expect, Page } from "@playwright/test";
import { createChannel, send, timeline, clickHeader } from "./helpers";

// Locks on a repository's shared resources. The fake OpenCode asks for a lock
// when a message says "take the <name> lock" (and holds it across turns with
// "and keep it"); queued, it ends its turn, and the grant wake Canopy sends
// later runs the suite and ends, which frees the lock.

const chip = (page: Page) => page.locator("#lock-chip-tests");

/** Clicks a control guarded by data-canopy-confirm and confirms the dialog. */
async function clickConfirmed(page: Page, selector: string) {
  await page.locator(selector).click();
  await expect(page.locator("#canopy-confirm")).toBeVisible();
  await page.locator("#canopy-confirm-ok").click();
}

test.describe("locks", () => {
  test("a queued agent is woken when the holder's lock is force-released", async ({ page }) => {
    await createChannel(page);
    await expect(chip(page)).toBeHidden();

    await send(page, "@backend take the tests lock and keep it");
    await expect(chip(page)).toContainText("@backend");

    await send(page, "@frontend take the tests lock");
    await expect(chip(page)).toContainText("next: @frontend");
    await expect(timeline(page)).toContainText("@frontend is waiting for the `tests` lock held by @backend (1st in line)");
    // an agent in line for a lock marks the Details button
    await expect(page.locator("#details-dot")).toBeVisible();

    // the chip opens Details › Locks: holder, reason, the line, and Force release
    await chip(page).click();
    await expect(page.locator("#details-locks #locks-panel")).toBeVisible();
    await expect(page.locator('#members [id$="-lock"]')).toHaveCount(1);
    await expect(page.locator('#members [id$="-lock-queued"]')).toHaveCount(1);
    await expect(page.locator("#lock-tests-holder")).toContainText("@backend");
    await expect(page.locator("#lock-tests")).toContainText("e2e run");
    await expect(page.locator("#lock-tests")).toContainText("across turns");
    await expect(page.locator("#lock-tests-queue")).toContainText("@frontend");

    await clickConfirmed(page, "#force-release-tests");

    // the lock passes to @frontend, which is woken, runs the suite, and ends its turn
    await expect(timeline(page)).toContainText("the `tests` lock passed to @frontend");
    await expect(timeline(page)).toContainText("Ran the suite with the tests lock: 42 tests, 0 failures.");
    await expect(chip(page)).toBeHidden();
    await expect(page.locator("#locks-empty")).toBeVisible();
  });

  test("a lock the user holds by hand makes agents wait until it is released", async ({ page }) => {
    await createChannel(page);

    await clickHeader(page, "take-lock-toggle");
    await page.locator("#take-lock-reason").fill("testing by hand");
    await page.locator("#take-lock").click();
    await expect(chip(page)).toBeVisible();
    await expect(page.locator("#lock-tests")).toContainText("testing by hand");

    await send(page, "@frontend take the tests lock");
    await expect(page.locator("#lock-tests-queue")).toContainText("@frontend");
    await expect(chip(page)).toContainText("next: @frontend");
    await expect(timeline(page)).toContainText("@frontend is waiting for the `tests` lock held by You (1st in line)");

    // the user's own lock is released without a confirmation
    await page.locator("#force-release-tests", { hasText: "Release" }).click();
    await expect(timeline(page)).toContainText("Ran the suite with the tests lock: 42 tests, 0 failures.");
    await expect(chip(page)).toBeHidden();
  });
});
