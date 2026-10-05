import { test, expect } from "@playwright/test";
import { createChannel, send, timeline, uniq, clickHeader, openDetails } from "./helpers";

test.describe("channel collaboration", () => {
  test("a user message wakes the owner: telemetry, an agent post via MCP, the reply, and a turn summary", async ({ page }) => {
    await createChannel(page);
    await openDetails(page);
    await expect(page.locator("#owner-badge")).toContainText("backend");

    await send(page, "Why are invoices duplicated?");
    await expect(timeline(page)).toContainText("Why are invoices duplicated?");

    // live telemetry while the fake agent works
    const card = page.locator('section[id^="telemetry-"]').first();
    await expect(card).toContainText(/is (researching|thinking|building|working)/);

    // the agent posted through canopy_message_send
    await expect(timeline(page)).toContainText("Acknowledged: looking into it now.");
    // Agent messages are Markdown, rendered to real lists and code blocks.
    await expect(timeline(page).locator(".message-body ol li").first()).toContainText("Read README.md");
    await expect(timeline(page).locator(".message-body pre code")).toContainText("queue.add(invoice_id)");
    await expect(timeline(page)).toContainText(/finished/);
    await expect(card).toBeHidden();
    // the finished turn (hidden in the compact timeline) opens to what it ran,
    // and keeps its closing text instead of posting it as a second message
    await clickHeader(page, "toggle-activity");
    const turn = timeline(page).locator('section[id^="turn-"]').last();
    await turn.locator('[id^="turn-toggle-"]').click();
    await expect(turn).toContainText("README.md");
    await expect(timeline(page).locator('[id^="turn-"][id$="-note"]').first()).toContainText("Reply from the fake agent.");
    await expect(timeline(page).locator('article[data-kind="reply"]')).toHaveCount(0);
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

  test("a question renders a card with its options and the answer resumes the agent", async ({ page }) => {
    await createChannel(page);
    await send(page, "Pick a retry key for enqueue_charge, but ask me first.");

    // a standalone card, or folded into the waiting turn's live card
    const card = page.locator('[id^="question-"][data-detached]').first();
    await expect(card).toContainText("Should the retry key include the attempt number?");
    await expect(card).toContainText("Invoice only");
    await expect(card).toContainText("Invoice + attempt");

    await card.getByLabel("Invoice + attempt").check();
    await card.locator('[id$="-send"]').click();
    await expect(card).toBeHidden();
    await expect(timeline(page)).toContainText("Going with Invoice + attempt.");
    await expect(timeline(page)).toContainText(/finished/);
  });

  test("/delegate runs the delegate in its own session and wakes the owner with the result", async ({ page }) => {
    const name = uniq("chan");
    await createChannel(page, name);
    await send(page, "/delegate @researcher list every enqueue path");

    // reported once: one line, by the user, for the owner
    await expect(timeline(page)).toContainText(`delegated to @researcher for @backend: list every enqueue path`);
    await expect(timeline(page).getByText(/delegated to @researcher/)).toHaveCount(1);
    await expect(timeline(page)).not.toContainText("Delegated to @researcher");
    // the delegate (fake) completes through canopy_task_update, then the owner is woken
    await expect(timeline(page)).toContainText("Delegated work finished.");
    await expect(timeline(page)).toContainText("Found two enqueue paths.");
    await expect(timeline(page)).toContainText("Delegation result received; wrapping up.");

    // one session per agent in the channel: no child sessions
    const res = await page.request.get(`http://127.0.0.1:${process.env.FAKE_OPENCODE_PORT || 4396}/__fake/sessions`);
    const sessions = ((await res.json()) as { parentID: string | null; title: string }[]).filter((s) => s.title?.startsWith(`#${name} `));
    expect(sessions.filter((s) => s.parentID)).toEqual([]);
    expect(sessions.map((s) => s.title).sort()).toEqual([`#${name} · @backend`, `#${name} · @researcher`]);
  });

  test("/handoff asks the target, who accepts through MCP, and the owner badge changes", async ({ page }) => {
    await createChannel(page);
    await openDetails(page);
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
    // Details (closed) carries a dot for it
    await expect(page.locator("#details-dot")).toBeVisible();

    // the "created" toast covers the header buttons until dismissed
    await page.locator("#flash-info").click();
    await expect(page.locator("#flash-info")).toBeHidden();
    await clickHeader(page, "edit-schedules");
    await expect(page.locator("#schedule-count")).toContainText("1 active");
    const row = page.locator('[id^="channel-schedules-sch_"]').first();
    await expect(row).toContainText("Run the scheduled check and report.");

    // Oban fires the job ~3s out; the fake agent answers the scheduled wake
    await expect(timeline(page)).toContainText(/scheduled task fired for @backend/, { timeout: 20_000 });
    await expect(timeline(page)).toContainText("Ran the scheduled check: all green.", { timeout: 20_000 });
    await expect(page.locator("#schedule-count")).toHaveCount(0);
    await expect(page.locator("#channel-schedules")).toContainText("Nothing scheduled.");
  });

  test("typing # suggests channels and @ suggests every agent and team", async ({ page }) => {
    const id = await createChannel(page, "mention-target");
    await createChannel(page, "mention-source");
    const input = page.locator("#composer-input");
    await input.fill("see #mention-t");
    await expect(page.locator("#composer-suggestions")).toContainText("#mention-target");
    await input.press("Enter");
    await expect(input).toHaveValue("see #mention-target ");
    await input.fill("hi @rev");
    await expect(page.locator("#composer-suggestions")).toContainText("@reviewer");
    await input.press("Escape");
    // teams share the @ namespace and follow the agents (the seeded @bugfix-team)
    await input.fill("hi @bug");
    await expect(page.locator("#composer-suggestions")).toContainText("@bugfix-team");
    await input.press("Enter");
    await expect(input).toHaveValue("hi @bugfix-team ");
    await input.fill("");
    void id;
  });

  test("a bad slash command shows an error and keeps the draft", async ({ page }) => {
    await createChannel(page);
    await send(page, "/handoff");
    await expect(page.locator("#flash-error")).toContainText(/usage: \/handoff/);
    await expect(page.locator("#composer-input")).toHaveValue("/handoff");
  });
});
