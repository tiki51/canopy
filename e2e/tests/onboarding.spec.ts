import { test, expect, Page } from "@playwright/test";
import fs from "node:fs";
import path from "node:path";
import { iso, sql } from "./site-helpers";
import { stubNotifications } from "./notify-helpers";

// bin/server.sh marks setup done so pages open as on an existing install;
// these specs clear `onboarded_at` straight in the e2e database (the server
// keeps running; SQLite is in WAL mode) to start from a fresh install, where
// setup is a modal over whatever page opens.
const fresh = () => sql("UPDATE settings SET onboarded_at = NULL, default_engine = NULL");
const onboarded = () => sql(`UPDATE settings SET onboarded_at = '${iso(new Date())}'`);

const dialog = (page: Page) => page.locator("#setup-dialog");
const current = (page: Page) => page.locator("#setup-steps [aria-current=step]");
const next = (page: Page) => page.locator("#setup-next").click();

// The page and the setup modal (a nested LiveView, #setup) both connected.
async function connected(page: Page) {
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
  await expect(page.locator("#setup.phx-connected")).toBeAttached();
}

// Where focus is, as an id (or the tag), and whether it is in the modal.
const focus = (page: Page) =>
  page.evaluate(() => {
    const el = document.activeElement;
    return { id: el?.id || el?.tagName || "", inside: !!el?.closest("#setup-dialog") };
  });

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

  test("walks a fresh install through the modal, step by step, to its first channel", async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto("/");
    // the normal home, with setup over it
    await expect(page).toHaveURL(/\/(channels\/ch_|repositories)/);
    await connected(page);
    await expect(dialog(page)).toBeVisible();
    await expect(dialog(page)).toHaveAttribute("aria-modal", "true");
    await expect(page.locator("#sidebar")).toBeVisible();
    await expect(page.locator("#app-shell")).toHaveAttribute("inert", "");
    // a centred panel, not a page
    const panel = (await page.locator("#setup-panel").boundingBox())!;
    expect(panel.width).toBeLessThanOrEqual(680);
    expect(panel.x).toBeGreaterThan(300);

    // you: focus starts in the field; it saves as it is typed, Enter moves on
    await expect(current(page)).toHaveAttribute("id", "setup-step-you");
    const name = page.getByLabel("What should the agents call you?");
    await expect(name).toBeFocused();
    await name.fill("Priya");
    await expect(page.locator("#welcome-you-saved")).toBeVisible();
    await name.press("Enter");
    await expect(current(page)).toHaveAttribute("id", "setup-step-look");
    await expect(page.locator("#welcome-look-title")).toBeFocused();

    // look: applies at once, to the app behind as well, and is kept by the browser
    const html = page.locator("html");
    const sidebarBg = () => page.locator("#sidebar").evaluate((el) => getComputedStyle(el).backgroundColor);
    const before = await sidebarBg();
    await page.locator("#palette-moss").click();
    await page.locator("#appearance-mode-dark").click();
    await expect(html).toHaveAttribute("data-palette", "moss");
    await expect(html).toHaveAttribute("data-theme", "dark");
    expect(await sidebarBg()).not.toBe(before);

    // Back keeps the name
    await page.locator("#setup-back").click();
    await expect(name).toHaveValue("Priya");

    // still a fresh install after a reload: the modal again, with what was chosen
    await page.reload();
    await connected(page);
    await expect(dialog(page)).toBeVisible();
    await expect(html).toHaveAttribute("data-palette", "moss");
    await expect(html).toHaveAttribute("data-theme", "dark");
    await expect(page.getByLabel("What should the agents call you?")).toHaveValue("Priya");

    // the indicator jumps: engines; the fake Claude Code and the fake OpenCode both answer
    await page.locator("#setup-step-engines").click();
    await expect(current(page)).toHaveAttribute("id", "setup-step-engines");
    await expect(page.locator("#setup-step-you")).toHaveAttribute("data-state", "done");
    await expect(page.locator("#welcome-claude")).toHaveAttribute("data-state", "ready");
    await expect(page.locator("#welcome-claude-status")).toContainText("priya@acme.example");
    await expect(page.locator("#welcome-opencode")).toHaveAttribute("data-state", "ready");
    await expect(page.locator("#welcome-opencode-status")).toContainText("fake-1.0");
    await expect(page.locator("#welcome-opencode-default-provider")).toBeEnabled();
    // default engine: both ready, so Claude Code, saved at once; a pick saves too
    const opencodeCard = page.locator("#welcome-engine-choice-opencode");
    const claudeCard = page.locator("#welcome-engine-choice-claude_code");
    await expect(claudeCard).toHaveAttribute("aria-checked", "true");
    await expect(claudeCard).toHaveAttribute("data-ready", "ready");
    await expect(opencodeCard).toHaveAttribute("data-ready", "ready");
    await expect.poll(() => sql("SELECT default_engine FROM settings")).toBe("claude_code");
    await opencodeCard.click();
    await expect(opencodeCard).toHaveAttribute("aria-checked", "true");
    await expect.poll(() => sql("SELECT default_engine FROM settings")).toBe("opencode");
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
    await next(page);
    await expect(page.locator("#welcome-presets-balanced")).toHaveAttribute("aria-checked", "true");
    await page.locator("#welcome-presets-careful").click();
    await expect(page.locator("#welcome-presets-careful")).toHaveAttribute("aria-checked", "true");
    await expect(page.locator("#welcome-pace-saved")).toBeVisible();

    // notifications
    await next(page);
    await expect(page.locator("#welcome-notify #notify-enabled")).toBeAttached();

    // project: added by its own button, with the result inline
    await next(page);
    await page.getByLabel("Project folder (absolute path)").fill(project);
    await page.locator("#welcome-add-repository").click();
    await expect(page.locator("#welcome-repository-added")).toContainText("so one was initialised");
    expect(fs.existsSync(path.join(project, ".git"))).toBe(true);

    // Esc asks instead of closing; the question takes focus, and Esc again takes it back
    await page.locator("#welcome-project-title").focus();
    await page.keyboard.press("Escape");
    await expect(page.locator("#setup-skip-confirm")).toContainText("Skip setup?");
    await expect(page.locator("#setup-keep-going")).toBeFocused();
    await page.keyboard.press("Escape");
    await expect(page.locator("#setup-skip-confirm")).toHaveCount(0);
    await expect(page.locator("#welcome-finish")).toBeFocused();
    await expect(dialog(page)).toBeVisible();

    // Tab and Shift+Tab stay in the modal
    for (let i = 0; i < 25; i++) {
      await page.keyboard.press("Tab");
      expect((await focus(page)).inside).toBe(true);
    }
    for (let i = 0; i < 5; i++) {
      await page.keyboard.press("Shift+Tab");
      expect((await focus(page)).inside).toBe(true);
    }

    // finish: the summary takes the steps' place
    await page.locator("#welcome-finish").click();
    await expect(page.locator("#welcome-done-title")).toBeFocused();
    await expect(page.locator("#setup-steps")).toHaveCount(0);
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
    await expect(dialog(page)).toHaveCount(0);
    await expect(page.locator("#app-shell")).not.toHaveAttribute("inert", "");
    const repositoryId = new URL(page.url()).searchParams.get("repository_id")!;
    await expect(page.getByLabel("Repository")).toHaveValue(repositoryId);

    // setup is done: no modal any more
    await page.goto("/");
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
    await expect(dialog(page)).toHaveCount(0);

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

  test("is a full-screen sheet on a phone, walked with Next to the summary", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto("/");
    await connected(page);
    await expect(dialog(page)).toBeVisible();

    const panel = (await page.locator("#setup-panel").boundingBox())!;
    expect(Math.round(panel.width)).toBe(390);
    expect(Math.round(panel.height)).toBe(844);
    await expect(page.locator("#setup-progress")).toContainText("1 of 6");

    const steps = ["you", "look", "engines", "pace", "notify", "project"];
    for (const [i, step] of steps.entries()) {
      await expect(current(page)).toHaveAttribute("id", `setup-step-${step}`);
      await expect(page.locator("#setup-progress")).toContainText(`${i + 1} of 6`);
      // nothing sideways, and the primary button always on screen
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
      expect(overflow).toBeLessThanOrEqual(0);
      const primary = page.locator("[data-setup-primary]");
      await expect(primary).toBeInViewport();

      if (step === "engines") await expect(page.locator("#welcome-claude")).toHaveAttribute("data-state", "ready");
      if (step === "pace") {
        // Custom's controls are the widest thing here (Custom only shows them; nothing saves)
        await page.locator("#welcome-presets-custom").click();
        await expect(page.locator("#welcome-team-form")).toBeVisible();
        const form = (await page.locator("#welcome-team-form").boundingBox())!;
        for (const label of await page.locator("#welcome-team-form .label").all()) {
          const box = (await label.boundingBox())!;
          expect(box.x + box.width).toBeLessThanOrEqual(form.x + form.width);
        }
        await page.locator("#welcome-team-form").scrollIntoViewIfNeeded();
        await expect(primary).toBeInViewport();
      }
      if (step !== "project") await next(page);
    }

    await page.locator("#welcome-finish").click();
    await expect(page.locator("#welcome-done-title")).toBeFocused();
    await expect(page.locator("#welcome-look-around")).toBeInViewport();
    const url = page.url();
    await page.locator("#welcome-look-around").click();
    await expect(dialog(page)).toHaveCount(0);
    expect(page.url()).toBe(url);
    await page.evaluate(() => localStorage.clear());
  });

  test("an old /welcome?step= link opens the modal at its step, and closing drops ?setup=", async ({ page }) => {
    await page.goto("/welcome?step=team");
    await expect(page).toHaveURL(/\/(channels\/ch_[^?]+|repositories)\?setup=pace$/);
    await connected(page);
    await expect(current(page)).toHaveAttribute("id", "setup-step-pace");
    await expect(page.locator("#welcome-pace")).toBeVisible();

    await page.locator("#skip-setup").click();
    await expect(dialog(page)).toHaveCount(0);
    await expect(page).not.toHaveURL(/setup=/);
  });

  test("Run setup again opens it over Settings, and focus comes back after", async ({ page }) => {
    onboarded();
    await page.goto("/settings");
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
    await expect(dialog(page)).toHaveCount(0);

    await page.locator("#run-setup").click();
    await expect(dialog(page)).toBeVisible();
    await expect(current(page)).toHaveAttribute("id", "setup-step-you");
    // the same picker and switch are in the modal, so Settings' own step aside meanwhile
    await expect(page.locator("#appearance-in-setup")).toBeAttached();
    await page.locator("#setup-step-look").click();
    await expect(page.locator("#palette-moss")).toHaveCount(1);
    await page.locator("#setup-step-notify").click();
    await expect(page.locator("#notify-prefs")).toHaveCount(1);

    await page.keyboard.press("Escape");
    await page.locator("#setup-skip-confirmed").click();
    await expect(dialog(page)).toHaveCount(0);
    await expect(page).toHaveURL(/\/settings$/);
    await expect(page.locator("#flash-info")).toContainText("Setup skipped");
    await expect(page.locator("#appearance-panel #palette-moss")).toBeVisible();
    await expect(page.locator("#run-setup")).toBeFocused();
  });

  test("turns desktop notifications on, and the summary says so", async ({ context, page }) => {
    await stubNotifications(context);
    await page.goto("/");
    await connected(page);
    await page.locator("#setup-step-notify").click();

    const prefs = page.locator("#welcome-notify #notify-prefs");
    await expect(prefs).toHaveAttribute("data-state", "off");
    await expect(page.locator("#welcome-notify #notify-kinds")).toHaveCount(0);
    expect(await page.evaluate(() => (window as any).__requests)).toBe(0);

    // the switch is the click the browser's prompt needs
    await page.locator("#notify-enabled").check();
    await expect(prefs).toHaveAttribute("data-state", "on");
    await expect(page.locator("#notify-granted")).toBeVisible();
    expect(await page.evaluate(() => (window as any).__requests)).toBe(1);

    await next(page);
    await page.locator("#welcome-finish").click();
    await expect(page.locator("#summary-notify")).toContainText("Desktop notifications: on", { useInnerText: true });
    await page.evaluate(() => localStorage.clear());
  });

  test("a browser that blocks notifications, or a page that can't have them, says so", async ({ browser }) => {
    const blocked = await browser.newContext({ baseURL: test.info().project.use.baseURL });
    await stubNotifications(blocked, { answer: "denied" });
    const page = await blocked.newPage();
    await page.goto("/");
    await connected(page);
    await page.locator("#setup-step-notify").click();
    await page.locator("#notify-enabled").click();
    await expect(page.locator("#notify-prefs")).toHaveAttribute("data-state", "blocked");
    await expect(page.locator("#notify-blocked")).toBeVisible();
    await page.locator("#setup-step-project").click();
    await page.locator("#welcome-finish").click();
    await expect(page.locator("#summary-notify")).toContainText("blocked by the browser", { useInnerText: true });
    await blocked.close();

    // finishing marked setup done; the next page is a fresh install again
    fresh();
    const lan = await browser.newContext({ baseURL: test.info().project.use.baseURL });
    await stubNotifications(lan, { unsupported: true });
    const other = await lan.newPage();
    await other.goto("/welcome?step=notifications");
    await connected(other);
    await expect(other.locator("#notify-prefs")).toHaveAttribute("data-state", "unsupported");
    await expect(other.locator("#notify-unsupported")).toContainText("http://127.0.0.1");
    await lan.close();
  });

  test("Skip setup finishes it and closes the modal on the page", async ({ page }) => {
    await page.goto("/");
    await connected(page);
    const url = page.url();
    await page.locator("#skip-setup").click();
    await expect(dialog(page)).toHaveCount(0);
    expect(page.url()).toBe(url);
    await expect(page.locator("#flash-info")).toContainText("Setup skipped");

    await page.goto("/");
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
    await expect(dialog(page)).toHaveCount(0);
  });
});
