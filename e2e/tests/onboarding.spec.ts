import { test, expect } from "@playwright/test";
import fs from "node:fs";
import path from "node:path";
import { sql } from "./site-helpers";
import { stubNotifications } from "./notify-helpers";

// bin/server.sh marks setup done so `/` behaves as on an existing install;
// these specs clear `onboarded_at` straight in the e2e database (the server
// keeps running; SQLite is in WAL mode) to start from a fresh install.
const fresh = () => sql("UPDATE settings SET onboarded_at = NULL");

// A sibling of the suite's tmp/e2e-repo; not a git repository until setup adds it.
const project = path.resolve("../tmp/e2e-onboard");

// Everything setup can change on the server, put back after the specs so the
// ones that follow see the install as it was. (Finish keeps the name git
// suggests, and the fake engines let the walk save defaults and a preset.)
const settingsColumns = [
  "onboarded_at",
  "user_display_name",
  "default_engine",
  "claude_default_model",
  "claude_default_effort",
  "opencode_default_provider",
  "opencode_default_model",
  "serialize_turns",
  "chatter_pause",
  "chatter_limit",
  "claude_binary",
];

const literal = (value: unknown) =>
  value === null ? "NULL" : typeof value === "number" ? String(value) : `'${String(value).replace(/'/g, "''")}'`;

function snapshot(): () => void {
  const settings = JSON.parse(
    sql(`SELECT json_object(${settingsColumns.map((c) => `'${c}', ${c}`).join(", ")}) FROM settings`),
  );
  const users = JSON.parse(sql("SELECT json_group_array(json_object('id', id, 'name', display_name)) FROM users"));
  const agents = JSON.parse(sql("SELECT json_group_array(json_object('id', id, 'engine', engine)) FROM agents"));

  return () => {
    sql(`UPDATE settings SET ${settingsColumns.map((c) => `${c} = ${literal(settings[c])}`).join(", ")}`);
    for (const u of users) sql(`UPDATE users SET display_name = ${literal(u.name)} WHERE id = ${literal(u.id)}`);
    for (const a of agents) sql(`UPDATE agents SET engine = ${literal(a.engine)} WHERE id = ${literal(a.id)}`);
  };
}

