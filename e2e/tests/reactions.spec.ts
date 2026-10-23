import { test, expect, Page } from "@playwright/test";
import { createChannel, gotoLive, reload, send, timeline } from "./helpers";

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

/** Waits out the "Created #…" toast: it leaves by a synthetic click, which
 * phx-click-away reads as a click outside an open picker. */
async function noToasts(page: Page) {
  await expect(page.locator('[phx-hook="AutoDismiss"]:visible')).toHaveCount(0, { timeout: 10_000 });
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

    await reload(page);
    const reloaded = timeline(page).locator("article", { hasText: "Acknowledged: looking into it now." }).first();
    await expect(reloaded.locator('[id^="reaction-msg_"][id$="-check"]')).toContainText("1");

    await reloaded.locator('[id^="reaction-msg_"][id$="-check"]').click();
    await expect(reloaded.locator('[id^="reactions-msg_"]')).toHaveCount(0);
    await reload(page);
    await expect(timeline(page).locator('[id^="reaction-msg_"]')).toHaveCount(0);
  });

  test("a reaction in one window appears in another on the same channel", async ({ page, context }) => {
    const post = await answered(page);
    const other = await context.newPage();
    await gotoLive(other, page.url());
    const mirrored = timeline(other).locator("article", { hasText: "Acknowledged: looking into it now." }).first();
    await expect(mirrored).toBeVisible();

    await react(page, post, "tada");
    await expect(mirrored.locator('[id^="reaction-msg_"][id$="-tada"]')).toContainText("1");
    await other.close();
  });

  test("the picker names the hovered or focused emoji in its footer", async ({ page }) => {
    const post = await answered(page);
    await noToasts(page);
    await post.hover();
    await post.locator('[id^="react-msg_"]').click();
    const picker = post.locator('[id^="react-picker-"][role="menu"]');
    const footer = picker.locator("[data-picker-footer]");
    await expect(picker.locator('[id$="-work"]')).toHaveText("Work");
    await expect(picker.locator('[id$="-cheer"]')).toHaveText("Thanks & cheers");
    await expect(footer).toHaveText("Pick a reaction");

    // the label is drawn over the footer, not inside the 28px cell: a transform
    // or position between the button and the popover would trap it there
    const hundred = picker.locator('[id$="-hundred"]');
    await hundred.hover();
    const label = hundred.locator("[data-picker-label]");
    await expect(label).toBeVisible();
    await expect(label).toContainText("exactly right");
    const l = (await label.boundingBox())!;
    const f = (await footer.boundingBox())!;
    expect(l.x).toBeGreaterThanOrEqual(f.x - 1);
    expect(l.y).toBeGreaterThanOrEqual(f.y - 1);
    expect(l.x + l.width).toBeLessThanOrEqual(f.x + f.width + 1);
    expect(l.y + l.height).toBeLessThanOrEqual(f.y + f.height + 1);

    await footer.hover();
    await expect(picker.locator("[data-picker-label]:visible")).toHaveCount(0);

    // keyboard focus shows the same label: React, then Tab to the sixth (🙏)
    await post.locator('[id^="react-msg_"]').focus();
    for (let i = 0; i < 6; i++) await page.keyboard.press("Tab");
    await expect(picker.locator('[id$="-pray"]')).toBeFocused();
    await expect(picker.locator('[id$="-pray"] [data-picker-label]')).toContainText("thank you");
    await expect(picker.locator("[data-picker-label]:visible")).toHaveCount(1);
  });

  test("the picker on the newest message opens in view, and the feed stays pinned", async ({ page }) => {
    // a short newest message at the bottom of a full feed: @backend only
    // reacts to it, so nothing is posted after it
    await page.setViewportSize({ width: 1280, height: 480 });
    await answered(page);
    await send(page, "@backend react if you saw this");
    const newest = timeline(page).locator("article").last();
    await expect(newest).toContainText("react if you saw this");
    await expect(newest.locator('[id^="reaction-msg_"][id$="-check"]')).toContainText("1");
    await expect(working(page)).toHaveCount(0);
    await noToasts(page);
    const scroller = page.locator("#timeline-scroll");

    await newest.hover();
    await newest.locator('[id^="react-msg_"]').click();
    const picker = newest.locator('[id^="react-picker-"][role="menu"]');
    const footer = picker.locator("[data-picker-footer]");
    await expect(footer).toBeVisible();
    await expect
      .poll(async () => {
        const f = (await footer.boundingBox())!;
        const s = (await scroller.boundingBox())!;
        return f.y + f.height <= s.y + s.height;
      })
      .toBe(true);
    expect(await scroller.evaluate(el => el.scrollHeight - el.scrollTop - el.clientHeight)).toBeLessThan(48);

    await picker.locator('[id$="-fire"]').click();
    await expect(picker).toBeHidden();
    await expect(newest.locator('[id^="reaction-msg_"][id$="-fire"]')).toContainText("1");
  });

  test("messages below an open picker never take its clicks", async ({ page }) => {
    const post = await answered(page);
    await send(page, "And the refunds?");
    await expect(turns(page)).toHaveCount(2);
    await expect(working(page)).toHaveCount(0);
    await noToasts(page);

    await post.hover();
    await post.locator('[id^="react-msg_"]').click();
    const picker = post.locator('[id^="react-picker-"][role="menu"]');
    await expect(picker).toBeVisible();

    const covered = () =>
      picker.evaluate(menu =>
        [...menu.querySelectorAll('[role="menuitem"]')]
          .filter(button => {
            const r = button.getBoundingClientRect();
            const hit = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
            return !hit || hit.closest('[role="menu"]') !== menu;
          })
          .map(button => button.id)
      );
    expect(await covered()).toEqual([]);

    // over the next message and back: the action bars fade, and still nothing covers it
    await timeline(page).locator("article").last().hover();
    await picker.locator('[id$="-hundred"]').hover();
    expect(await covered()).toEqual([]);
    await picker.locator('[id$="-hundred"]').click();
    await expect(picker).toBeHidden();
    await expect(post.locator('[id^="reaction-msg_"][id$="-hundred"]')).toContainText("1");

    // React twice closes it again
    await post.hover();
    await post.locator('[id^="react-msg_"]').click();
    await expect(picker).toBeVisible();
    await post.locator('[id^="react-msg_"]').click();
    await expect(picker).toBeHidden();
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
