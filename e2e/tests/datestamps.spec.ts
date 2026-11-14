import { test, expect, Locator, Page } from "@playwright/test";
import { clickHeader, createChannel, gotoLive, reload, send, timeline, uniq } from "./helpers";
import { iso, localAt, sql } from "./site-helpers";

// Dated stamps on older messages (`stamp_text/2` in timeline_components.ex):
// `21:48` today, `Yesterday 21:48`, `Thu 17:22` for 2–6 days ago, then
// `Oct 21, 16:40`, with the year for past years. Rows are posted through the
// UI, then moved back in time in the database and the page reloaded (stream
// items don't re-render). `localAt` picks local wall-clock times, so every
// expected stamp is exact on any run date.

const offsetMin = Number(process.env.SITE_UTC_OFFSET_MIN ?? -new Date().getTimezoneOffset());
const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** The server's local wall clock for `d`, read with the getUTC* methods. */
const wall = (d: Date) => new Date(d.getTime() + offsetMin * 60_000);
const pad = (n: number) => String(n).padStart(2, "0");
const hm = (w: Date) => `${pad(w.getUTCHours())}:${pad(w.getUTCMinutes())}`;
const day = (w: Date) => Date.UTC(w.getUTCFullYear(), w.getUTCMonth(), w.getUTCDate());

/** What the stamp for `d` should read, by the design's rule. */
function stampText(d: Date): string {
  const w = wall(d);
  const today = wall(new Date());
  const diff = Math.round((day(today) - day(w)) / 86_400_000);
  const date = `${MONTHS[w.getUTCMonth()]} ${w.getUTCDate()}`;
  if (diff === 0) return hm(w);
  if (diff === 1) return `Yesterday ${hm(w)}`;
  if (diff >= 2 && diff <= 6) return `${DAYS[w.getUTCDay()].slice(0, 3)} ${hm(w)}`;
  if (w.getUTCFullYear() === today.getUTCFullYear()) return `${date}, ${hm(w)}`;
  return `${date}, ${w.getUTCFullYear()}, ${hm(w)}`;
}

const stampTitle = (d: Date) => {
  const w = wall(d);
  return `${DAYS[w.getUTCDay()]}, ${MONTHS[w.getUTCMonth()]} ${w.getUTCDate()}, ${w.getUTCFullYear()} at ${hm(w)}`;
};

const backdate = (table: "messages" | "timeline_events", id: string, d: Date) =>
  sql(`UPDATE ${table} SET inserted_at='${iso(d)}', updated_at='${iso(d)}' WHERE id='${id}'`);

/** The stamp under `scope`: text, readable title, and the instant in datetime. */
async function expectStamp(scope: Locator, d: Date) {
  const time = scope.locator("time").first();
  await expect(time).toHaveText(stampText(d));
  await expect(time).toHaveAttribute("title", stampTitle(d));
  const datetime = await time.getAttribute("datetime");
  expect(new Date(datetime!).getTime()).toBe(d.getTime());
}

const message = (page: Page, text: string) => timeline(page).locator('article[id^="message-"]', { hasText: text }).first();
const idOf = async (el: Locator, prefix: string) => (await el.getAttribute("id"))!.slice(prefix.length);
const acks = (page: Page) => timeline(page).locator("article", { hasText: "Acknowledged: looking into it now." });

/** Posts each text as the user and waits for @backend's answer to all of them; returns the message ids. */
async function post(page: Page, texts: string[]): Promise<string[]> {
  const ids: string[] = [];
  for (const [i, text] of texts.entries()) {
    await send(page, text);
    ids.push(await idOf(message(page, text), "message-"));
    await expect(acks(page)).toHaveCount(i + 1);
  }
  await expect(page.locator('section[id^="telemetry-"]')).toHaveCount(0);
  return ids;
}

