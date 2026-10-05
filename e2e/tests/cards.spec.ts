import { test, expect } from "@playwright/test";
import { createChannel, send, timeline, uniq } from "./helpers";

// Clickable cards (assets/js/card_links.js): a click on the card follows its
// link, its controls keep their own behaviour, closing a menu or selecting
// text doesn't navigate, and ⌘/Ctrl-click opens a new tab.

test("a playbook card opens its editor; its controls and text stay usable", async ({ page, context }) => {
  await page.goto("/playbooks");
  const card = page
    .locator("#playbooks > li[data-card]")
    .filter({ has: page.locator("span.font-mono", { hasText: /^bug-fix$/ }) });
  const description = card.locator("p").first();
  await expect(card).toHaveCSS("cursor", "pointer");

  // the Enabled toggle flips the playbook and stays on the page
  const toggle = card.locator("input[id^='toggle-playbook-']");
  await toggle.click();
  await expect(card).toHaveAttribute("data-enabled", "false");
  await toggle.click();
  await expect(card).toHaveAttribute("data-enabled", "true");
  await expect(page).toHaveURL(/\/playbooks$/);

  // the ⋯ menu opens; a click on the card then only closes it
  await card.locator("[id$='-toggle']").click();
  await expect(card.locator("[role=menu]")).toBeVisible();
  await description.click();
  await expect(card.locator("[role=menu]")).toBeHidden();
  await expect(page).toHaveURL(/\/playbooks$/);

  // selecting text in the card doesn't navigate
  const box = (await description.boundingBox())!;
  await page.mouse.move(box.x + 2, box.y + 6);
  await page.mouse.down();
  await page.mouse.move(box.x + box.width - 2, box.y + 6, { steps: 5 });
  await page.mouse.up();
  expect(await page.evaluate(() => window.getSelection()!.toString().length)).toBeGreaterThan(0);
  await expect(page).toHaveURL(/\/playbooks$/);

  // ⌘/Ctrl-click opens the editor in a new tab
  const [tab] = await Promise.all([
    context.waitForEvent("page"),
    description.click({ modifiers: ["ControlOrMeta"] }),
  ]);
  await expect(tab).toHaveURL(/\/playbooks\/[^/]+\/edit$/);
  await tab.close();
  await expect(page).toHaveURL(/\/playbooks$/);

  // a plain click anywhere else on the card opens the editor
  await description.click();
  await expect(page).toHaveURL(/\/playbooks\/[^/]+\/edit$/);
  await expect(page.locator("#playbook-builder")).toBeVisible();
});

test("a thread row opens its thread", async ({ page }) => {
  const rootText = uniq("Which cache scope");
  const channel = await createChannel(page);
  await send(page, rootText);
  await expect(timeline(page)).toContainText("Acknowledged: looking into it now.");
  await expect(page.locator('section[id^="telemetry-"]')).toHaveCount(0);

  // a reply makes it a thread the user follows
  const root = timeline(page).locator("article", { hasText: rootText }).first();
  await root.hover();
  await root.locator('[id^="reply-"]').click();
  await page.locator("#thread-composer-input").fill("Per request, I think.");
  await page.locator("#thread-composer-input").press("Enter");
  await expect(page.locator("#thread-replies")).toContainText("Per request, I think.");

  await page.goto("/threads?tab=active");
  const row = page.locator("#threads > li[data-card]", { hasText: rootText });
  await expect(row).toHaveCSS("cursor", "pointer");
  await row.getByText(rootText).click();
  await expect(page).toHaveURL(new RegExp(`/channels/${channel}\\?.*thread=msg_`));
  await expect(page.locator("#thread-panel")).toBeVisible();
});
