import { test, expect, Page } from "@playwright/test";
import { createChannel, send, timeline, uniq } from "./helpers";

// The app shell is exactly the window: the page itself never scrolls, only the
// columns inside it. And the channel header fits its controls to its width
// (the HeaderFit hook): none is ever clipped, whatever the window, the side
// panel, or a held lock adds; what leaves the row is in the ⋯ menu.

/** The page is no taller and no wider than the window. */
async function expectNoPageScroll(page: Page) {
  await expect
    .poll(() =>
      page.evaluate(() => ({
        height: document.documentElement.scrollHeight - window.innerHeight,
        width: document.documentElement.scrollWidth - window.innerWidth,
      })),
    )
    .toEqual({ height: 0, width: 0 });
}

/** Every header control that shows sits inside the header and the window, and shows all of itself. */
async function expectHeaderFits(page: Page) {
  // the hook settles on resize; wait for one frame after it
  await page.evaluate(() => new Promise(requestAnimationFrame));
  const problems = await page.evaluate(() => {
    const header = document.getElementById("channel-header")!.getBoundingClientRect();
    const out: string[] = [];
    const shown = Array.from(document.querySelectorAll<HTMLElement>("#channel-header-actions > *")).filter(
      (el) => el.id !== "channel-more-menu" && el.getClientRects().length > 0,
    );
    for (const el of shown) {
      const box = el.getBoundingClientRect();
      if (box.left < header.left - 0.5 || box.right > header.right + 0.5 || box.right > window.innerWidth + 0.5)
        out.push(`${el.id} at ${Math.round(box.left)}–${Math.round(box.right)} outside the header (to ${Math.round(header.right)})`);
      if (el.scrollWidth > el.clientWidth + 1) out.push(`${el.id} clips its own label`);
    }
    if (!shown.some((el) => el.id === "stop-all")) out.push("Stop is not showing");
    // the topic is whole, or keeps room for a few words, or gives way: never a
    // stray letter beside the name
    const topic = document.getElementById("channel-topic");
    if (topic && topic.getClientRects().length > 0) {
      const width = topic.getBoundingClientRect().width;
      if (width + 1 < Math.min(topic.scrollWidth, 90)) out.push(`the topic is squeezed to ${Math.round(width)}px`);
    }
    if (!shown.some((el) => el.id === "channel-more")) out.push("the ⋯ button is not showing");
    return out;
  });
  expect(problems).toEqual([]);
}

/** Opens the ⋯ menu and returns the ids of the entries it shows. */
async function menuEntries(page: Page) {
  await page.locator("#channel-more").click();
  const menu = page.locator("#channel-more-menu");
  await expect(menu).toBeVisible();
  const ids = await menu.evaluate((el) =>
    Array.from(el.querySelectorAll<HTMLElement>("button, a"))
      .filter((item) => item.getClientRects().length > 0)
      .map((item) => item.id),
  );
  await page.keyboard.press("Escape");
  await expect(menu).toBeHidden();
  return ids;
}

