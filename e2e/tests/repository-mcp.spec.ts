import { test, expect, Page } from "@playwright/test";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import { createChannel } from "./helpers";

// The repository page's MCP inventory. The fake OpenCode reports the
// repository's own servers from `GET /config` (a local one with a fake secret
// in its environment, a remote one with credentials in its URL that fails
// until reconnected); the Claude Code section reads the .mcp.json written
// into the e2e repository here.

const MCP_JSON = fileURLToPath(new URL("../../tmp/e2e-repo/.mcp.json", import.meta.url));

test.beforeAll(() => {
  fs.writeFileSync(
    MCP_JSON,
    JSON.stringify({
      mcpServers: {
        "e2e-docs": { command: "docs-mcp", args: ["--api-key", "e2e-docs-secret-456"], env: { DOCS_TOKEN: "e2e-env-secret-789" } },
      },
    }),
  );
});

test.afterAll(() => fs.rmSync(MCP_JSON, { force: true }));

/** Expands an engine's section when no agent here uses it (collapsed by default). */
async function expand(page: Page, engine: string) {
  const table = page.locator(`#mcp-servers-${engine}`);
  if (!(await table.isVisible())) await page.locator(`#mcp-engine-${engine}-toggle`).click();
  await expect(table).toBeVisible();
}

test("a repository's MCP servers: status, secrets masked, re-register and reconnect", async ({ page }) => {
  // a channel makes OpenCode (the seeded agents' engine) in use here
  await createChannel(page);

  await page.goto("/repositories");
  const row = page.locator("#repositories li", { hasText: "e2e-repo" });
  await row.locator("[id^=repository-mcp-]").click();
  await expect(page).toHaveURL(/\/repositories\/.+/);
  await expect(page.locator("#repository-mcp-panel")).toBeVisible();

  await expand(page, "opencode");
  const opencode = page.locator("#mcp-engine-opencode");

  // the failed repository server, its error redacted
  const remote = page.locator("#mcp-server-opencode-fake-remote");
  await expect(remote.locator("[data-status=failed]")).toBeVisible();
  await expect(remote).toContainText("connect ECONNREFUSED http://127.0.0.1:9/mcp");
  await expect(page.locator("#mcp-server-opencode-fake-local [data-status=connected]")).toBeVisible();
  await expect(page.locator("#mcp-server-opencode-fake-local")).toContainText("FAKE_SECRET");

  // Re-register Canopy: canopy shows connected for this repository
  await page.locator("#mcp-reregister").click();
  await expect(page.locator("#flash-info")).toContainText("re-registered");
  await expect(page.locator("#mcp-server-opencode-canopy [data-status=connected]")).toBeVisible();

  // Reconnect the failed server
  await page.locator("#mcp-reconnect-fake-remote").click();
  await expect(remote.locator("[data-status=connected]")).toBeVisible();
  await expect(page.locator("#mcp-reconnect-fake-remote")).toHaveCount(0);

  // Claude Code loads the repository's .mcp.json, with a security note
  await expand(page, "claude_code");
  const docs = page.locator("#mcp-server-claude_code-e2e-docs");
  await expect(docs).toContainText("docs-mcp --api-key ••••");
  await expect(docs).toContainText("DOCS_TOKEN");
  await expect(page.locator("#mcp-claude-security")).toBeVisible();
  await expect(page.locator("#mcp-server-claude_code-canopy")).toBeVisible();

  // no secret reaches the page
  const text = await page.locator("body").innerText();
  for (const secret of ["fake-secret-value-123", "user:pw", "e2e-docs-secret-456", "e2e-env-secret-789"]) {
    expect(text).not.toContain(secret);
  }
  await expect(opencode).toBeVisible();

  // Refresh keeps the reconnected state (OpenCode holds it, not the page)
  await page.locator("#refresh-mcp").click();
  await expect(remote.locator("[data-status=connected]")).toBeVisible();
});
