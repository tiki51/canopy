import { test, expect } from "@playwright/test";
import { uniq } from "./helpers";

test.describe("repositories and agents", () => {
  test("lists the registered repository with its branch", async ({ page }) => {
    await page.goto("/repositories");
    await expect(page.locator("#repositories").getByText("e2e-repo", { exact: true })).toBeVisible();
    await expect(page.locator("#repositories")).toContainText("main");
  });

  test("rejects a path that does not exist", async ({ page }) => {
    await page.goto("/repositories");
    await page.getByLabel("Absolute path").fill("/definitely/not/here");
    await page.locator("#save-repository").click();
    await expect(page.locator("#repository-form")).toContainText(/does not exist/i);
  });

  test("shows the seeded agents and creates a new one", async ({ page }) => {
    await page.goto("/agents");
    for (const name of ["backend", "reviewer", "researcher", "test"]) {
      await expect(page.locator("#active-agents")).toContainText(`@${name}`);
    }

    const name = uniq("tester").replace(/[^a-z0-9-]/g, "");
    await page.locator("#new-agent").click();
    await expect(page).toHaveURL(/\/agents\/new$/);
    await page.getByLabel("Name (slug, used as @name)").fill(name);
    await page.getByLabel("Display name").fill("Tester");
    await page.getByLabel("Role (one line)").fill("Checks things");
    await page.locator("#save-agent").click();

    // lands on the new agent's page; the list has it too. The model was left on
    // its default, so the agent inherits.
    await expect(page).toHaveURL(/\/agents\/agt_/);
    const id = new URL(page.url()).pathname.split("/").pop();
    await expect(page.locator("#agent-about")).toContainText("Checks things");
    await expect(page.locator("#agent-model")).toContainText("OpenCode default");
    await page.locator("#flash-info").click();
    await expect(page.locator("#flash-info")).toBeHidden();
    await page.locator("#back-to-agents").click();
    await expect(page.locator("#active-agents")).toContainText(`@${name}`);

    // override the model from the row's picker: a badge; Default brings it back
    const model = page.locator(`#model-${id}`);
    await expect(model).toHaveText("default");
    await model.click();
    await page.locator("#model-option-opencode-gpt-5-nano").click();
    await expect(page.locator("#model-picker")).toBeHidden();
    await expect(model).toHaveText("opencode/gpt-5-nano");
    await expect(model).toHaveClass(/badge/);

    await model.click();
    await page.locator("#model-option-default").click();
    await expect(model).toHaveText("default");
    await expect(model).not.toHaveClass(/badge/);
  });
});
