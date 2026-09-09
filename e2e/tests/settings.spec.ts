import { test, expect } from "@playwright/test";

test.describe("settings", () => {
  test("checks the OpenCode connection and shows MCP install details", async ({ page }) => {
    await page.goto("/settings");
    await expect(page.getByLabel("Server URL")).toHaveValue(/127\.0\.0\.1:4396/);

    await page.locator("#check-connection").click();
    await expect(page.locator("#health-result")).toContainText(/fake-1\.0/);

    await expect(page.locator("#mcp-url")).toContainText("/mcp");
    await expect(page.locator("#plugin-source")).toContainText("canopy_session_id");
    await expect(page.locator("#plugin-path")).toContainText("canopy.js");
  });

  test("saves the display name", async ({ page }) => {
    await page.goto("/settings");
    await page.getByLabel("Display name").fill("Steven");
    await page.locator("#save-profile").click();
    await page.reload();
    await expect(page.getByLabel("Display name")).toHaveValue("Steven");
  });
});
