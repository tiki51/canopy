// The command palette (⌘K / Ctrl+K, or the sidebar's "Jump to…"): jumping,
// commands, slash commands into the composer, files, and keys that must not
// leak to the page underneath.
import { test, expect, Page } from "@playwright/test";
import path from "node:path";
import { createChannel, send, timeline, uniq } from "./helpers";

const dialog = (page: Page) => page.locator("#cmdk-dialog");
const input = (page: Page) => page.locator("#cmdk-input");
const options = (page: Page) => page.locator("#cmdk-list [role=option]");
const active = (page: Page) => page.locator('#cmdk-list [role=option][aria-selected="true"]');
const composer = (page: Page) => page.locator("#composer-input");

const png = path.resolve("../test/support/files/red.png");

async function connected(page: Page) {
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
}

async function openPalette(page: Page) {
  await connected(page);
  await page.keyboard.press("ControlOrMeta+k");
  await expect(dialog(page)).toBeVisible();
  await expect(input(page)).toBeFocused();
}

test.describe("command palette", () => {
  test("opens from the shortcut and the sidebar button; arrows move, Esc closes and gives focus back", async ({ page }) => {
    await createChannel(page);
    await connected(page);
    await composer(page).click();

    await openPalette(page);
    await expect(input(page)).toHaveAttribute("role", "combobox");
    await expect(input(page)).toHaveAttribute("aria-expanded", "true");
    await expect(input(page)).toHaveAttribute("aria-activedescendant", "cmdk-opt-0");

    // one listbox, every option has an id, groups are labelled
    await expect(page.locator("[role=listbox]")).toHaveCount(1);
    expect(await options(page).count()).toBeGreaterThan(2);
    expect(await options(page).evaluateAll(els => els.every(el => /^cmdk-opt-\d+$/.test(el.id)))).toBe(true);
    await expect(page.locator("#cmdk-list [role=group]").first()).toHaveAttribute("aria-labelledby", /cmdk-group-/);

    await page.keyboard.press("ArrowDown");
    await page.keyboard.press("ArrowDown");
    await page.keyboard.press("ArrowUp");
    await expect(active(page)).toHaveId("cmdk-opt-1");
    await expect(input(page)).toHaveAttribute("aria-activedescendant", "cmdk-opt-1");
    // up from the top wraps to the bottom
    await page.keyboard.press("ArrowUp");
    await page.keyboard.press("ArrowUp");
    await expect(active(page)).toHaveId(`cmdk-opt-${(await options(page).count()) - 1}`);

    await page.keyboard.press("Escape");
    await expect(dialog(page)).toBeHidden();
    await expect(composer(page)).toBeFocused();

    await page.locator("#cmdk-open").click();
    await expect(dialog(page)).toBeVisible();
    // the shortcut toggles it shut again
    await page.keyboard.press("ControlOrMeta+k");
    await expect(dialog(page)).toBeHidden();
  });

  test("type part of a channel name and Enter jumps there; it heads Recent afterwards", async ({ page }) => {
    const name = uniq("jumpto");
    const id = await createChannel(page, name);

    await page.goto("/agents");
    await openPalette(page);
    await page.keyboard.type(name.slice(0, -2));
    await expect(active(page)).toContainText(name);
    await page.keyboard.press("Enter");
    await expect(page).toHaveURL(`/channels/${id}`);
    await expect(page.locator("#channel-name")).toContainText(name);

    // where you are is not offered as recent; elsewhere it comes first
    await openPalette(page);
    await expect(options(page).filter({ hasText: name })).toHaveCount(0);
    await page.keyboard.press("Escape");

    await page.goto("/settings");
    await openPalette(page);
    const recent = page.locator("#cmdk-list [role=group]").first();
    await expect(recent).toContainText("Recent");
    await expect(recent.locator("[role=option]").first()).toContainText(name);
    await expect(active(page)).toContainText(name);
  });

  test("keys meant for the palette never reach the page", async ({ page }) => {
    await createChannel(page);
    await connected(page);

    // a draft survives the palette, and Enter in it doesn't send the draft
    await composer(page).fill("half-written draft");
    await openPalette(page);
    await page.keyboard.type("qqzzxxnothing");
    await expect(page.locator("#cmdk-empty")).toBeVisible();
    await page.keyboard.press("Enter");
    await page.keyboard.press("Escape");
    await expect(dialog(page)).toBeHidden();
    await expect(composer(page)).toHaveValue("half-written draft");
    await expect(timeline(page)).not.toContainText("half-written draft");
    await composer(page).fill("");

    // Esc in the palette closes the palette, not the thread panel under it
    await send(page, "A root for the thread. No need to reply.");
    const root = timeline(page).locator("article", { hasText: "A root for the thread" }).first();
    await root.hover();
    await root.locator('[id^="reply-"]').click();
    await expect(page.locator("#thread-panel")).toBeVisible();
    await expect(page.locator("#thread-composer-input")).toBeFocused();
    await openPalette(page);
    await page.keyboard.press("Escape");
    await expect(dialog(page)).toBeHidden();
    await expect(page.locator("#thread-panel")).toBeVisible();
    await expect(page).toHaveURL(/\?thread=msg_/);
    await expect(page.locator("#thread-composer-input")).toBeFocused();
    // the panel's own Esc still works once the palette is gone
    await page.keyboard.press("Escape");
    await expect(page.locator("#thread-panel")).toBeHidden();

    // nor the brief editor's
    await page.locator("#edit-brief").click();
    await page.locator("#brief-form textarea").fill("Goal: keep the palette out of the way");
    await openPalette(page);
    await page.keyboard.press("Escape");
    await expect(dialog(page)).toBeHidden();
    await expect(page.locator("#brief-editor")).toBeVisible();
    await expect(page.locator("#brief-form textarea")).toHaveValue("Goal: keep the palette out of the way");
  });

  test("> commands: theme and a new channel in a repository", async ({ page }) => {
    await page.goto("/settings");
    await openPalette(page);
    await page.keyboard.type(">theme dark");
    await expect(page.locator("#cmdk-chip")).toHaveText("> commands");
    await expect(active(page)).toContainText("Theme: Dark");
    await page.keyboard.press("Enter");
    await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
    await expect(dialog(page)).toBeHidden();

    // Backspace on an empty query leaves the mode
    await openPalette(page);
    await page.keyboard.type(">");
    await expect(page.locator("#cmdk-chip")).toBeVisible();
    await page.keyboard.press("Backspace");
    await expect(page.locator("#cmdk-chip")).toBeHidden();

    await page.keyboard.type(">new channel in e2e-repo");
    await expect(active(page)).toContainText("New channel in e2e-repo");
    await page.keyboard.press("Enter");
    await expect(page).toHaveURL(/\/channels\/new\?repository_id=/);
    await expect(page.getByLabel("Repository").locator("option:checked")).toHaveText("e2e-repo");
  });

  test("/ commands: in a channel they go into the composer", async ({ page }) => {
    await createChannel(page);
    await openPalette(page);
    await page.keyboard.type("/delegate");
    await expect(active(page)).toContainText("/delegate @agent task");
    await page.keyboard.press("Enter");
    await expect(dialog(page)).toBeHidden();
    await expect(composer(page)).toHaveValue("/delegate @");
    await expect(composer(page)).toBeFocused();
    await expect(page.locator("#composer-suggestions")).toBeVisible();

    // what was typed after the command comes along
    await composer(page).fill("");
    await openPalette(page);
    await page.keyboard.type("/handoff @backend please take it from here");
    await page.keyboard.press("Enter");
    await expect(composer(page)).toHaveValue("/handoff @backend please take it from here");
  });

  test("/ commands elsewhere ask for a channel; /stop stops it without leaving", async ({ page }) => {
    const name = uniq("slashto");
    const id = await createChannel(page, name);

    await page.goto("/settings");
    await openPalette(page);
    await page.keyboard.type("/delegate");
    await expect(active(page)).toContainText("choose a channel");
    await page.keyboard.press("Enter");
    await expect(page.locator("#cmdk-chip")).toHaveText("/delegate ›");
    await page.keyboard.type(name);
    await expect(active(page)).toContainText(name);
    await page.keyboard.press("Enter");
    await expect(page).toHaveURL(`/channels/${id}`);
    await expect(composer(page)).toHaveValue("/delegate @");

    await page.goto("/agents");
    await openPalette(page);
    await page.keyboard.type("/stop");
    await page.keyboard.press("Enter");
    await page.keyboard.type(name);
    await expect(active(page)).toContainText(name);
    await page.keyboard.press("Enter");
    await expect(page.locator("#flash-info")).toContainText(`Stopped #${name}`);
    await expect(page).toHaveURL("/agents");
  });

  test("@ mode: Enter opens an agent's page, Shift+Enter messages it", async ({ page }) => {
    await createChannel(page);
    await page.goto("/settings");
    await openPalette(page);
    await page.keyboard.type("@backend");
    await expect(page.locator("#cmdk-chip")).toHaveText("@ agents");
    await expect(active(page)).toContainText("@backend");
    await page.keyboard.press("Shift+Enter");
    await expect(page).toHaveURL(/\/channels\/ch_/);
    await expect(page.locator("#sidebar-dms")).toContainText("@backend");

    await openPalette(page);
    await page.keyboard.type("@backend");
    await page.keyboard.press("Enter");
    await expect(page).toHaveURL(/\/agents\/agt_/);
  });

  test("files are searched by name; Shift+Enter in a channel attaches one", async ({ page }) => {
    await createChannel(page);
    await page.locator("#upload-form input[type=file]").setInputFiles([png]);
    await expect(page.locator("#composer-files")).toContainText("red.png");
    await send(page, "Here is the red square. No need to reply.");
    await expect(timeline(page).locator('[id^="attachment-"]')).toHaveCount(1);

    await page.goto("/agents");
    await openPalette(page);
    await page.keyboard.type("red.pn");
    await expect(options(page).filter({ hasText: "red.png" }).first()).toContainText("image");

    await createChannel(page);
    await openPalette(page);
    await page.keyboard.type("red.png");
    await expect(active(page)).toContainText("red.png");
    await expect(active(page)).toContainText("attach");
    await page.keyboard.press("Shift+Enter");
    await expect(page.locator('[id^="picked-doc_"]')).toHaveCount(1);
  });

  test("on a phone the sidebar button opens it full width over the closed drawer", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto("/agents");
    await connected(page);
    await page.locator('label[for="app-drawer"][aria-label="Open the menu"]').first().click();
    await expect(page.locator("#app-drawer")).toBeChecked();
    await page.locator("#cmdk-open").click();
    await expect(dialog(page)).toBeVisible();
    await expect(page.locator("#app-drawer")).not.toBeChecked();
    expect(Math.round((await dialog(page).boundingBox())!.width)).toBe(390);
    const fontSize = await input(page).evaluate(el => parseFloat(getComputedStyle(el).fontSize));
    expect(fontSize).toBeGreaterThanOrEqual(16);
  });

  test("first-run setup has no palette", async ({ page }) => {
    await page.goto("/welcome");
    await connected(page);
    await page.keyboard.press("ControlOrMeta+k");
    await expect(page.locator("#cmdk")).toHaveCount(0);
  });

  test("on a Mac, Ctrl+K stays the composer's kill-line", async ({ page }) => {
    test.skip(process.platform !== "darwin", "macOS key binding");
    await createChannel(page);
    await connected(page);
    await composer(page).fill("keep this");
    await composer(page).press("Home");
    await page.keyboard.press("Control+k");
    await expect(dialog(page)).toBeHidden();
  });
});
