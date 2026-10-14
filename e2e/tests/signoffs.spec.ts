import { test, expect, Page } from "@playwright/test";
import { createChannel, gotoLive, send, timeline } from "./helpers";

// Sign-off cards from an agent (e2e/fake-opencode.mjs): "ask me to sign off on
// <thing> with options A, B, C" puts up a card with three options, B
// recommended. A freestanding card's answer is posted as the user's message,
// mentioning the agent; the agent's next turn echoes what it heard. The
// run-linked card is in playbooks.spec.ts.

const card = (page: Page) => page.locator('section[id^="signoff-so_"]');

/** Asks @backend for a card and returns its sign-off id. */
async function ask(page: Page, thing: string): Promise<string> {
  await send(page, `@backend ask me to sign off on ${thing} with options A, B, C`);
  await expect(card(page)).toBeVisible();
  await expect(card(page)).toContainText(thing);
  return (await card(page).getAttribute("id"))!.replace(/^signoff-/, "");
}

const answers = (page: Page, text: RegExp) => page.locator('#timeline [id^="evt-"]').filter({ hasText: text });

test.describe("sign-off cards", () => {
  test("pick an option with a note, reject all, and see it in a second tab", async ({ page }) => {
    const channel = await createChannel(page);
    const so = await ask(page, "header design");

    // three rows; the recommended one is the solid Accept
    await expect(page.locator(`#signoff-${so}`)).toHaveAttribute("data-options", "3");
    await expect(page.locator(`#signoff-${so}-title`)).toContainText("@backend wants your sign-off");
    await expect(page.locator(`#signoff-${so}-accept-1`)).not.toHaveClass(/btn-outline/);
    await expect(page.locator(`#signoff-${so}-accept-0`)).toHaveClass(/btn-outline/);
    await expect(page.locator(`#signoff-${so}-accept-2`)).toHaveClass(/btn-outline/);
    await expect(page.locator("#awaiting-bar")).toContainText("@backend wants your sign-off");

    // Enter in the note answers nothing
    const note = page.locator(`#signoff-${so}-note`);
    await note.fill("keep the badge grey");
    await note.press("Enter");
    await page.waitForTimeout(500);
    await expect(page.locator(`#signoff-${so}`)).toBeVisible();
    await expect(answers(page, /Accepted your sign-off|Rejected your sign-off/)).toHaveCount(0);

    // a second tab on the same channel
    const other = await page.context().newPage();
    await gotoLive(other, `/channels/${channel}`);
    await expect(other.locator(`#signoff-${so}`)).toBeVisible();

    // C's Accept: the answer is posted with the note, the row stays hidden,
    // and the agent hears it
    await page.locator(`#signoff-${so}-accept-2`).click();
    await expect(page.locator(`#signoff-${so}`)).toHaveCount(0);
    await expect(page.locator("#awaiting-bar")).toBeHidden();
    const accepted = answers(page, /Accepted your sign-off/);
    await expect(accepted).toHaveCount(1);
    await expect(accepted).toContainText("C · Minimal");
    await expect(accepted).toContainText("keep the badge grey");
    await expect(page.locator(`#signoff-resolved-${so}`)).toBeAttached();
    await expect(page.locator(`#signoff-resolved-${so}`)).toBeHidden();
    await expect(timeline(page)).toContainText("Heard: you accepted C.");

    // the other tab dropped its card and shows the answer
    await expect(other.locator(`#signoff-${so}`)).toHaveCount(0);
    await expect(answers(other, /Accepted your sign-off/)).toHaveCount(1);
    await other.close();

    // a second ask, Reject all with no note
    const again = await ask(page, "footer design");
    await page.locator(`#signoff-${again}-reject-all`).click();
    await expect(page.locator(`#signoff-${again}`)).toHaveCount(0);
    const rejected = answers(page, /Rejected your sign-off/);
    await expect(rejected).toHaveCount(1);
    await expect(rejected).toContainText("all options");
    await expect(page.locator(`#signoff-resolved-${again}`)).toBeHidden();
    await expect(timeline(page)).toContainText("Heard: you rejected it.");
  });

  test("two tabs pressing Accept at once answer once", async ({ page }) => {
    const channel = await createChannel(page);
    const so = await ask(page, "logo");
    const other = await page.context().newPage();
    await gotoLive(other, `/channels/${channel}`);
    await expect(other.locator(`#signoff-${so}`)).toBeVisible();

    await Promise.all([
      page.locator(`#signoff-${so}-accept-1`).click(),
      other.locator(`#signoff-${so}-accept-1`).click(),
    ]);

    for (const p of [page, other]) {
      await expect(p.locator(`#signoff-${so}`)).toHaveCount(0);
      await expect(answers(p, /Accepted your sign-off/)).toHaveCount(1);
    }
    await expect(timeline(page)).toContainText("Heard: you accepted B.");
    // one turn: give a second one time to land, then count
    await page.waitForTimeout(1500);
    await expect(answers(page, /Heard: you accepted/)).toHaveCount(1);
    for (const p of [page, other]) await expect(p.locator("#flash-error")).toBeHidden();
    await other.close();
  });
});
