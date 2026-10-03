import { test, expect, Page } from "@playwright/test";
import { createChannel, send, timeline, uniq } from "./helpers";

const layer = (page: Page) => page.locator("#composer-highlight");
const chips = (page: Page, kind: string) => layer(page).locator(`[data-kind="${kind}"]`);

test.describe("composer highlight", () => {
  test("mentions, outsiders, teams and channels are marked as you type", async ({ page }) => {
    const other = uniq("hl-ref");
    await createChannel(page, other);
    await createChannel(page);
    const input = page.locator("#composer-input");

    // take @reviewer out of the channel: its mention would wake nobody
    await page.locator("#edit-members").click();
    const reviewerRow = page
      .locator('[id^="member-row-"]')
      .filter({ has: page.getByText("@reviewer", { exact: true }) });
    await reviewerRow.locator('[id^="remove-member-"]').click();
    await expect(reviewerRow).toHaveCount(0);

    await input.fill(`@backend and @reviewer see #${other} and @nobody`);
    await expect(chips(page, "mention")).toHaveText(["@backend"]);
    await expect(chips(page, "outsider")).toHaveText(["@reviewer"]);
    await expect(chips(page, "channel")).toHaveText([`#${other}`]);
    await expect(layer(page).locator("[data-kind]")).toHaveCount(3);
    await expect(layer(page)).toHaveAttribute("aria-hidden", "true");
    expect((await layer(page).textContent())!.replace(/​$/, "")).toBe(await input.inputValue());

    // adding @reviewer back, without touching the draft, makes it a mention
    const option = page.locator("#add-member-select option", { hasText: "@reviewer ·" });
    await page.locator("#add-member-select").selectOption((await option.getAttribute("value"))!);
    await page.locator("#add-member").click();
    await expect(chips(page, "mention")).toHaveText(["@backend", "@reviewer"]);
    await expect(chips(page, "outsider")).toHaveCount(0);

    // a team counts like its members; code never wakes, so it is never marked
    await input.fill("@bugfix-team look, not `@backend`\n```\n@test\n```");
    await expect(chips(page, "mention")).toHaveText(["@bugfix-team"]);
    await expect(layer(page).locator("[data-kind]")).toHaveCount(1);

    await input.fill("/stop @backend");
    await expect(chips(page, "command")).toHaveText(["/stop"]);
    await expect(chips(page, "mention")).toHaveCount(0);
  });

  test("the layer stays aligned and scrolled with the textarea, and clears on send", async ({ page }) => {
    await createChannel(page);
    const input = page.locator("#composer-input");

    // a mention on the third line sits on the third line of the textarea
    await input.fill("first\nsecond\nhi @backend");
    const chip = chips(page, "mention").first();
    await expect(chip).toHaveText("@backend");
    const metrics = await input.evaluate(el => {
      const style = getComputedStyle(el);
      return {
        top: el.getBoundingClientRect().top,
        padding: parseFloat(style.paddingTop),
        line: parseFloat(style.lineHeight),
      };
    });
    const chipTop = (await chip.boundingBox())!.y;
    const expected = metrics.top + metrics.padding + 2 * metrics.line;
    expect(Math.abs(chipTop - expected)).toBeLessThan(metrics.line);

    // 30 lines overflow the auto-grown height; the layer scrolls with it
    const lines = Array.from({ length: 30 }, (_, i) => `line ${i + 1} @backend`).join("\n");
    await input.fill(lines);
    await input.evaluate(el => (el.scrollTop = el.scrollHeight));
    await expect
      .poll(() =>
        page.evaluate(() => {
          const area = document.getElementById("composer-input")!;
          const copy = document.getElementById("composer-highlight")!;
          return area.scrollTop > 0 && copy.scrollTop === area.scrollTop && copy.clientWidth === area.clientWidth;
        }),
      )
      .toBe(true);

    // (a draft ending in a mention would open the autocomplete, and Enter picks)
    await send(page, "done, @backend thanks");
    await expect(timeline(page)).toContainText("done, @backend thanks");
    await expect(input).toHaveValue("");
    await expect(layer(page).locator("[data-kind]")).toHaveCount(0);
  });

  test("a command typed in a thread is marked invalid", async ({ page }) => {
    await createChannel(page);
    await send(page, "thread root for the highlight");
    const root = timeline(page).locator("article", { hasText: "thread root for the highlight" }).first();
    await root.hover();
    await root.locator('[id^="reply-"]').click();
    await expect(page.locator("#thread-panel")).toBeVisible();

    // the thread panel's composer has its own layer, fed by the same hook
    const threadLayer = page.locator("#thread-composer-highlight");
    await page.locator("#thread-composer-input").fill("/i @reviewer");
    await expect(threadLayer.locator('[data-kind="invalid"]')).toHaveText(["/i"]);
    await expect(threadLayer.locator('[data-kind="command"]')).toHaveCount(0);

    // the channel's composer is not a thread: the same command is a command there
    await page.locator("#composer-input").fill("/i @reviewer");
    await expect(chips(page, "command")).toHaveText(["/i"]);
  });
});
