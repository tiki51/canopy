import { expect, Page } from "@playwright/test";

let n = 0;
export const uniq = (prefix: string) => `${prefix}-${Date.now().toString(36)}${(n++).toString(36)}`;

/** Creates a channel through the UI and returns its id. All active agents are members; @backend owns it. */
export async function createChannel(page: Page, name = uniq("chan")): Promise<string> {
  await page.goto("/channels/new");
  await page.getByLabel("Repository").selectOption({ label: "e2e-repo" });
  await page.getByLabel("Name (slug, shown as #name)").fill(name);
  await page.getByLabel("Topic").fill("end-to-end");
  const owner = page.getByLabel("Initial owner");
  const backendValue = await owner.locator("option", { hasText: "backend" }).first().getAttribute("value");
  await owner.selectOption(backendValue!);
  await page.locator("#create-channel").click();
  await expect(page).toHaveURL(/\/channels\/ch_/);
  await expect(page.locator("#channel-name")).toContainText(name);
  return page.url().split("/channels/")[1];
}

export async function send(page: Page, text: string) {
  const input = page.locator("#composer-input");
  await input.fill(text);
  await input.press("Enter");
}

export const timeline = (page: Page) => page.locator("#timeline");

/** Opens the channel's Details side panel, unless it is open. */
export async function openDetails(page: Page) {
  const panel = page.locator("#details-panel");
  if (await panel.isVisible()) return;
  await page.locator("#toggle-details").click();
  await expect(panel).toBeVisible();
}

// Header controls HeaderFit may hide for lack of room, and their twin in Details.
const IN_DETAILS: Record<string, string> = { "open-changes": "details-changes", "edit-budget": "edit-budget-row" };

/**
 * Clicks a channel control (`edit-task`, `toggle-activity`, `lock-chip-tests`, …):
 * in the header when it shows there, otherwise in the Details panel, opened
 * first. The header refits a frame after its width changes (a side panel
 * just opened or closed), so this retries until the click lands.
 */
export async function clickHeader(page: Page, id: string) {
  const inline = page.locator(`#channel-header #${id}`);
  await expect(async () => {
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    if (await inline.isVisible()) return await inline.click({ timeout: 2_000 });
    await openDetails(page);
    await page.locator(`#details-panel #${IN_DETAILS[id] ?? id}`).click({ timeout: 2_000 });
  }).toPass({ timeout: 15_000 });
}
