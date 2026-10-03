import { test, expect } from "@playwright/test";
import fs from "node:fs";
import path from "node:path";
import { sql } from "./site-helpers";

// bin/server.sh marks setup done so `/` behaves as on an existing install;
// these specs clear `onboarded_at` straight in the e2e database (the server
// keeps running; SQLite is in WAL mode) to start from a fresh install.
const fresh = () => sql("UPDATE settings SET onboarded_at = NULL");

// A sibling of the suite's tmp/e2e-repo; not a git repository until setup adds it.
const project = path.resolve("../tmp/e2e-onboard");

test.describe("first-run setup", () => {
  test.beforeEach(() => {
    fs.rmSync(project, { recursive: true, force: true });
    fs.mkdirSync(project, { recursive: true });
    fresh();
  });

  test.afterEach(() => {
    sql(`DELETE FROM repositories WHERE path = '${project}'`);
    fs.rmSync(project, { recursive: true, force: true });
  });

  test("walks a fresh install from / to its first channel", async ({ page }) => {
    await page.goto("/");
    await expect(page).toHaveURL(/\/welcome$/);
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();

    // name
    await page.getByLabel("What should the agents call you?").fill("Priya");
    await page.locator("#welcome-continue").click();
    await expect(page).toHaveURL(/step=theme/);

    // look: applies at once and is kept by the browser
    const html = page.locator("html");
    await page.locator("#palette-moss").click();
    await page.locator("#appearance-mode-dark").click();
    await expect(html).toHaveAttribute("data-palette", "moss");
    await expect(html).toHaveAttribute("data-theme", "dark");
    await page.reload();
    await expect(html).toHaveAttribute("data-palette", "moss");
    await expect(html).toHaveAttribute("data-theme", "dark");
    await page.locator("#welcome-continue").click();
    await expect(page).toHaveURL(/step=engines/);

    // engines: the fake Claude Code and the fake OpenCode both answer
    await expect(page.locator("#welcome-claude")).toHaveAttribute("data-state", "ready");
    await expect(page.locator("#welcome-claude-status")).toContainText("priya@acme.example");
    await expect(page.locator("#welcome-opencode")).toHaveAttribute("data-state", "ready");
    await expect(page.locator("#welcome-opencode-status")).toContainText("fake-1.0");
    await expect(page.locator("#welcome-claude-default-model")).toBeVisible();
    await expect(page.locator("#welcome-opencode-default-provider")).toBeEnabled();
    await expect(page.locator("#welcome-move-starters")).toHaveCount(0);
    await page.locator("#welcome-continue").click();
    await expect(page).toHaveURL(/step=team/);

    // pace
    await expect(page.locator("#welcome-presets-balanced")).toHaveAttribute("aria-checked", "true");
    await page.locator("#welcome-presets-careful").click();
    await expect(page.locator("#welcome-presets-careful")).toHaveAttribute("aria-checked", "true");
    await page.locator("#welcome-continue").click();
    await expect(page).toHaveURL(/step=repository/);

    // project
    await page.getByLabel("Project folder (absolute path)").fill(project);
    await page.locator("#welcome-continue").click();
    await expect(page).toHaveURL(/step=done/);
    await expect(page.locator("#flash-info")).toContainText("so one was initialised");
    expect(fs.existsSync(path.join(project, ".git"))).toBe(true);

    // summary
    await expect(page.locator("#summary-name")).toContainText("Priya");
    // every palette and mode is in the page; CSS shows the ones in force
    await expect(page.locator("#summary-look")).toContainText(/Moss & Paper,\s+dark/, { useInnerText: true });
    await expect(page.locator("#summary-engines")).toContainText(/Claude Code ✓,\s+OpenCode ✓/);
    await expect(page.locator("#summary-pace")).toContainText("Careful");
    await expect(page.locator("#summary-project")).toContainText("e2e-onboard");

    await page.locator("#welcome-finish").click();
    await expect(page).toHaveURL(/\/channels\/new\?repository_id=/);
    const repositoryId = new URL(page.url()).searchParams.get("repository_id")!;
    await expect(page.getByLabel("Repository")).toHaveValue(repositoryId);

    // setup is done: home no longer sends us back
    await page.goto("/");
    await expect(page).not.toHaveURL(/\/welcome/);

    await page.goto("/settings");
    await expect(page.locator("#profile-form").getByLabel("Display name")).toHaveValue("Priya");
    await expect(page.locator("#chatter-presets-careful")).toHaveAttribute("aria-checked", "true");

    // put things back for the specs that follow
    await page.locator("#chatter-presets-balanced").click();
    await expect(page.locator("#chatter-presets-balanced")).toHaveAttribute("aria-checked", "true");
    await page.locator("#profile-form").getByLabel("Display name").fill("You");
    await page.locator("#save-profile").click();
    await expect(page.locator("#flash-info")).toContainText("Display name saved");
    await page.evaluate(() => localStorage.clear());
  });

  test("Skip setup finishes it and goes home", async ({ page }) => {
    await page.goto("/welcome");
    await page.locator("#skip-setup").click();
    await expect(page).toHaveURL(/\/(channels\/ch_|repositories)/);
    await expect(page.locator("#flash-info")).toContainText("Setup skipped");

    await page.goto("/");
    await expect(page).not.toHaveURL(/\/welcome/);
  });
});
