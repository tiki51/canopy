import { test, expect } from "@playwright/test";
import { createChannel, send, timeline } from "./helpers";

test.describe("channel collaboration", () => {
  test("a user message wakes the owner: telemetry, an agent post via MCP, the reply, and a turn summary", async ({ page }) => {
    await createChannel(page);
    await expect(page.locator("#owner-badge")).toContainText("backend");

    await send(page, "Why are invoices duplicated?");
    await expect(timeline(page)).toContainText("Why are invoices duplicated?");

    // live telemetry while the fake agent works
    const card = page.locator('[id^="telemetry-"]').first();
    await expect(card).toContainText(/is (researching|thinking|building|working)/);
    await expect(card).toContainText("README.md");

    // the agent posted through canopy_message_send
    await expect(timeline(page)).toContainText("Acknowledged: looking into it now.");
    // Agent messages are Markdown, rendered to real lists and code blocks.
    await expect(timeline(page).locator(".message-body ol li").first()).toContainText("Read README.md");
    await expect(timeline(page).locator(".message-body pre code")).toContainText("queue.add(invoice_id)");
    await expect(timeline(page)).toContainText(/finished/);
    // its closing text is kept on the turn card, not posted as a second message
    await expect(timeline(page).locator('[id^="turn-"][id$="-note"]').first()).toContainText("Reply from the fake agent.");
    await expect(timeline(page).locator('article[data-kind="reply"]')).toHaveCount(0);
    await expect(card).toBeHidden();
  });

  test("a permission request renders a card with the diff and Once resumes the agent", async ({ page }) => {
    await createChannel(page);
    await send(page, "Please edit notes.txt; this needs a permission.");

    const card = page.locator('[id^="permission-"]').first();
    await expect(card).toContainText("edit");
    await expect(card).toContainText("notes.txt");
    await expect(card).toContainText("+perm: test");

    await page.locator('[id^="permission-"][id$="-once"]').first().click();
    await expect(card).toBeHidden();
    await expect(timeline(page)).toContainText(/finished/);
  });

  test("/delegate runs the delegate in a child session and wakes the owner with the result", async ({ page }) => {
    await createChannel(page);
    await send(page, "/delegate @researcher list every enqueue path");

    await expect(timeline(page)).toContainText(/delegat/i);
    // the delegate (fake) completes through canopy_task_update, then the owner is woken
    await expect(timeline(page)).toContainText("Delegated work finished.");
    await expect(timeline(page)).toContainText("Found two enqueue paths.");
    await expect(timeline(page)).toContainText("Delegation result received; wrapping up.");
  });

  test("/handoff asks the target, who accepts through MCP, and the owner badge changes", async ({ page }) => {
    await createChannel(page);
    await expect(page.locator("#owner-badge")).toContainText("backend");

    await send(page, "/handoff @reviewer needs a second pair of eyes");
    await expect(timeline(page)).toContainText(/handoff|handed/i);
    await expect(timeline(page)).toContainText("Accepted the handoff.");
    await expect(page.locator("#owner-badge")).toContainText("reviewer");
  });

  test("an agent schedules a task through MCP; Oban fires it and the agent runs it", async ({ page }) => {
    await createChannel(page, "sched");
    await send(page, "Please schedule a quick check for a few seconds from now.");
    await expect(timeline(page)).toContainText(/scheduled: once · Run the scheduled check/);
    await expect(page.locator("#schedule-count")).toContainText("1");

    // the "created" toast covers the header buttons until dismissed
    await page.locator("#flash-info").click();
    await expect(page.locator("#flash-info")).toBeHidden();
    await page.locator("#edit-schedules").click();
    const row = page.locator('[id^="channel-schedules-sch_"]').first();
    await expect(row).toContainText("Run the scheduled check and report.");

    // Oban fires the job ~3s out; the fake agent answers the scheduled wake
    await expect(timeline(page)).toContainText(/scheduled task fired for @backend/, { timeout: 20_000 });
    await expect(timeline(page)).toContainText("Ran the scheduled check: all green.", { timeout: 20_000 });
    await expect(page.locator("#schedule-count")).toHaveCount(0);
    await expect(page.locator("#channel-schedules")).toContainText("Nothing scheduled.");
  });

  test("a bad slash command shows an error and keeps the draft", async ({ page }) => {
    await createChannel(page);
    await send(page, "/handoff");
    await expect(page.locator("#flash-error")).toContainText(/usage: \/handoff/);
    await expect(page.locator("#composer-input")).toHaveValue("/handoff");
  });
});