test.describe("layout", () => {
  // The header spec holds the repository's `tests` lock by hand; whatever
  // happens, later specs find it free.
  let channelPath: string | null = null;
  test.afterEach(async ({ page }) => {
    if (!channelPath) return;
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto(channelPath);
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
    const chip = page.locator("#lock-chip-tests");
    if ((await chip.count()) > 0) {
      await chip.click();
      await page.locator("#force-release-tests", { hasText: "Release" }).click();
      await expect(chip).toBeHidden();
    }
    channelPath = null;
  });

  test("the channel header never clips a control, at 1440 and 1024, with a lock and the thread panel", async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    // a long name and topic, and a held lock, as in the review's screenshots
    channelPath = "/channels/" + (await createChannel(page, uniq("billing-retries-duplicate-charge")));
    await page.locator("#edit-locks").click();
    await page.locator("#take-lock-reason").fill("layout spec");
    await page.locator("#take-lock").click();
    // the locks panel stays open after taking one; the chip closes it
    await page.locator("#lock-chip-tests").click();
    await expect(page.locator("#locks-panel")).toBeHidden();

    await expectHeaderFits(page);
    await expectNoPageScroll(page);
    // at a laptop width the plain buttons are icons with a tooltip, the lock chip keeps its name
    await expect(page.locator("#edit-task")).toHaveAttribute("title", /task/i);
    await expect(page.locator("#lock-chip-tests")).toContainText("tests");
    await expect(page.locator("#stop-all")).toContainText("Stop");
    // Archive is always in the ⋯ menu
    expect(await menuEntries(page)).toContain("archive-channel");

    await page.setViewportSize({ width: 1024, height: 768 });
    await expectHeaderFits(page);
    await expectNoPageScroll(page);

    // the thread panel takes 28rem of the row: the header collapses further
    await send(page, "A root for the layout spec");
    await expect(timeline(page)).toContainText("Acknowledged: looking into it now.");
    const root = timeline(page).locator("article", { hasText: "A root for the layout spec" }).first();
    await root.hover();
    await root.locator('[id^="reply-"]').click();
    await expect(page.locator("#thread-panel")).toBeVisible();
    await expectHeaderFits(page);
    await expectNoPageScroll(page);

    // whatever left the row is in the menu, and works from there
    const entries = await menuEntries(page);
    expect(entries).toEqual(expect.arrayContaining(["archive-channel", "more-edit-task", "more-edit-members"]));
    await page.locator("#channel-more").click();
    await page.locator("#more-edit-task").click();
    await expect(page.locator("#channel-more-menu")).toBeHidden();
    await expect(page.locator("#task-form")).toBeVisible();

    await page.setViewportSize({ width: 1440, height: 900 });
    await expectHeaderFits(page);
    await expectNoPageScroll(page);
  });

  test("Archive from the ⋯ menu asks first, then archives; Reopen brings it back", async ({ page }) => {
    await createChannel(page);
    await page.locator("#channel-more").click();
    await page.locator("#archive-channel").click();
    // the confirmation is a modal dialog; the menu closes under it
    await expect(page.locator("#canopy-confirm")).toBeVisible();
    await expect(page.locator("#channel-more-menu")).toBeHidden();
    await page.locator("#canopy-confirm-ok").click();
    await expect(page.locator("#archived-badge")).toBeVisible();
    await expect(page.locator("#archived-bar")).toBeVisible();

    await page.locator("#reopen-channel").click();
    await expect(page.locator("#archived-badge")).toBeHidden();
    await expect(page.locator("#composer-input")).toBeVisible();
  });

  test("the page never scrolls: a channel with a live turn, Settings, Agents, Search", async ({ page }) => {
    for (const size of [
      { width: 1440, height: 900 },
      { width: 390, height: 844 },
    ]) {
      await page.setViewportSize(size);
      await createChannel(page);
      // enough messages to scroll the feed (the owner answers them; wait until
      // it is idle), then a turn whose live card holds a live region; with the
      // feed scrolled up, that region sits far below the window
      for (let i = 0; i < 12; i++) await send(page, `filler ${i}\n\nsecond line\n\nthird line`);
      await expect(timeline(page)).toContainText("Acknowledged: looking into it now.");
      await expect(page.locator('section[id^="telemetry-"]')).toHaveCount(0, { timeout: 30_000 });
      await send(page, "Run the long activity demo slowly.");
      await expect(page.locator('section[id^="telemetry-"]').first()).toContainText("is testing", { timeout: 30_000 });
      await page.locator("#timeline-scroll").evaluate((el) => (el.scrollTop = 0));
      await expectNoPageScroll(page);

      for (const path of ["/settings", "/agents", "/search?q=filler"]) {
        await page.goto(path);
        await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
        await expectNoPageScroll(page);
      }
    }
  });
});