test.describe("dated stamps", () => {
  test("the feed words each band, dates the tooltip, and keeps a live message as the time", async ({ page }) => {
    await createChannel(page);
    const bands = [localAt(0, 0, 5), localAt(-1, 21, 48), localAt(-3, 17, 22), localAt(-10, 16, 40), localAt(-400, 9, 12)];
    const texts = bands.map((_, i) => `band ${i}`);
    const ids = await post(page, texts);
    ids.forEach((id, i) => backdate("messages", id, bands[i]));
    await reload(page);

    // expectStamp works out each band from the clock when it runs, so a run that crosses midnight still agrees
    for (const [i, id] of ids.entries()) await expectStamp(page.locator(`#message-${id}`), bands[i]);

    // the tooltip is the title attribute, readable rather than ISO
    await page.locator(`#message-${ids[1]} time`).hover();
    await expect(page.locator(`#message-${ids[1]} time`)).not.toHaveAttribute("title", /^\d{4}-\d{2}-\d{2}T/);

    // a message that arrives now, without a reload, is just its own time of day
    await send(page, "arrived live");
    const live = message(page, "arrived live").locator("time");
    const liveAt = new Date((await live.getAttribute("datetime"))!);
    await expect(live).toHaveText(hm(wall(liveAt)));
  });

  test("at phone width an agent's header stays one line: stamp, receipt chip, no blank row", async ({ page }) => {
    await createChannel(page);
    await post(page, ["Is the checkout fix in?"]);
    const answer = acks(page).first();
    const answerId = await idOf(answer, "message-");
    const at = localAt(-400, 9, 13);
    backdate("messages", answerId, at);
    await page.setViewportSize({ width: 390, height: 844 });
    await reload(page);
    await page.mouse.move(0, 0);
    await expectStamp(page.locator(`#message-${answerId}`), at);
    expect(await page.evaluate(() => matchMedia("(hover: hover)").matches)).toBe(true);

    // the longest stamp beside the receipt chip (compact feed, the default)
    const header = page.locator(`#message-${answerId} time`).locator("xpath=..");
    await expect(header.locator(".receipt-chip")).toBeVisible();
    const fit = await header.evaluate((row) => {
      const lines = (el: Element) => Math.round(el.getBoundingClientRect().height / parseFloat(getComputedStyle(el).lineHeight));
      const name = row.firstElementChild!;
      return {
        stamp: lines(row.querySelector("time")!),
        chip: lines(row.querySelector(".receipt-chip")!),
        // one line is ~21px; the hover actions wrapping onto their own line made it ~38px
        oneRow: row.getBoundingClientRect().height < 1.5 * parseFloat(getComputedStyle(name).lineHeight),
      };
    });
    expect(fit).toEqual({ stamp: 1, chip: 1, oneRow: true });
  });

  test("a DM dates its messages", async ({ page }) => {
    await gotoLive(page, "/");
    await page.locator("#sidebar-new-dm").click();
    await expect(page.locator("#dm-picker-dialog")).toBeVisible();
    await page.locator("#dm-agents label", { hasText: "@backend" }).first().click();
    const before = page.url();
    await page.locator("#open-dm").click();
    await expect(page).not.toHaveURL(before);
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();

    const text = uniq("dm two days back");
    await send(page, text);
    const id = await idOf(message(page, text), "message-");
    await expect(page.locator('section[id^="telemetry-"]')).toHaveCount(0, { timeout: 15_000 });
    const at = localAt(-2, 8, 30);
    backdate("messages", id, at);
    await reload(page);
    await expectStamp(page.locator(`#message-${id}`), at);
  });

  test("the thread panel and the Threads page date the root and its reply", async ({ page }) => {
    await createChannel(page);
    const [rootId] = await post(page, ["Which cache scope for priceCart?"]);

    const root = page.locator(`#message-${rootId}`);
    await root.hover();
    await root.locator('[id^="reply-"]').click();
    await expect(page.locator("#thread-panel")).toBeVisible();
    const input = page.locator("#thread-composer-input");
    await input.fill("Take your time and look at the session code.");
    await input.press("Enter");
    await expect(page.locator("#thread-replies")).toContainText("Answering in the thread");
    await expect(page.locator('section[id^="telemetry-"]')).toHaveCount(0);

    const reply = page.locator('#thread-replies article[id^="thread-msg-"]', { hasText: "Take your time" }).first();
    const replyId = await idOf(reply, "thread-msg-");
    const rootAt = localAt(-10, 9, 15);
    const replyAt = localAt(-3, 14, 2);
    backdate("messages", rootId, rootAt);
    backdate("messages", replyId, replyAt);
    await reload(page);

    await expectStamp(page.locator(`#thread-msg-${replyId}`), replyAt);
    await expectStamp(page.locator(`#thread-msg-${rootId}`), rootAt);
    await expectStamp(page.locator(`#message-${rootId}`), rootAt);

    await gotoLive(page, "/threads");
    const row = page.locator(`#thread-row-${rootId}`);
    await expect(row).toBeVisible();
    await expectStamp(row.locator("li", { hasText: "Take your time" }), replyAt);
  });

  test("a turn card and a system line carry the date; the card's stamp fits at 390px", async ({ page }) => {
    await createChannel(page);
    await post(page, ["A quick note for the team."]);
    await clickHeader(page, "edit-brief");
    await page.locator("#brief-form textarea").fill("Goal: dated stamps.");
    await page.locator("#save-brief").click();
    await expect(page.locator("#brief-form")).toHaveCount(0);
    const line = timeline(page).locator('[id^="line-"]', { hasText: "updated the channel brief" }).first();
    const lineId = await idOf(line, "line-");

    const toggle = timeline(page).locator('[id^="turn-toggle-"]').first();
    const turnId = await idOf(toggle, "turn-toggle-");
    const turnAt = localAt(-400, 9, 12);
    const lineAt = localAt(-1, 7, 45);
    backdate("timeline_events", turnId, turnAt);
    backdate("timeline_events", lineId, lineAt);
    await reload(page);
    // the compact feed (the default) hides routine turn cards: show all activity
    await clickHeader(page, "toggle-activity");
    await expect(page.locator(`#turn-toggle-${turnId}`)).toBeVisible();

    await expectStamp(page.locator(`#turn-toggle-${turnId}`), turnAt);
    await expectStamp(page.locator(`#line-${lineId}`), lineAt);

    // the longest stamp (a past year) is whole beside the chevron at phone width
    await page.setViewportSize({ width: 390, height: 844 });
    const stamp = page.locator(`#turn-toggle-${turnId} time`);
    await expect(stamp).toBeVisible();
    const fit = await stamp.evaluate((el) => {
      const r = el.getBoundingClientRect();
      const box = el.closest("button")!.getBoundingClientRect();
      return { clipped: el.scrollWidth > el.clientWidth + 1, inside: r.left >= box.left && r.right <= box.right + 0.5, lines: Math.round(r.height / parseFloat(getComputedStyle(el).lineHeight)) };
    });
    expect(fit).toEqual({ clipped: false, inside: true, lines: 1 });
  });

  test("a playbook sign-off's resolved line is dated", async ({ page }) => {
    const name = uniq("ds-check");
    await gotoLive(page, "/playbooks/new/blank");
    await page.locator("#about-title").fill(name);
    await page.locator("#about-description").fill("A three-step check for dated stamps.");
    await page.locator("#step-s1-title").fill("Build");
    await page.locator("#add-owner-s1").click();
    await page.locator("#owner-agent-frontend").click();
    await page.keyboard.press("Escape");
    await page.locator("#add-step").click();
    await page.locator("#preset-lead").click();
    await page.locator("#step-s2-title").fill("Plan");
    await page.locator("#add-step").click();
    await page.locator("#preset-sign_off").click();
    await page.locator("#step-s3-title").fill("Sign-off");
    await page.locator("#grip-s2").focus();
    await page.keyboard.press("Space");
    await page.keyboard.press("ArrowUp");
    await page.keyboard.press("Space");
    await expect(page.locator("#builder-step-list > li").first()).toHaveAttribute("data-title", "Plan");
    await page.locator("#save-playbook").click();
    await expect(page.locator("#save-state")).toContainText("Saved");

    const channel = await createChannel(page);
    await send(page, `@backend run the ${name} playbook`);
    const card = page.locator('section[id^="signoff-so_"]');
    await expect(card).toBeVisible({ timeout: 30_000 });
    const so = (await card.getAttribute("id"))!.replace(/^signoff-/, "");
    await card.locator('[id$="-accept"]').click();
    await expect(timeline(page)).toContainText("Signed off; closing the run.");
    await expect(page.locator('section[id^="telemetry-"]')).toHaveCount(0);

    const eventId = sql(
      `SELECT id FROM timeline_events WHERE channel_id='${channel}' AND event_type='signoff_resolved' AND ref_id='${so}'`
    );
    expect(eventId).not.toBe("");
    const at = localAt(-5, 18, 20);
    backdate("timeline_events", eventId, at);
    await reload(page);
    await expectStamp(page.locator(`#signoff-resolved-${so}`), at);
  });
});
