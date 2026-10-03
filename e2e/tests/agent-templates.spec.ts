// Agent templates: export an agent as a file, import it back under a new
// name, and add a starter agent from the gallery. Agents can't be deleted,
// so the agents this spec creates are deactivated at the end: later specs
// see the same active agents as before.
import { test, expect, Page } from "@playwright/test";

async function agentIdByName(page: Page, name: string): Promise<string> {
  await page.goto("/agents");
  const row = page.locator('#active-agents li[id^="agent-agt_"]', { hasText: `@${name}` }).first();
  return (await row.getAttribute("id"))!.replace(/^agent-/, "");
}

async function deactivate(page: Page, name: string) {
  const id = await agentIdByName(page, name);
  await page.goto(`/agents/${id}`);
  await page.locator(`#deactivate-agent-${id}`).click();
  await expect(page.locator("#canopy-confirm")).toBeVisible();
  await page.locator("#canopy-confirm-ok").click();
  await expect(page.locator("#agent-about")).toContainText("deactivated");
}

test.describe("agent templates", () => {
  test("export an agent, import the file as a copy, and add one from the gallery", async ({ page }, testInfo) => {
    // export @reviewer from its page
    const reviewerId = await agentIdByName(page, "reviewer");
    await page.goto(`/agents/${reviewerId}`);
    await page.locator(`#export-agent-${reviewerId}`).click();
    await expect(page.locator("#export-agent-download")).toBeVisible();
    const [download] = await Promise.all([
      page.waitForEvent("download"),
      page.locator("#export-agent-download").click(),
    ]);
    expect(download.suggestedFilename()).toBe("reviewer.md");
    const file = testInfo.outputPath("reviewer.md");
    await download.saveAs(file);

    // import it: it's identical to the one here, so it starts skipped; rename it
    await page.goto("/agents");
    await page.locator("#agents-import").click();
    await expect(page).toHaveURL(/\/agents\/import$/);
    await page.locator("#import-upload-form input[type=file]").setInputFiles(file);
    const item = page.locator("#import-item-1");
    await expect(item).toHaveAttribute("data-status", "identical");
    await expect(item).toContainText("already here");
    await expect(page.locator("#import-apply")).toBeDisabled();

    await page.locator("#import-item-1-rename").check();
    await expect(page.locator("#import-item-1-name")).toHaveValue("reviewer-2");
    await expect(page.locator("#import-apply")).toBeEnabled();
    await page.locator("#import-apply").click();
    await expect(page).toHaveURL(/\/agents$/);
    await expect(page.locator("#flash-info")).toContainText("Imported @reviewer-2.");
    await expect(page.locator("#active-agents")).toContainText("@reviewer-2");

    // add @security-reviewer from the gallery, through the same preview
    await page.locator("#agents-gallery").click();
    await expect(page).toHaveURL(/\/agents\/gallery$/);
    await page.locator("#gallery-add-security-reviewer").click();
    await expect(page.locator("#import-item-1")).toHaveAttribute("data-status", "new");
    await expect(page.locator("#import-item-1-permission")).toContainText("agent plan");
    await page.locator("#import-apply").click();
    await expect(page).toHaveURL(/\/agents\/gallery$/);
    await expect(page.locator("#gallery-added-security-reviewer")).toBeVisible();

    await deactivate(page, "reviewer-2");
    await deactivate(page, "security-reviewer");
  });
});
