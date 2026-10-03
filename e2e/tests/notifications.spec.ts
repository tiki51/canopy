import { test, expect, Page } from "@playwright/test";
import { createChannel, send, timeline } from "./helpers";
import { notes, open, setVisible, stubNotifications, turnOn, waiting } from "./notify-helpers";

// Desktop notifications (assets/js/notify.js, CanopyWeb.Notify). The browser's
// Notification API and the tab's visibility are stubbed (notify-helpers.ts).
// The fake OpenCode agent (@backend, the channel owner) asks a question card
// when a message says "ask me". "Work finished" waits for the channel's quiet
// check (3 s outside the test environment). Earlier specs leave cards
// pending in their channels, so counts of what waits are relative.

const card = (page: Page) => page.locator('section[id^="question-"]').first();

const ofKind = async (page: Page, pattern: RegExp) => (await notes(page)).filter(n => pattern.test(n.title));

const both = async (a: Page, b: Page, pattern: RegExp) => [...(await ofKind(a, pattern)), ...(await ofKind(b, pattern))];

async function answer(page: Page) {
  await card(page).getByLabel("Invoice only").check();
  await card(page).locator('[id$="-send"]').click();
  await expect(card(page)).toBeHidden();
  await expect(timeline(page)).toContainText("Going with Invoice only.");
}

