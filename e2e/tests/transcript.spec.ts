import { test, expect, Page } from "@playwright/test";
import { createChannel, send, timeline } from "./helpers";

// The session transcript: the fake OpenCode keeps each session's history
// (every prompt with its system text, every part it emitted) and serves it
// from GET /session/:id/message, as OpenCode does. Every spec works in a
// channel of its own, so the session resets here touch nothing else.

/** The owner's member pill (@backend owns the channels createChannel makes). */
const backendPill = (page: Page) => page.locator('#members li[id^="member-"]', { hasText: "@backend" });

async function openFromPill(page: Page) {
  await backendPill(page).locator('a[id^="transcript-"]').click();
  await expect(page).toHaveURL(/\/agents\/agt_[^/]+\/transcript/);
  await expect(page.locator("#transcript-summary")).toContainText("OpenCode");
}

/** Posts a message and waits for @backend's whole turn (its post, then the card closing). */
async function turn(page: Page, text: string) {
  const posts = timeline(page).getByText("Acknowledged: looking into it now.");
  const before = await posts.count();
  await send(page, text);
  await expect(posts).toHaveCount(before + 1);
  await expect(page.locator('section[id^="telemetry-"]')).toHaveCount(0);
}

test.describe("session transcript", () => {
  test("opens from the member pill: the prompt, the collapsed system prompt, a tool row", async ({ page }) => {
    await createChannel(page);
    await turn(page, "Where does the retry worker live?");

    await openFromPill(page);
    const entries = page.locator("#transcript-entries");
    await expect(entries.locator('[data-kind="prompt"]').first()).toContainText("You have a new Canopy message");
    await expect(entries.locator('[data-kind="prompt"]').first()).toContainText("Where does the retry worker live?");

    // Canopy's system text, collapsed until asked for
    const system = page.locator("#transcript-system-canopy");
    await expect(system).toContainText("System prompt (Canopy");
    await expect(system.locator("pre")).toBeHidden();
    await system.locator("summary").click();
    await expect(system.locator("pre")).toContainText("an AI coworker in Canopy");

    // the read tool opens to its input and output
    const read = entries.locator('[data-kind="tool"]', { hasText: "README.md" }).first();
    await read.locator('[id$="-toggle"]').click();
    await expect(read.locator('[id$="-body"]')).toContainText("# e2e repo");

    await page.locator("#transcript-back").click();
    await expect(page.locator("#channel-name")).toBeVisible();
  });

  test("opens from a finished turn card and lands on that turn, highlighted", async ({ page }) => {
    await createChannel(page);
    await turn(page, "First question for the transcript.");
    await turn(page, "Second question for the transcript.");

    await page.locator("#toggle-activity").click();
    const card = timeline(page).locator('section[id^="turn-"]').last();
    await card.locator('[id^="turn-toggle-"]').click();
    const eventId = (await card.getAttribute("id"))!.replace(/^turn-/, "");
    await card.locator(`#turn-${eventId}-transcript`).click();

    await expect(page).toHaveURL(new RegExp(`turn=${eventId}`));
    const divider = page.locator(`#transcript-turn-${eventId}`);
    await expect(divider).toContainText("woken by your message");
    await expect(divider.locator("> div")).toHaveClass(/ring-primary/);
    // the turn's own prompt follows its divider
    await expect(page.locator(`#transcript-turn-${eventId} + li`)).toContainText("Second question for the transcript.");
  });

  test("a compacted session shows where its context was summarised", async ({ page }) => {
    await createChannel(page);
    // the fake reports a model call past the cap; Canopy compacts after the turn
    await turn(page, "Please read everything, big context.");
    await page.locator("#toggle-activity").click();
    await expect(timeline(page)).toContainText("session was compacted");

    await openFromPill(page);
    const compaction = page.locator('#transcript-entries [data-kind="compaction"]');
    await expect(compaction).toContainText("Context compacted");
    await compaction.locator("summary").click();
    await expect(compaction).toContainText("Summary of the session so far");
  });

  test("a reset session stays readable from its line and from the session picker", async ({ page }) => {
    const channelId = await createChannel(page);
    await turn(page, "Remember the word pineapple.");

    await backendPill(page).locator('button[id^="reset-session-"]').click();
    await expect(page.locator("#canopy-confirm")).toContainText("fresh OpenCode session");
    await page.locator("#canopy-confirm-ok").click();

    const line = timeline(page).locator('[id^="line-"][id$="-transcript"]').last();
    await line.click();
    await expect(page).toHaveURL(/session=ses_/);
    await expect(page.locator("#transcript-entries")).toContainText("Remember the word pineapple.");

    // a new session starts on the next message; the old one is in the picker
    await page.locator("#transcript-back").click();
    await expect(page).toHaveURL(new RegExp(`/channels/${channelId}$`));
    await turn(page, "What was the word?");
    await openFromPill(page);
    await expect(page.locator("#transcript-entries")).toContainText("What was the word?");
    await expect(page.locator("#transcript-entries")).not.toContainText("pineapple");

    const picker = page.locator("#transcript-session-picker");
    const reset = picker.locator("option", { hasText: "Reset" });
    await picker.selectOption((await reset.getAttribute("value"))!);
    await expect(page.locator("#transcript-entries")).toContainText("Remember the word pineapple.");
  });

  test("on a phone the page never scrolls sideways", async ({ page }) => {
    await createChannel(page);
    await turn(page, "A message to read on a phone.");
    await page.setViewportSize({ width: 390, height: 844 });
    await openFromPill(page);

    const read = page.locator('#transcript-entries [data-kind="tool"]').first();
    await read.locator('[id$="-toggle"]').click();
    await page.locator("#transcript-system-canopy summary").click();
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    expect(overflow).toBeLessThanOrEqual(0);
  });
});
