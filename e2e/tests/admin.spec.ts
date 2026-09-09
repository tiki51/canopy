import { test, expect } from "@playwright/test";
import { uniq } from "./helpers";

test.describe("repositories and agents", () => {
  test("lists the registered repository with its branch", async ({ page }) => {
    await page.goto("/repositories");
    await expect(page.locator("#repositories").getByText("e2e-repo", { exact: true })).toBeVisible();
    await expect(page.locator("#repositories")).toContainText("main");
  });

  test("rejects a path that is not a git repository", async ({ page }) => {
    await page.goto("/repositories");
    await page.getByLabel("Absolute path").fill("/definitely/not/here");
    await page.locator("#save-repository").click();
    await expect(page.locator("#repository-form")).toContainText(/exist|directory|git/i);
  });

  test("shows the seeded agents and creates a new one", async ({ page }) => {
    await page.goto("/agents");
    for (const name of ["backend", "reviewer", "researcher", "test"]) {
      await expect(page.locator("#active-agents")).toContainText(`@${name}`);
    }

    const name = uniq("tester").replace(/[^a-z0-9-]/g, "");
    await page.locator("#new-agent").click();
    await page.getByLabel("Name (slug, used as @name)").fill(name);
    await page.getByLabel("Display name").fill("Tester");
    await page.getByLabel("Role (one line)").fill("Checks things");
    await page.locator("#save-agent").click();
    await expect(page.locator("#active-agents")).toContainText(`@${name}`);
  });
});