test.describe("desktop notifications", () => {
  test("Settings: unsupported without the Notification API", async ({ context, page }) => {
    await stubNotifications(context, { unsupported: true });
    await open(page, "/settings");
    await expect(page.locator("#notify-prefs")).toHaveAttribute("data-state", "unsupported");
    await expect(page.locator("#notify-unsupported")).toBeVisible();
    await expect(page.locator("#notify-enabled")).toBeHidden();
  });

  test("Settings: off by default; the switch asks only when clicked, and is remembered", async ({ context, page }) => {
    await stubNotifications(context);
    await open(page, "/settings");

    const prefs = page.locator("#notify-prefs");
    await expect(prefs).toHaveAttribute("data-state", "off");
    await expect(page.locator("#notify-enabled")).not.toBeChecked();
    await expect(page.locator("#notify-needs_you")).toBeDisabled();
    await expect(page.locator("#notify-test")).toBeDisabled();
    expect(await page.evaluate(() => (window as any).__requests)).toBe(0);

    await page.locator("#notify-enabled").check();
    await expect(prefs).toHaveAttribute("data-state", "on");
    await expect(page.locator("#notify-granted")).toBeVisible();
    expect(await page.evaluate(() => (window as any).__requests)).toBe(1);
    await expect(page.locator("#notify-needs_you")).toBeEnabled();
    await expect(page.locator("#notify-needs_you")).toBeChecked();
    await expect(page.locator("#notify-sound")).not.toBeChecked();

    // a kind turned off, then the master switch: the kinds keep their values
    await page.locator("#notify-work").uncheck();
    await page.locator("#notify-enabled").uncheck();
    await expect(prefs).toHaveAttribute("data-state", "off");
    await expect(page.locator("#notify-needs_you")).toBeDisabled();
    await expect(page.locator("#notify-needs_you")).toBeChecked();

    await page.reload();
    await expect(prefs).toHaveAttribute("data-state", "off");
    await expect(page.locator("#notify-work")).not.toBeChecked();
    await page.locator("#notify-enabled").check();
    await expect(prefs).toHaveAttribute("data-state", "on");
    // granted once: not asked again
    expect(await page.evaluate(() => (window as any).__requests)).toBe(0);

    await page.locator("#notify-test").click();
    await expect.poll(() => notes(page)).toEqual([expect.objectContaining({ tag: "canopy:test", silent: true })]);
  });

  test("Settings: a browser that says no shows how to allow it", async ({ context, page }) => {
    await stubNotifications(context, { answer: "denied" });
    await open(page, "/settings");
    await page.locator("#notify-enabled").click();
    await expect(page.locator("#notify-prefs")).toHaveAttribute("data-state", "blocked");
    await expect(page.locator("#notify-blocked")).toContainText("blocked for this site");
    await expect(page.locator("#notify-enabled")).not.toBeChecked();
  });

  test("needs you: nothing while looking; shown from another page, once; a click opens the card", async ({ context, page }) => {
    await stubNotifications(context);
    await turnOn(page);
    const id = await createChannel(page);

    // looking at the channel: nothing
    await send(page, "ask me about the retry key");
    await expect(card(page)).toBeVisible();
    await page.waitForTimeout(800);
    expect(await notes(page)).toEqual([]);
    await answer(page);

    // elsewhere (visible and focused, another page): shown, silent while sound is off
    await open(page, "/settings");
    const other = await context.newPage();
    await open(other, `/channels/${id}`);
    await setVisible(other, false);
    await send(other, "ask me once more");
    await expect.poll(() => ofKind(page, /needs you/)).toHaveLength(1);
    const [note] = await ofKind(page, /needs you/);
    expect(note.title).toMatch(/^@backend needs you in #chan-/);
    expect(note.body).toBe("Retry key");
    expect(note.tag).toMatch(/^card:/);
    expect(note.silent).toBe(true);
    // the hidden tab did not show it too
    await page.waitForTimeout(500);
    expect(await notes(other)).toEqual([]);
    await other.close();

    // the click goes to the channel and shows the card
    await page.evaluate(() => {
      const shown = (window as any).__instances.find((n: any) => /^card:/.test(n.tag));
      shown.onclick({ preventDefault() {} });
    });
    await expect(page).toHaveURL(new RegExp(`/channels/${id}$`));
    await expect(card(page)).toBeInViewport();
  });

  test("a kind turned off shows nothing of that kind", async ({ context, page }) => {
    await stubNotifications(context);
    await turnOn(page);
    await page.locator("#notify-needs_you").uncheck();
    const id = await createChannel(page);
    await open(page, "/settings");

    const other = await context.newPage();
    await open(other, `/channels/${id}`);
    await setVisible(other, false);
    await send(other, "ask me about the retry key");
    await expect(card(other)).toBeVisible();
    await page.waitForTimeout(800);
    expect(await both(page, other, /needs you/)).toEqual([]);
    await other.close();
  });

  test("the palette flips the master switch, and other tabs follow", async ({ context, page }) => {
    await stubNotifications(context);
    await turnOn(page);
    const second = await context.newPage();
    await open(second, "/settings");
    await expect(second.locator("#notify-prefs")).toHaveAttribute("data-state", "on");

    await open(page, "/agents");
    await page.locator("#cmdk-open").click();
    await page.keyboard.type(">notifications");
    await expect(page.locator("#cmdk-list [aria-selected='true']")).toContainText("Turn desktop notifications off");
    await page.keyboard.press("Enter");
    await expect(page.locator("#flash-info")).toContainText("Desktop notifications are off in this browser.");

    // the Settings tab follows at once
    await expect(second.locator("#notify-prefs")).toHaveAttribute("data-state", "off");
    await expect(second.locator("#notify-enabled")).not.toBeChecked();

    // off: a card nobody is looking at shows nothing, in either tab
    await createChannel(second);
    await setVisible(second, false);
    await send(second, "ask me about the retry key");
    await expect(card(second)).toBeVisible();
    await page.waitForTimeout(800);
    expect(await both(page, second, /needs you/)).toEqual([]);

    // and back on: the wording follows the state, and the other tab too
    await page.locator("#cmdk-open").click();
    await page.keyboard.type(">notifications");
    await expect(page.locator("#cmdk-list [aria-selected='true']")).toContainText("Turn desktop notifications on");
    await page.keyboard.press("Enter");
    await expect(page.locator("#flash-info")).toContainText("Desktop notifications are on in this browser.");
    await expect.poll(() => second.evaluate(() => (window as any).canopyNotifier.status())).toBe("on");
  });

  test("two tabs, both hidden: one notification; one tab looking at the channel: none", async ({ context, page }) => {
    await stubNotifications(context);
    await turnOn(page);
    const id = await createChannel(page);
    await open(page, "/agents");
    const second = await context.newPage();
    await open(second, `/channels/${id}`);

    await setVisible(page, false);
    await setVisible(second, false);
    await send(second, "ask me about the retry key");
    await expect.poll(async () => (await both(page, second, /needs you/)).length).toBe(1);
    await page.waitForTimeout(800);
    expect(await both(page, second, /needs you/)).toHaveLength(1);

    // answered; then another question while the channel's tab is in front
    await setVisible(second, true);
    await answer(second);
    await page.evaluate(() => { (window as any).__notes.length = 0; });
    await second.evaluate(() => { (window as any).__notes.length = 0; });

    await send(second, "ask me again please");
    await expect(card(second)).toBeVisible();
    await page.waitForTimeout(800);
    expect(await both(page, second, /needs you/)).toEqual([]);
  });

  test("work finished: a hidden tab hears that the channel went quiet", async ({ context, page }) => {
    await stubNotifications(context);
    await turnOn(page);
    const id = await createChannel(page);
    await setVisible(page, false);
    await send(page, "have a look at the queue");
    await expect(timeline(page)).toContainText("Acknowledged: looking into it now.");

    await expect.poll(() => ofKind(page, /is done$/), { timeout: 15_000 }).toHaveLength(1);
    const [note] = await ofKind(page, /is done$/);
    expect(note.title).toMatch(/^#chan-.* is done$/);
    expect(note.body).toMatch(/^@backend · 1 turn · \d+ s$/);
    expect(note.tag).toBe(`work:${id}`);
  });

  test("rate limit: four a minute, then one note for the rest", async ({ context, page }) => {
    await stubNotifications(context);
    await turnOn(page);
    await setVisible(page, false);

    const offer = (from: number, to: number) =>
      page.evaluate(({ from, to }) => {
        for (let i = from; i <= to; i++) {
          (window as any).canopyNotifier.offer({
            id: `card:rate-${i}-${Date.now()}`,
            kind: "needs_you",
            channel_id: "ch_elsewhere",
            place: "#elsewhere",
            tag: `card:rate-${i}`,
            title: `Card ${i}`,
            body: "waiting",
            url: "/channels/ch_elsewhere",
          });
        }
      }, { from, to });

    await offer(1, 6);
    await expect.poll(async () => (await notes(page)).map(n => n.tag), { timeout: 5_000 }).toEqual([
      "card:rate-1",
      "card:rate-2",
      "card:rate-3",
      "card:rate-4",
      "canopy:overflow",
    ]);
    expect((await notes(page))[4].title).toBe("2 more updates in Canopy");

    // back in front of Canopy: the limit starts over
    await setVisible(page, true);
    await setVisible(page, false);
    await offer(7, 7);
    await expect.poll(async () => (await notes(page)).map(n => n.tag).at(-1)).toBe("card:rate-7");
  });

  test("a page that wakes up catches up on a card it missed, once", async ({ browser }) => {
    const baseURL = test.info().project.use.baseURL;
    // notifications on in a browser whose tabs start hidden, then no tab open
    const asleep = await browser.newContext({ baseURL });
    await stubNotifications(asleep, { permission: "granted", hidden: true });
    const first = await asleep.newPage();
    await open(first, "/settings");
    await first.evaluate(() => (window as any).canopyNotifier.setPrefs({ enabled: true }));
    await first.close();

    // meanwhile, somewhere else, an agent asks
    const elsewhere = await browser.newContext({ baseURL });
    const other = await elsewhere.newPage();
    await createChannel(other);
    await send(other, "ask me about the retry key");
    await expect(card(other)).toBeVisible();

    // the sleeping browser's tab comes back: one note for what it missed
    // (earlier specs' cards from the last half hour are in it too), once
    const page = await asleep.newPage();
    await open(page, "/agents");
    await expect.poll(() => notes(page)).toHaveLength(1);
    expect((await notes(page))[0].title).toMatch(/needs you|things are waiting on you/);
    await open(page, "/files");
    await page.waitForTimeout(800);
    expect(await notes(page)).toEqual([]);

    await elsewhere.close();
    await asleep.close();
  });

  test("the title counts what waits on you, across pages", async ({ context, page }) => {
    await stubNotifications(context);
    const id = await createChannel(page);
    const before = await waiting(page);
    const prefix = (n: number) => (n > 0 ? new RegExp(`^\\(${n}\\) `) : /^[^(]/);

    await send(page, "ask me about the retry key");
    await expect(card(page)).toBeVisible();
    await expect(page).toHaveTitle(prefix(before + 1));

    await open(page, "/files");
    await expect(page).toHaveTitle(prefix(before + 1));
    await open(page, `/channels/${id}`);
    await expect(page).toHaveTitle(prefix(before + 1));

    await answer(page);
    await expect(page).toHaveTitle(prefix(before));
  });
});
