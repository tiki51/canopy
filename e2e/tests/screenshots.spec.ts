// Captures the screenshots used by docs/manual-testing.md. Only runs when
// SCREENSHOTS=1 so the normal suite stays fast:  SCREENSHOTS=1 npx playwright test screenshots
import { test, expect } from "@playwright/test";
import { createChannel, send, timeline } from "./helpers";

const enabled = process.env.SCREENSHOTS === "1";
const dir = "../docs/screenshots";
const shot = (page: any, name: string, opts: any = {}) =>
  page.screenshot({ path: `${dir}/${name}.png`, ...opts });

test.describe("screenshots for the manual testing guide", () => {
  test.skip(!enabled, "set SCREENSHOTS=1 to capture");
  test.use({ viewport: { width: 1280, height: 820 } });

  test("capture every screen", async ({ page }) => {
    await page.goto("/settings");
    await page.locator("#check-connection").click();
    await expect(page.locator("#health-result")).toContainText(/fake/);
    await shot(page, "01-settings");

    await page.goto("/repositories");
    await expect(page.locator("#repositories")).toContainText("e2e-repo");
    await shot(page, "02-repositories");

    await page.goto("/agents");
    await expect(page.locator("#active-agents")).toContainText("@backend");
    await shot(page, "03-agents");

    await page.goto("/channels/new");
    await page.getByLabel("Repository").selectOption({ label: "e2e-repo" });
    await page.getByLabel("Name (slug, shown as #name)").fill("payment-retries");
    await page.getByLabel("Topic").fill("Invoices are occasionally charged twice");
    await shot(page, "04-new-channel");
    await page.locator("#create-channel").click();
    await expect(page).toHaveURL(/\/channels\/ch_/);
    // dismiss the "created" toast so it does not cover the header buttons
    await page.locator("#flash-info").click();
    await expect(page.locator("#flash-info")).toBeHidden();
    await shot(page, "05-empty-channel");

    await page.locator("#composer-input").fill("@re");
    await expect(page.locator("#composer-suggestions")).toContainText("@researcher");
    await shot(page, "12-composer-autocomplete", { clip: { x: 320, y: 600, width: 960, height: 220 } });
    await page.locator("#composer-input").fill("");

    await send(page, "Why are invoices sometimes charged twice? Start by reading payments.py.");
    const card = page.locator('[id^="telemetry-"]').first();
    await expect(card).toContainText(/is working/);
    await card.scrollIntoViewIfNeeded();
    await shot(page, "06-agent-working");

    await expect(timeline(page)).toContainText(/finished/);
    await expect(card).toBeHidden();
    await shot(page, "07-agent-replied");

    await send(page, "Please edit notes.txt; this needs a permission.");
    const perm = page.locator('[id^="permission-"]').first();
    await expect(perm).toContainText("+perm: test");
    await perm.scrollIntoViewIfNeeded();
    await shot(page, "08-permission-card");
    await page.locator('[id^="permission-"][id$="-once"]').first().click();
    await expect(perm).toBeHidden();

    await send(page, "/delegate @researcher list every path that can enqueue a charge");
    await expect(timeline(page)).toContainText("Delegation result received; wrapping up.");
    await timeline(page).getByText("Delegation result received").scrollIntoViewIfNeeded();
    await shot(page, "09-delegation");

    await send(page, "/handoff @reviewer needs a second pair of eyes on the fix");
    await expect(page.locator("#owner-badge")).toContainText("reviewer");
    await timeline(page).getByText("Accepted the handoff.").scrollIntoViewIfNeeded();
    await shot(page, "10-handoff");

    await page.locator("#open-changes").click();
    await expect(page.locator("#changes-modal")).toBeVisible();
    await shot(page, "11-changes-modal");
    await page.locator("#close-changes").click();

  });
});
