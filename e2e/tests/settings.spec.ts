import { test, expect } from "@playwright/test";
import { gotoLive, reload } from "./helpers";
import { sql } from "./site-helpers";

test.describe("settings", () => {
  test("checks the OpenCode connection and shows MCP install details", async ({ page }) => {
    await gotoLive(page, "/settings");
    const fakePort = process.env.FAKE_OPENCODE_PORT || "4396";
    await expect(page.getByLabel("Server URL")).toHaveValue(new RegExp(`127\\.0\\.0\\.1:${fakePort}`));

    await page.locator("#check-connection").click();
    await expect(page.locator("#health-result")).toContainText(/fake-1\.0/);

    await expect(page.locator("#mcp-url")).toContainText("/mcp");
    await expect(page.locator("#plugin-source")).toContainText("canopy_session_id");
    await expect(page.locator("#plugin-path")).toContainText("canopy.js");
  });

  test("switches the palette and keeps it across reloads", async ({ page }) => {
    await gotoLive(page, "/settings");
    const html = page.locator("html");
    await expect(html).toHaveAttribute("data-palette", "blue-hour");
    await expect(page.locator("#palette-blue-hour")).toHaveAttribute("aria-checked", "true");

    await page.locator("#palette-moss").click();
    await expect(html).toHaveAttribute("data-palette", "moss");
    await expect(page.locator("#palette-moss")).toHaveAttribute("aria-checked", "true");
    await expect(page.locator("#palette-blue-hour")).toHaveAttribute("aria-checked", "false");

    await reload(page);
    await expect(html).toHaveAttribute("data-palette", "moss");
    await expect(page.locator("#palette-moss")).toHaveAttribute("aria-checked", "true");
    await expect(page.locator('meta[name="theme-color"]')).not.toHaveAttribute("content", "#0A1730");

    await page.locator("#palette-blue-hour").click();
    await expect(html).toHaveAttribute("data-palette", "blue-hour");
  });

  test("the appearance mode and the rail toggle share state", async ({ page }) => {
    await gotoLive(page, "/settings");
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

  test("sets the default models", async ({ page }) => {
    await gotoLive(page, "/settings");

    // OpenCode's default comes from the fake server's provider list
    const provider = page.locator("#opencode-default-provider");
    await expect(provider).toBeEnabled();
    await provider.selectOption("opencode");
    const model = page.locator("#opencode-default-model");
    await expect(model).toBeEnabled();
    await model.selectOption("gpt-5-nano");
    await page.locator("#save-opencode").click();
    await expect(page.locator("#flash-info")).toContainText("use the default model");
    await expect(page.locator("#opencode-default-price")).toContainText("$0.05 in / $0.4 out");

    await page.locator("#claude-default-model").selectOption("sonnet");
    await page.locator("#claude-default-effort").selectOption("high");
    await page.locator("#save-claude").click();
    await expect(page.locator("#flash-info")).toContainText("default model");

    // the seeded agents have no model of their own: they inherit
    await gotoLive(page, "/agents");
    await expect(page.locator("#default-model-claude_code")).toContainText("sonnet");
    await expect(page.locator("#default-model-opencode")).toContainText("opencode/gpt-5-nano");
    await expect(page.locator("#active-agents").getByText("default · opencode/gpt-5-nano").first()).toBeVisible();

    // put the engines back on their own defaults for the specs that follow
    await gotoLive(page, "/settings");
    await expect(provider).toBeEnabled();
    await provider.selectOption("");
    await page.locator("#save-opencode").click();
    await expect(page.locator("#opencode-default-price")).toBeHidden();
    await page.locator("#claude-default-model").selectOption("");
    await page.locator("#claude-default-effort").selectOption("");
    await page.locator("#save-claude").click();
    await gotoLive(page, "/agents");
    await expect(page.locator("#default-model-opencode")).toContainText("OpenCode's own default");
    await expect(page.locator("#default-model-claude_code")).toContainText("Claude Code's own default");
  });

  test("the default engine moves the seeded agents with it", async ({ page }) => {
    await gotoLive(page, "/settings");
    const opencode = page.locator("#default-engine-choice-opencode");
    const claude = page.locator("#default-engine-choice-claude_code");
    await expect(opencode).toHaveAttribute("aria-checked", "true");
    await expect(opencode).toHaveAttribute("data-ready", "ready");
    await expect(page.locator("#engine-usage")).toContainText(/\d+ agents? uses? the default/);

    try {
      await claude.click();
      await expect(claude).toHaveAttribute("aria-checked", "true");
      await expect(page.locator("#flash-info")).toContainText("Claude Code is the default engine");

      // the seeded agents name no engine: the list shows the default's, muted
      await gotoLive(page, "/agents");
      await expect(page.locator("#default-engine-label")).toContainText("Claude Code");
      const backend = page.locator('#active-agents [id^="engine-"]', { hasText: "Claude Code" });
      await expect(backend.first().locator("[data-default-engine]")).toBeVisible();
    } finally {
      // back to OpenCode (bin/server.sh) for the specs that follow
      sql("UPDATE settings SET default_engine = 'opencode'");
    }
  });

  test("three engine cards, and Check Codex against the fake", async ({ page }) => {
    await gotoLive(page, "/settings");
    const cards = page.locator("#default-engine-choice [role=radio]");
    await expect(cards).toHaveCount(3);
    await expect(cards.nth(0)).toHaveAttribute("id", "default-engine-choice-claude_code");
    await expect(cards.nth(1)).toHaveAttribute("id", "default-engine-choice-codex");
    await expect(cards.nth(2)).toHaveAttribute("id", "default-engine-choice-opencode");
    // found on PATH, not checked on mount
    const codex = page.locator("#default-engine-choice-codex");
    await expect(codex).toHaveAttribute("data-ready", "installed");

    await page.locator("#check-codex").click();
    await expect(page.locator("#codex-check-result")).toContainText("signed in");
    await expect(codex).toHaveAttribute("data-ready", "ready");

    // a default model and effort from Codex's list, shown on the Agents hint
    const model = page.locator("#codex-default-model");
    await expect(model).toBeEnabled();
    const id = await model.locator("option").nth(1).getAttribute("value");
    try {
      await model.selectOption(id!);
      const effort = page.locator("#codex-default-effort");
      const level = await effort.locator("option").nth(1).getAttribute("value");
      await effort.selectOption(level!);
      await page.locator("#save-codex").click();
      await expect(page.locator("#flash-info")).toContainText("Saved.");
      await gotoLive(page, "/agents");
      await expect(page.locator("#default-model-codex")).toContainText(id!);
    } finally {
      sql("UPDATE settings SET codex_default_model = NULL, codex_default_effort = NULL");
    }
  });

  test("saves the display name", async ({ page }) => {
    await gotoLive(page, "/settings");
    await page.getByLabel("Display name").fill("Steven");
    await page.locator("#save-profile").click();
    await reload(page);
    await expect(page.getByLabel("Display name")).toHaveValue("Steven");
  });
});
