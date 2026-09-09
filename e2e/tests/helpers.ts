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
