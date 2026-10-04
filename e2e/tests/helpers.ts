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

/**
 * Clicks a channel header control (`edit-task`, `toggle-activity`, `lock-chip-tests`, …):
 * the inline one, or its copy in the ⋯ menu when the header has moved it there
 * for lack of room (the HeaderFit hook). The header refits a frame after its
 * width changes (a side panel just closed), so this retries until one of the
 * two takes the click.
 */
export async function clickHeader(page: Page, id: string) {
  const inline = page.locator(`#${id}`);
  const copy = page.locator(`#more-${id}`);
  await expect(async () => {
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    if (await inline.isVisible()) return await inline.click({ timeout: 2_000 });
    if (!(await page.locator("#channel-more-menu").isVisible())) await page.locator("#channel-more").click({ timeout: 2_000 });
    await copy.click({ timeout: 2_000 });
  }).toPass({ timeout: 15_000 });
}
