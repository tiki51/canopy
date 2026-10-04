import { test, expect, Page } from "@playwright/test";
import { createChannel, send, timeline, uniq } from "./helpers";

// Question cards from a Claude Code agent (e2e/fake-claude/claude.mjs asks
// through AskUserQuestion, which blocks on Canopy's permission tool). The
// suite runs Canopy with a 10 s no-output window for Claude Code turns
// (CANOPY_CLAUDE_STALL_MS in bin/server.sh); a question must outlive it.

/** Creates an active Claude Code agent through the Agents page and returns its name. */
async function createClaudeAgent(page: Page): Promise<string> {
  const name = uniq("asker").replace(/[^a-z0-9-]/g, "");
  await page.goto("/agents/new");
  await page.getByLabel("Name (slug, used as @name)").fill(name);
  await page.getByLabel("Display name").fill("Asker");
  await page.getByLabel("Role (one line)").fill("Asks before acting");
  await page.locator("#agent-engine-select").selectOption("claude_code");
  await page.locator("#claude-model").selectOption({ index: 1 });
  await page.locator("#claude-effort").selectOption("low");
  await page.locator("#save-agent").click();
  await expect(page).toHaveURL(/\/agents\/agt_/);
  return name;
}

test.describe("question cards", () => {
  test("a question with no options is answered by typing, and the composer is not the answer", async ({ page }) => {
    const name = await createClaudeAgent(page);
    await createChannel(page);
    await send(page, `@${name} ask me what to call the release`);

    // the question is folded into the live turn's card: one card, not two
    const card = page.locator('[id^="question-"][data-detached]').first();
    await expect(card).toContainText("What should the release be called?");
    const live = page.locator('section[id^="telemetry-"]').first();
    await expect(live).toContainText("needs a decision to carry on");
    await expect(live.locator('[id^="question-"][data-detached]')).toHaveCount(1);
    await expect(page.locator('section[id^="question-"]')).toHaveCount(0);
    // Send waits for an answer; Dismiss is a neutral button
    await expect(card.locator('[id$="-send"]')).toBeDisabled();
    await expect(card.locator('[id$="-dismiss"]')).toHaveClass(/btn-ghost/);
    await expect(card.locator('[id$="-dismiss"]')).not.toHaveClass(/text-error/);
    await expect(page.locator("#awaiting-bar")).toContainText(`@${name} is waiting on your answer`);
    await expect(page.locator(`#members [data-status="awaiting_user"]`)).toHaveCount(1);

    // a draft that mentions the waiting agent says it will not answer the card
    const input = page.locator("#composer-input");
    await input.fill(`@${name} call it Maple`);
    await expect(page.locator("#composer-awaiting-hint")).toContainText(`@${name} is waiting on the card above`);
    await input.fill("");
    await expect(page.locator("#composer-awaiting-hint")).toBeHidden();

    await card.getByPlaceholder("Your answer").fill("Maple");
    await expect(card.locator('[id$="-send"]')).toBeEnabled();
    await card.locator('[id$="-send"]').click();

    await expect(card).toBeHidden();
    await expect(page.locator("#awaiting-bar")).toBeHidden();
    await expect(timeline(page)).toContainText("Going with Maple.");
    await expect(timeline(page)).toContainText(new RegExp(`@${name} finished`));
  });

  test("a question left unanswered past the stall window still reaches the agent", async ({ page }) => {
    const name = await createClaudeAgent(page);
    await createChannel(page);
    await send(page, `@${name} ask me which colour`);

    const card = page.locator('[id^="question-"][data-detached]').first();
    await expect(card).toContainText("Which colour should the banner be?");

    // the turn prints nothing while the user decides; it is not killed for it
    await page.waitForTimeout(13_000);
    await expect(timeline(page)).not.toContainText("no output from claude");
    await expect(card).toBeVisible();
    await expect(card).not.toContainText("stopped waiting");

    await expect(card.locator('[id$="-send"]')).toBeDisabled();
    await card.getByLabel("Orange").check();
    await expect(card.locator('[id$="-send"]')).toBeEnabled();
    await card.locator('[id$="-send"]').click();

    await expect(card).toBeHidden();
    await expect(timeline(page)).toContainText("Going with Orange.");
    await expect(timeline(page)).toContainText(new RegExp(`@${name} finished`));
  });
});