test.describe("first-run setup", () => {
  let restore = () => {};

  test.beforeAll(() => {
    restore = snapshot();
  });

  test.afterAll(() => restore());

  test.beforeEach(() => {
    fs.rmSync(project, { recursive: true, force: true });
    fs.mkdirSync(project, { recursive: true });
    fresh();
  });

  test.afterEach(() => {
    sql(`DELETE FROM repositories WHERE path = '${project}'`);
    fs.rmSync(project, { recursive: true, force: true });
  });

  test("walks a fresh install from / down the page to its first channel", async ({ page }) => {
    await page.goto("/");
    await expect(page).toHaveURL(/\/welcome$/);
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();

    // one page: no steps, no Continue
    await expect(page.locator("#welcome-steps")).toHaveCount(0);
    await expect(page.locator("#welcome-continue")).toHaveCount(0);

    // you: saves as it is typed, with no Continue
    await page.getByLabel("What should the agents call you?").fill("Priya");
    await expect(page.locator("#welcome-you-saved")).toBeVisible();

    // look: applies at once and is kept by the browser
    const html = page.locator("html");
    await page.locator("#palette-moss").click();
    await page.locator("#appearance-mode-dark").click();
    await expect(html).toHaveAttribute("data-palette", "moss");
    await expect(html).toHaveAttribute("data-theme", "dark");
    await page.reload();
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
    await expect(html).toHaveAttribute("data-palette", "moss");
    await expect(html).toHaveAttribute("data-theme", "dark");
    // the name came through the reload too
    await expect(page.getByLabel("What should the agents call you?")).toHaveValue("Priya");

    // engines: the fake Claude Code and the fake OpenCode both answer
    await expect(page.locator("#welcome-claude")).toHaveAttribute("data-state", "ready");
    await expect(page.locator("#welcome-claude-status")).toContainText("priya@acme.example");
    await expect(page.locator("#welcome-opencode")).toHaveAttribute("data-state", "ready");
    await expect(page.locator("#welcome-opencode-status")).toContainText("fake-1.0");
    await expect(page.locator("#welcome-opencode-default-provider")).toBeEnabled();
    // default engine: both ready, so OpenCode until the user picks; a pick saves at once
    const opencodeCard = page.locator("#welcome-engine-choice-opencode");
    const claudeCard = page.locator("#welcome-engine-choice-claude_code");
    await expect(opencodeCard).toHaveAttribute("aria-checked", "true");
    await expect(opencodeCard).toHaveAttribute("data-ready", "ready");
    await expect(claudeCard).toHaveAttribute("data-ready", "ready");
    await claudeCard.click();
    await expect(claudeCard).toHaveAttribute("aria-checked", "true");
    await expect(page.locator("#welcome-engines-saved")).toBeVisible();
    expect(sql("SELECT default_engine FROM settings")).toBe("claude_code");
    // the default engine's model controls come first
    const first = page.locator("#welcome-default-model [id$='-defaults']").first();
    await expect(first).toHaveAttribute("id", "welcome-claude-defaults");
    await page.locator("#welcome-claude-default-model").selectOption("sonnet");
    await expect(page.locator("#welcome-engines-saved")).toBeVisible();

    // pace
    await expect(page.locator("#welcome-presets-balanced")).toHaveAttribute("aria-checked", "true");
    await page.locator("#welcome-presets-careful").click();
    await expect(page.locator("#welcome-presets-careful")).toHaveAttribute("aria-checked", "true");
    await expect(page.locator("#welcome-pace-saved")).toBeVisible();

    // notifications
    await expect(page.locator("#welcome-notify #notify-enabled")).toBeAttached();

    // project: added by its own button, with the result inline
    await page.getByLabel("Project folder (absolute path)").fill(project);
    await page.locator("#welcome-add-repository").click();
    await expect(page.locator("#welcome-repository-added")).toContainText("so one was initialised");
    expect(fs.existsSync(path.join(project, ".git"))).toBe(true);

    // finish: the summary takes the sections' place
    await page.locator("#welcome-finish").click();
    await expect(page.locator("#welcome-done-title")).toBeFocused();
    await expect(page.locator("#welcome-you")).toHaveCount(0);
    await expect(page.locator("#summary-name")).toContainText("Priya");
    // every palette and mode is in the page; CSS shows the ones in force
    await expect(page.locator("#summary-look")).toContainText(/Moss & Paper,\s+dark/, { useInnerText: true });
    await expect(page.locator("#summary-engines")).toContainText(/Claude Code ✓,\s+OpenCode ✓/);
    await expect(page.locator("#summary-default-engine")).toContainText("Claude Code");
    await expect(page.locator("#summary-model")).toContainText("sonnet");
    await expect(page.locator("#summary-pace")).toContainText("Careful");
    await expect(page.locator("#summary-project")).toContainText("e2e-onboard");

    await page.locator("#welcome-start-channel").click();
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

  test("an old ?step= link opens the page at its section", async ({ page }) => {
    await page.goto("/welcome?step=team");
    await expect(page).toHaveURL(/\/welcome#welcome-pace$/);
    await expect(page.locator("#welcome-pace")).toBeInViewport();
  });

  test("is comfortable on a phone: no sideways scroll, Finish always in reach", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto("/welcome");
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
    await expect(page.locator("#welcome-claude")).toHaveAttribute("data-state", "ready");
    // Custom's controls are the widest thing on the page (Custom only shows them; nothing saves)
    await page.locator("#welcome-presets-custom").click();
    await expect(page.locator("#welcome-team-form")).toBeVisible();

    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    expect(overflow).toBeLessThanOrEqual(0);
    const form = (await page.locator("#welcome-team-form").boundingBox())!;
    for (const label of await page.locator("#welcome-team-form .label").all()) {
      const box = (await label.boundingBox())!;
      expect(box.x + box.width).toBeLessThanOrEqual(form.x + form.width);
    }
    // the sticky footer keeps Finish on screen halfway down
    await page.locator("#welcome-pace").scrollIntoViewIfNeeded();
    await expect(page.locator("#welcome-finish")).toBeInViewport();
  });

  test("turns desktop notifications on, and the summary says so", async ({ context, page }) => {
    await stubNotifications(context);
    await page.goto("/welcome");
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();

    const prefs = page.locator("#welcome-notify #notify-prefs");
    await expect(prefs).toHaveAttribute("data-state", "off");
    await expect(page.locator("#welcome-notify #notify-kinds")).toHaveCount(0);
    expect(await page.evaluate(() => (window as any).__requests)).toBe(0);

    // the switch is the click the browser's prompt needs
    await page.locator("#notify-enabled").check();
    await expect(prefs).toHaveAttribute("data-state", "on");
    await expect(page.locator("#notify-granted")).toBeVisible();
    expect(await page.evaluate(() => (window as any).__requests)).toBe(1);

    await page.locator("#welcome-finish").click();
    await expect(page.locator("#summary-notify")).toContainText("Desktop notifications: on", { useInnerText: true });
    await page.evaluate(() => localStorage.clear());
  });

  test("a browser that blocks notifications, or a page that can't have them, says so", async ({ browser }) => {
    const blocked = await browser.newContext({ baseURL: test.info().project.use.baseURL });
    await stubNotifications(blocked, { answer: "denied" });
    const page = await blocked.newPage();
    await page.goto("/welcome");
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
    await page.locator("#notify-enabled").click();
    await expect(page.locator("#notify-prefs")).toHaveAttribute("data-state", "blocked");
    await expect(page.locator("#notify-blocked")).toBeVisible();
    await page.locator("#welcome-finish").click();
    await expect(page.locator("#summary-notify")).toContainText("blocked by the browser", { useInnerText: true });
    await blocked.close();

    const lan = await browser.newContext({ baseURL: test.info().project.use.baseURL });
    await stubNotifications(lan, { unsupported: true });
    const other = await lan.newPage();
    await other.goto("/welcome");
    await expect(other.locator("#notify-prefs")).toHaveAttribute("data-state", "unsupported");
    await expect(other.locator("#notify-unsupported")).toContainText("http://127.0.0.1");
    await lan.close();
  });

  test("Skip setup finishes it and goes home", async ({ page }) => {
    await page.goto("/welcome");
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
    await page.locator("#skip-setup").click();
    await expect(page).toHaveURL(/\/(channels\/ch_|repositories)/);
    await expect(page.locator("#flash-info")).toContainText("Setup skipped");

    await page.goto("/");
    await expect(page).not.toHaveURL(/\/welcome/);
  });
});
