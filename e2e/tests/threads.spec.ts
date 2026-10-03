import { test, expect, Page } from "@playwright/test";
import { createChannel, send, timeline } from "./helpers";

const panel = (page: Page) => page.locator("#thread-panel");
const replies = (page: Page) => page.locator("#thread-replies");

async function reply(page: Page, text: string) {
  const input = page.locator("#thread-composer-input");
  await input.fill(text);
  await input.press("Enter");
}

/** A channel with one root message from the user, and its thread open in the panel. */
async function openThread(page: Page, rootText: string) {
  await createChannel(page);
  await send(page, rootText);
  // the owner answers the root in the channel first; wait for its turn to end
  await expect(timeline(page)).toContainText("Acknowledged: looking into it now.");
  await expect(page.locator('details[id^="telemetry-"]')).toHaveCount(0);

  const root = timeline(page).locator("article", { hasText: rootText }).first();
  await root.hover();
  await root.locator('[id^="reply-"]').click();
  await expect(panel(page)).toBeVisible();
  await expect(page).toHaveURL(/\?thread=msg_/);
  return root;
}

test.describe("threads", () => {
  test("a reply in the panel wakes the agent, which answers in the thread; its live card stays there", async ({ page }) => {
    await openThread(page, "Which cache scope for priceCart?");

    await reply(page, "Take your time and look at the session code.");
    await expect(replies(page)).toContainText("Take your time and look at the session code.");

    // the agent works for the thread: its live card is in the panel, not the feed
    await expect(panel(page).locator('details[id^="telemetry-"]')).toBeVisible();
    await expect(page.locator('#timeline-scroll > details[id^="telemetry-"]')).toHaveCount(0);
    await expect(page.locator('[id^="thread-working-"]')).toContainText("@backend is replying");

    // it answers with canopy_thread_reply: in the thread, not in the channel feed
    await expect(replies(page)).toContainText("Answering in the thread: per-request caching is the safe option.");
    await expect(timeline(page)).not.toContainText("Answering in the thread");
    await expect(panel(page).locator('details[id^="telemetry-"]')).toHaveCount(0);

    // the feed keeps the root and its summary row, which opens the thread again
    const summary = page.locator('[id^="thread-summary-"]');
    await expect(summary).toContainText("2 replies");
    await page.locator("#thread-panel-close").click();
    await expect(panel(page)).toBeHidden();
    await summary.click();
    await expect(panel(page)).toBeVisible();
    await expect(replies(page)).toContainText("Answering in the thread");
  });

  test("Also send to channel shows a reply in the thread and in the feed", async ({ page }) => {
    await openThread(page, "Which width should the layout use?");

    await page.locator("#thread-also-send").check();
    await reply(page, "Decided on 390px; tell the channel when it is in.");

    // the user's reply, and the agent's (it was asked to tell the channel), in both places
    await expect(replies(page)).toContainText("Decided on 390px");
    await expect(timeline(page)).toContainText("Decided on 390px");
    await expect(timeline(page)).toContainText("replied to a thread");
    await expect(replies(page)).toContainText("Answering in the thread");
    await expect(timeline(page)).toContainText("Answering in the thread");
    await expect(page.locator("#thread-also-send")).not.toBeChecked();
  });

  test("a reload with ?thread= restores the panel, and Esc closes it", async ({ page }) => {
    await openThread(page, "Does the reload keep the thread?");
    const url = page.url();

    await page.reload();
    await expect(page).toHaveURL(url);
    await expect(panel(page)).toBeVisible();
    await expect(panel(page)).toContainText("Does the reload keep the thread?");

    // Esc with a draft keeps the panel; with an empty box it closes it
    const input = page.locator("#thread-composer-input");
    await input.fill("half a thought");
    await input.press("Escape");
    await expect(panel(page)).toBeVisible();
    await input.fill("");
    await input.press("Escape");
    await expect(panel(page)).toBeHidden();
    await expect(page).not.toHaveURL(/thread=/);
  });

  test("on a phone the panel is a full-screen overlay with Back", async ({ page }) => {
    await openThread(page, "Phone-sized thread");
    const url = page.url();

    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto(url);
    await expect(panel(page)).toBeVisible();

    // it slides in from the right, then covers the whole screen
    await expect.poll(async () => (await panel(page).boundingBox())!.x).toBe(0);
    const box = (await panel(page).boundingBox())!;
    expect(box.width).toBe(390);
    expect(box.height).toBe(844);
    await expect(page.locator("#composer-input")).toBeHidden();
    await expect(page.locator("#thread-panel-close")).toBeHidden();

    await page.locator("#thread-panel-back").click();
    await expect(panel(page)).toBeHidden();
    await expect(page.locator("#composer-input")).toBeVisible();
  });

  test("the Threads inbox lists a followed thread with new replies, and its badge clears once read", async ({ page }) => {
    await openThread(page, "Will the inbox show this?");

    // reply, then leave the thread before the agent answers
    await reply(page, "Take your time, then answer here.");
    await expect(panel(page).locator('details[id^="telemetry-"]')).toBeVisible();
    await page.locator("#thread-panel-close").click();
    await expect(panel(page)).toBeHidden();

    const badge = page.locator("#rail-threads-badge");
    await expect(badge).toHaveText("1");
    await expect(page.locator('[id^="thread-unread-"]')).toBeVisible();

    await page.locator("#rail-threads").click();
    await expect(page).toHaveURL(/\/threads$/);
    const row = page.locator('[id^="thread-row-"]', { hasText: "Will the inbox show this?" }).first();
    await expect(row).toContainText("Answering in the thread");
    await expect(row).toContainText("1 new");

    await row.locator('[id$="-open"]').click();
    await expect(panel(page)).toBeVisible();
    await expect(replies(page)).toContainText("Answering in the thread");
    await expect(badge).toHaveCount(0);
    await expect(page.locator('[id^="thread-unread-"]')).toHaveCount(0);
  });

  test("another thread opens with an empty composer; Copy link says Copied once", async ({ page, context }) => {
    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    await openThread(page, "First thread for the draft");

    // a draft and a ticked box in the first thread
    await page.locator("#thread-composer-input").fill("meant for the first thread");
    await page.locator("#thread-also-send").check();

    // a second root; its thread opens with nothing carried over
    await send(page, "Second thread for the draft");
    await expect(timeline(page)).toContainText("Second thread for the draft");
    const second = timeline(page).locator("article", { hasText: "Second thread for the draft" }).first();
    await second.hover();
    await second.locator('[id^="reply-"]').click();
    await expect(panel(page)).toContainText("Second thread for the draft");
    await expect(page.locator("#thread-composer-input")).toHaveValue("");
    await expect(page.locator("#thread-also-send")).not.toBeChecked();

    // two quick clicks: the title comes back to what it was
    const copy = page.locator("#thread-copy-link");
    const title = await copy.getAttribute("title");
    await copy.click();
    await expect(copy).toHaveAttribute("title", "Copied");
    await copy.click();
    await expect(copy).toHaveAttribute("title", title!, { timeout: 4000 });
    expect(await page.evaluate(() => navigator.clipboard.readText())).toContain("?thread=msg_");
  });
});
