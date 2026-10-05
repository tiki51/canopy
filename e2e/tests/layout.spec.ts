import { test, expect, Page } from "@playwright/test";
import { createChannel, send, timeline, uniq } from "./helpers";

// The app shell is exactly the window: the page itself never scrolls, only the
// columns inside it. And the channel header fits its one row to its width
// (the HeaderFit hook): nothing is ever clipped, whatever the window, the side
// panel (Details narrows the header), or a held lock adds; what leaves the
// row is in Details.

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
  // the hook settles on resize; wait for a frame after it
  await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
  const problems = await page.evaluate(() => {
    const header = document.getElementById("channel-header")!.getBoundingClientRect();
    const row = document.getElementById("channel-header-row")!;
    const out: string[] = [];
    if (row.scrollWidth > row.clientWidth + 1) out.push(`the row overflows: ${row.scrollWidth} > ${row.clientWidth}`);
    const shown = Array.from(document.querySelectorAll<HTMLElement>("#channel-header-actions > *")).filter(
      (el) => el.getClientRects().length > 0,
    );
    for (const el of shown) {
      const box = el.getBoundingClientRect();
      if (box.left < header.left - 0.5 || box.right > header.right + 0.5 || box.right > window.innerWidth + 0.5)
        out.push(`${el.id} at ${Math.round(box.left)}–${Math.round(box.right)} outside the header (to ${Math.round(header.right)})`);
      if (el.scrollWidth > el.clientWidth + 1) out.push(`${el.id} clips its own label`);
    }
    for (const id of ["stop-all", "toggle-details"])
      if (!shown.some((el) => el.id === id)) out.push(`#${id} is not showing`);
    // the topic is whole, or keeps room for a few words, or gives way: never a
    // stray letter beside the name
    const topic = document.getElementById("channel-topic");
    if (topic && topic.getClientRects().length > 0) {
      const width = topic.getBoundingClientRect().width;
      if (width + 1 < Math.min(topic.scrollWidth, 90)) out.push(`the topic is squeezed to ${Math.round(width)}px`);
    }
    // the name never vanishes to its "#"
    const name = document.getElementById("channel-name")!.getBoundingClientRect().width;
    if (name < 60) out.push(`the channel name is squeezed to ${Math.round(name)}px`);
    return out;
  });
  expect(problems).toEqual([]);
}

const fit = (page: Page) => page.locator("#channel-header").getAttribute("data-fit");

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

  test("the channel header never clips: 1440 and 1024, with a lock, Details, and the thread panel", async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    // a long name and topic, and a held lock, as in the review's screenshots
    channelPath = "/channels/" + (await createChannel(page, uniq("billing-retries-duplicate-charge")));
    await page.evaluate(() => localStorage.removeItem("canopy:channel-details"));
    await page.locator("#toggle-details").click();
    await page.locator("#take-lock-toggle").click();
    await page.locator("#take-lock-reason").fill("layout spec");
    await page.locator("#take-lock").click();
    await expect(page.locator("#lock-chip-tests")).toBeVisible();
    await page.locator("#toggle-details").click();
    await expect(page.locator("#details-panel")).toBeHidden();

    // Details closed at 1440: every control keeps its label
    await expectHeaderFits(page);
    await expectNoPageScroll(page);
    await expect(page.locator("#lock-chip-tests")).toContainText("tests");
    await expect(page.locator("#open-changes")).toContainText("Changes");
    await expect(page.locator("#toggle-details")).toContainText("Details");
    await expect(page.locator("#stop-all")).toContainText("Stop");

    // Details open narrows the header: it collapses, nothing clips, Stop stays
    await page.locator("#toggle-details").click();
    await expect(page.locator("#details-panel")).toBeVisible();
    await expectHeaderFits(page);
    await expectNoPageScroll(page);
    expect(await fit(page)).toContain("rest-icons");
    await expect(page.locator("#stop-all")).toBeVisible();
    // icon-only controls keep a name and a tooltip
    await expect(page.locator("#toggle-details")).toHaveAttribute("aria-expanded", "true");
    await expect(page.locator("#open-changes")).toHaveAttribute("title", /changes/i);

    await page.setViewportSize({ width: 1024, height: 768 });
    await expectHeaderFits(page);
    await expectNoPageScroll(page);

    // the thread panel takes the slot: Details closes, and stays closed after
    await send(page, "A root for the layout spec");
    await expect(timeline(page)).toContainText("Acknowledged: looking into it now.");
    const root = timeline(page).locator("article", { hasText: "A root for the layout spec" }).first();
    await root.hover();
    await root.locator('[id^="reply-"]').click();
    await expect(page.locator("#thread-panel")).toBeVisible();
    await expect(page.locator("#details-panel")).toBeHidden();
    await expectHeaderFits(page);
    await expectNoPageScroll(page);
    await page.locator("#thread-panel-close").click();
    await expect(page.locator("#thread-panel")).toBeHidden();
    await expect(page.locator("#details-panel")).toBeHidden();

    // a chip opens Details at its section
    await page.locator("#lock-chip-tests").click();
    await expect(page.locator("#details-locks")).toBeInViewport();
    await expect(page.locator("#lock-tests")).toContainText("layout spec");

    await page.setViewportSize({ width: 1440, height: 900 });
    await expectHeaderFits(page);
    await expectNoPageScroll(page);
  });

  test("below lg Details is a full-screen overlay with Back, and never opens by itself", async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    const path = "/channels/" + (await createChannel(page));
    // remembered open from lg up
    await page.locator("#toggle-details").click();
    await expect(page.locator("#details-panel")).toBeVisible();
    await page.reload();
    await expect(page.locator("#details-panel")).toBeVisible();

    await page.setViewportSize({ width: 800, height: 900 });
    await page.goto(path);
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
    await expect(page.locator("#details-panel")).toBeHidden();
    await expectHeaderFits(page);

    await page.locator("#toggle-details").click();
    const panel = page.locator("#details-panel");
    await expect(page.locator("#details-panel-back")).toBeVisible();
    await expect(page.locator("#details-panel-close")).toBeHidden();
    await expect
      .poll(() => panel.evaluate((el) => { const b = el.getBoundingClientRect(); return [b.left, b.width]; }))
      .toEqual([0, 800]);
    await page.locator("#details-panel-back").click();
    await expect(panel).toBeHidden();

    await page.setViewportSize({ width: 390, height: 844 });
    await expectHeaderFits(page);
    await expectNoPageScroll(page);
  });

  test("Archive in Details asks first, then archives; Reopen brings it back", async ({ page }) => {
    await createChannel(page);
    await page.locator("#toggle-details").click();
    await page.locator("#archive-channel").click();
    await expect(page.locator("#canopy-confirm")).toBeVisible();
    await page.locator("#canopy-confirm-ok").click();
    await expect(page.locator("#archived-badge")).toBeVisible();
    await expect(page.locator("#archived-bar")).toBeVisible();
    await expect(page.locator("#archive-channel")).toBeHidden();

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
