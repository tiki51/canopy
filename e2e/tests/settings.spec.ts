import { test, expect } from "@playwright/test";

test.describe("settings", () => {
  test("checks the OpenCode connection and shows MCP install details", async ({ page }) => {
    await page.goto("/settings");
    const fakePort = process.env.FAKE_OPENCODE_PORT || "4396";
    await expect(page.getByLabel("Server URL")).toHaveValue(new RegExp(`127\\.0\\.0\\.1:${fakePort}`));

    await page.locator("#check-connection").click();
    await expect(page.locator("#health-result")).toContainText(/fake-1\.0/);

    await expect(page.locator("#mcp-url")).toContainText("/mcp");
    await expect(page.locator("#plugin-source")).toContainText("canopy_session_id");
    await expect(page.locator("#plugin-path")).toContainText("canopy.js");
  });

  test("switches the palette and keeps it across reloads", async ({ page }) => {
    await page.goto("/settings");
    const html = page.locator("html");
    await expect(html).toHaveAttribute("data-palette", "blue-hour");
    await expect(page.locator("#palette-blue-hour")).toHaveAttribute("aria-checked", "true");

    await page.locator("#palette-moss").click();
    await expect(html).toHaveAttribute("data-palette", "moss");
    await expect(page.locator("#palette-moss")).toHaveAttribute("aria-checked", "true");
    await expect(page.locator("#palette-blue-hour")).toHaveAttribute("aria-checked", "false");

    await page.reload();
    await expect(html).toHaveAttribute("data-palette", "moss");
    await expect(page.locator("#palette-moss")).toHaveAttribute("aria-checked", "true");
    await expect(page.locator('meta[name="theme-color"]')).not.toHaveAttribute("content", "#0A1730");

    await page.locator("#palette-blue-hour").click();
    await expect(html).toHaveAttribute("data-palette", "blue-hour");
  });

  test("the appearance mode and the rail toggle share state", async ({ page }) => {
    await page.goto("/settings");
    const html = page.locator("html");

    await page.locator("#appearance-mode-dark").click();
    await expect(html).toHaveAttribute("data-theme", "dark");
    await expect(html).toHaveAttribute("data-theme-source", "user");

    await page.locator('[data-phx-theme="light"]:not([id])').click();
    await expect(html).toHaveAttribute("data-theme", "light");
    // The panel's Light button is now the highlighted one.
    const bg = (id: string) =>
      page.locator(id).evaluate((el) => getComputedStyle(el).backgroundColor);
    expect(await bg("#appearance-mode-light")).not.toEqual(await bg("#appearance-mode-dark"));

    await page.locator("#appearance-mode-system").click();
    await expect(html).toHaveAttribute("data-theme-source", "system");
  });

  test("saves the display name", async ({ page }) => {
    await page.goto("/settings");
    await page.getByLabel("Display name").fill("Steven");
    await page.locator("#save-profile").click();
    await page.reload();
    await expect(page.getByLabel("Display name")).toHaveValue("Steven");
  });
});
