import { test, expect, Page } from "@playwright/test";
import { createChannel, send, timeline } from "./helpers";
import { iso, sql } from "./site-helpers";

// The Search page over the fake agent's "activity demo" turn
// (e2e/fake-opencode.mjs), which runs `mix test test/billing`, edits
// activity-demo.txt and posts "Fixed the double charge…".

/** A word no other spec posts, and that tokenizes as one word. */
const word = (prefix: string) => `${prefix}${Date.now().toString(36)}`;

const input = (page: Page) => page.locator("#search-input");
const results = (page: Page) => page.locator("#search-results");

const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/** A ULID for millisecond `ms`, its random part replaced by the counter `n`. */
function ulid(ms: number, n: number) {
  let time = "";
  for (let i = 0, x = ms; i < 10; i++, x = Math.floor(x / 32)) time = CROCKFORD[x % 32] + time;
  let tail = "";
  for (let i = 0, y = n; i < 16; i++, y = Math.floor(y / 32)) tail = CROCKFORD[y % 32] + tail;
  return time + tail;
}

/** More than a page of newer notes in a channel, straight into the e2e database. */
function fillChannel(channelId: string, count: number) {
  const now = Date.now();
  const at = iso(new Date(now));
  const user = "(SELECT id FROM users LIMIT 1)";
  const messages: string[] = [];
  const events: string[] = [];
  for (let i = 0; i < count; i++) {
    const id = ulid(now, i);
    messages.push(`('msg_${id}', '${channelId}', ${user}, 'system', 'filler ${i}', '${at}', '${at}')`);
    events.push(
      `('evt_${id}', '${channelId}', 'message', 'msg_${id}', '{"kind":"system","user_id":null}', '${at}', '${at}')`,
    );
  }
  sql(
    `INSERT INTO messages (id, channel_id, user_id, kind, body, inserted_at, updated_at) VALUES ${messages.join(",")};` +
      `INSERT INTO timeline_events (id, channel_id, event_type, ref_id, payload, inserted_at, updated_at) VALUES ${events.join(",")};`,
  );
}

test.describe("search", () => {
  test("live results find a message and a turn; filters live in the URL; a hit opens highlighted", async ({ page }) => {
    const marker = word("kiwi");
    const channelId = await createChannel(page);
    await send(page, `Run the activity demo for ${marker}.`);
    await expect(timeline(page)).toContainText("Fixed the double charge");

    await page.locator("#rail-search").click();
    await expect(page).toHaveURL(/\/search$/);
    await expect(page.locator("#search-empty")).toBeVisible();
    await expect(input(page)).toBeFocused();

    // part of a word finds the message while typing
    await input(page).pressSequentially(marker.slice(0, -2));
    const message = results(page).locator('a[id^="result-msg_"]').filter({ hasText: "Run the activity demo" });
    await expect(message).toHaveCount(1);
    await expect(message.locator("mark")).toHaveText(marker);
    await expect(page).toHaveURL(new RegExp(`q=${marker.slice(0, -2)}$`));

    // a path finds the turn that changed it
    await input(page).fill("activity-demo.txt");
    const turn = results(page).locator('a[id^="result-evt_"]').first();
    await expect(turn).toBeVisible();
    await expect(turn.locator("mark").first()).toHaveText("activity-demo.txt");

    // narrowing to the channel goes into the URL and survives a reload
    await page.locator("#search-filters_channel").selectOption(channelId);
    await expect(page).toHaveURL(new RegExp(`channel=${channelId}`));
    await expect(results(page).locator('a[id^="result-evt_"]')).toHaveCount(1);
    await page.reload();
    await expect(results(page).locator('a[id^="result-evt_"]')).toHaveCount(1);
    await expect(page.locator("#search-filters_channel")).toHaveValue(channelId);

    // the turn opens in the channel's activity panel
    await results(page).locator('a[id^="result-evt_"]').click();
    await expect(page).toHaveURL(new RegExp(`/channels/${channelId}\\?activity=evt_`));
    await expect(page.locator("#activity-panel")).toBeVisible();

    // the message opens at its row, flashed
    await page.goto(`/search?q=${marker}`);
    const hit = results(page).locator('a[id^="result-msg_"]').first();
    const messageId = (await hit.getAttribute("id"))!.replace("result-", "");
    await hit.click();
    await expect(page).toHaveURL(new RegExp(`/channels/${channelId}\\?msg=${messageId}`));
    const row = timeline(page).locator(`[id^="evt-"]`).filter({ has: page.locator(`#message-${messageId}`) });
    await expect(row).toHaveClass(/search-hit/);
    await expect(page.locator("#jump-to-latest")).toHaveCount(0);
  });

  test("an old hit opens history around it, and Jump to latest comes back", async ({ page }) => {
    const marker = word("fig");
    const channelId = await createChannel(page);
    await send(page, `Note for later: ${marker}.`);
    await expect(timeline(page)).toContainText("Acknowledged: looking into it now.");
    fillChannel(channelId, 120);

    await page.goto(`/search?q=${marker}`);
    const hit = results(page).locator('a[id^="result-msg_"]').first();
    const messageId = (await hit.getAttribute("id"))!.replace("result-", "");
    await hit.click();

    await expect(page.locator(`#message-${messageId}`)).toBeVisible();
    await expect(page.locator("#jump-to-latest")).toBeVisible();
    await expect(page.locator("#load-newer")).toBeAttached();
    await expect(timeline(page)).not.toContainText("filler 119");

    await page.locator("#jump-to-latest").click();
    await expect(page.locator("#jump-to-latest")).toHaveCount(0);
    await expect(timeline(page)).toContainText("filler 119");
    await expect(page.locator(`#message-${messageId}`)).toHaveCount(0);
  });

  test("the command palette hands a query over to Search", async ({ page }) => {
    await page.goto("/settings");
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();

    const open = async () => {
      await page.locator("#cmdk-open").click();
      await expect(page.locator("#cmdk-dialog")).toBeVisible();
      await expect(page.locator("#cmdk-input")).toBeFocused();
    };

    // with name matches, Search is the last row
    await open();
    await page.keyboard.type("repo");
    await expect(page.locator("#cmdk-list [role=option]").last()).toContainText("Search everywhere for “repo”");
    await page.keyboard.press("Escape");

    // with none, Shift+Enter searches
    await open();
    await page.keyboard.type("qqzzxxnothing");
    await expect(page.locator("#cmdk-empty")).toContainText("⇧↵ searches");
    await page.keyboard.press("Shift+Enter");
    await expect(page).toHaveURL(/\/search\?q=qqzzxxnothing$/);
    await expect(page.locator("#search-none")).toBeVisible();
  });

  test("at phone width the filters fold into a disclosure", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto("/search?q=billing&sort=newest");

    await expect(page.locator("#search-filters-body")).toBeHidden();
    await expect(page.locator("#search-filters-toggle")).toContainText("Filters (1)");
    await page.locator("#search-filters-toggle").click();
    await expect(page.locator("#search-filters_sort")).toBeVisible();
    await expect(page.locator("#search-filters_sort")).toHaveValue("newest");

    // no sideways scroll
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    expect(overflow).toBeLessThanOrEqual(0);
  });
});
