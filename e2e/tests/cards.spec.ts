import { test, expect } from "@playwright/test";
import { createChannel, gotoLive, send, timeline, uniq } from "./helpers";

// Clickable cards (assets/js/card_links.js): a click on the card follows its
// link, its controls keep their own behaviour, closing a menu or selecting
// text doesn't navigate, and ⌘/Ctrl-click opens a new tab. Playbook rows are
// not cards: they open in place.

test("a playbook row opens in place; its star doesn't open it", async ({ page }) => {
  await gotoLive(page, "/playbooks");
  const row = page.locator("#playbooks li[data-playbook='bug-fix']");
  const expand = row.locator("[id^='expand-playbook-']");
  const detail = row.locator("[id^='playbook-detail-']");

  // a click on the row opens it, a second closes it; the page stays put
  await expect(detail).toHaveCount(0);
  await expand.click();
  await expect(expand).toHaveAttribute("aria-expanded", "true");
  await expect(row.locator("[id^='playbook-strip-'] li").first()).toBeVisible();
  await expand.click();
  await expect(expand).toHaveAttribute("aria-expanded", "false");
  await expect(detail).toHaveCount(0);
  await expect(page).toHaveURL(/\/playbooks$/);

  // the star moves the row to Starred without opening it, and back
  await row.locator("[id^='star-playbook-']").click();
  await expect(page.locator("#playbooks-starred li[data-playbook='bug-fix']")).toBeVisible();
  await expect(row).toHaveAttribute("data-starred", "true");
  await expect(detail).toHaveCount(0);
  await row.locator("[id^='star-playbook-']").click();
  await expect(row).toHaveAttribute("data-starred", "false");
  await expect(page.locator("#playbooks-starred")).toHaveCount(0);
  await expect(page).toHaveURL(/\/playbooks$/);
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

  await gotoLive(page, "/threads?tab=active");
  const row = page.locator("#threads > li[data-card]", { hasText: rootText });
  await expect(row).toHaveCSS("cursor", "pointer");
  await row.getByText(rootText).click();
  await expect(page).toHaveURL(new RegExp(`/channels/${channel}\\?.*thread=msg_`));
  await expect(page.locator("#thread-panel")).toBeVisible();
});
