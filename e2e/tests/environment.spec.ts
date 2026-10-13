// Settings → Environment → Reset from scratch, for real: the backup (VACUUM
// INTO), the clear and the reseed, with a second tab open on a channel. Only
// runs when ENV_RESET=1, because it wipes canopy_e2e.db under every spec that
// runs after it (the suite shares one server):
//
//   ENV_RESET=1 CANOPY_RESET_STEP_DELAY_MS=1500 npx playwright test tests/environment.spec.ts
//
// On the e2e database a reset takes milliseconds; the step delay (dev only,
// read by config/dev.exs) holds each step open so the running state can be
// checked. Without it that check is skipped.
//
// A reset keeps settings and repositories and reseeds, which is the state
// bin/server.sh boots into, so `ENV_RESET=1 npx playwright test` (the whole
// suite) should pass with it in its alphabetical slot.
import { test, expect } from "@playwright/test";
import fs from "node:fs";
import { createChannel } from "./helpers";

test.describe("environment reset", () => {
  test.skip(process.env.ENV_RESET !== "1", "set ENV_RESET=1 to run the real reset (it wipes canopy_e2e.db)");

  test("resets from scratch and reloads every tab onto the banner", async ({ page, context }) => {
    test.setTimeout(120_000);
    const name = `reset-${Date.now().toString(36)}`;
    const channelId = await createChannel(page, name);

    const other = await context.newPage();
    await other.goto(`/channels/${channelId}`);
    await expect(other.locator("[data-phx-main].phx-connected")).toBeAttached();

    await page.goto("/settings");
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
    await page.locator("#open-reset").click();
    await expect(page.locator("#reset-dialog")).toBeVisible();
    await expect(page.locator("#reset-confirm")).toBeFocused();
    await expect(page.locator("#confirm-reset")).toBeDisabled();
    await page.locator("#reset-confirm").fill("reset");
    await expect(page.locator("#confirm-reset")).toBeEnabled();

    let backup: string | null = null;
    try {
      await page.locator("#confirm-reset").click();

      if (process.env.CANOPY_RESET_STEP_DELAY_MS) {
        await expect(page.locator("#reset-step")).toContainText(/\(step [1-4] of 4\)/);
        await expect(page.locator("#reset-dialog")).toHaveAttribute("aria-busy", "true");
        await expect(page.locator("#cancel-reset")).toBeDisabled();
        // a running reset ignores Escape
        await page.keyboard.press("Escape");
        await expect(page.locator("#reset-dialog")).toBeVisible();
      }

      for (const tab of [page, other]) {
        await expect(tab).toHaveURL(/\/settings\?reset=rst_/, { timeout: 60_000 });
        await expect(tab.locator("#reset-result")).toContainText("Canopy was reset");
      }

      backup = (await page.locator("#reset-backup-path").textContent())!.trim();
      expect(backup).toMatch(/canopy_e2e\.\d{4}-\d{2}-\d{2}T\d{4}(-\d+)?\.db$/);
      expect(fs.existsSync(backup)).toBe(true);
      expect(fs.statSync(backup).size).toBeGreaterThan(0);

      // the channel is gone, the repository and the starters are back
      const sidebar = page.locator("#sidebar");
      await expect(sidebar).not.toContainText(name);
      await expect(sidebar).toContainText("e2e-repo");
      await expect(sidebar).toContainText("backend");
      await expect(page.locator("#reset-result")).toContainText("Seeder created");

      // a tab that comes back on the deleted channel lands on the banner too
      await other.goto(`/channels/${channelId}`);
      await expect(other).toHaveURL(/\/settings\?reset=rst_/);
    } finally {
      if (backup) fs.rmSync(backup, { force: true });
    }
  });
});
