// Captures the screenshots for docs/user-guide.md against the seeded "Acme"
// workspace, in light and dark mode. Only runs when USER_GUIDE=1:
//
//   USER_GUIDE=1 CANOPY_SEED=e2e/bin/seed-acme.exs FAKE_TURN_DELAY_MS=2500 npx playwright test user-guide
//
// Everything already on screen comes from e2e/bin/seed-acme.exs; the live
// interactions (an agent working, a permission card, a delegation) run
// against the fake OpenCode, so that text is placeholder.
import { test, expect, Page } from "@playwright/test";
import { send, timeline, clickHeader, openDetails } from "./helpers";

/** The Details side panel, whole height. */
async function detailsClip(page: Page) {
  const box = (await page.locator("#details-panel").boundingBox())!;
  return { x: Math.floor(box.x), y: 0, width: Math.ceil(box.width), height: Math.ceil(box.height) };
}

const enabled = process.env.USER_GUIDE === "1" && process.env.CANOPY_SEED !== undefined;
const dir = "../docs/user-guide/images";

async function theme(page: Page, name: "light" | "dark") {
  await page.evaluate((t) => {
    localStorage.setItem("phx:theme", t);
    document.documentElement.setAttribute("data-theme", t);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, name);
}

/** One screenshot per theme: <name>-light.png and <name>-dark.png. */
async function shot(page: Page, name: string, opts: Record<string, unknown> = {}) {
  for (const t of ["light", "dark"] as const) {
    await theme(page, t);
    await page.waitForTimeout(200);
    await page.screenshot({ path: `${dir}/${name}-${t}.png`, animations: "disabled", ...opts });
  }
  await theme(page, "light");
}

const sidebarChannel = (page: Page, name: string) =>
  page.locator('#sidebar a[id^="sidebar-channel-"]', { hasText: name }).first();

const sidebarDm = (page: Page, name: string) =>
  page.locator("#sidebar-dms a", { hasText: name }).first();

/** Opens the first thread on the page in the side panel, from its summary row. */
async function openThread(page: Page) {
  await page.locator('[id^="thread-summary-"]').first().click();
  await expect(page.locator("#thread-panel")).toBeVisible();
}

async function dismissFlash(page: Page) {
  const flash = page.locator("#flash-info");
  if (await flash.isVisible()) {
    await flash.click();
    await expect(flash).toBeHidden();
  }
}

test.describe("screenshots for the user guide", () => {
  test.skip(!enabled, "set USER_GUIDE=1 and CANOPY_SEED=e2e/bin/seed-acme.exs to capture");
  test.use({ viewport: { width: 1440, height: 900 } });

  test("capture every screen", async ({ page }) => {
    test.setTimeout(240_000);

    // -- Settings, with the billing hold the seed engaged ---------------------
    await page.goto("/settings");
    await expect(page.locator("#hold-banner")).toContainText("insufficient balance");
    await shot(page, "hold-banner", { clip: { x: 0, y: 0, width: 1440, height: 300 } });
    await page.locator("#release-hold").click();
    await expect(page.locator("#hold-banner")).toBeHidden();
    await dismissFlash(page);

    await page.locator("#check-connection").click();
    await expect(page.locator("#health-result")).toContainText(/fake/);
    await shot(page, "settings");

    await page.locator("#appearance-panel").scrollIntoViewIfNeeded();
    await shot(page, "settings-appearance", { clip: { x: 312, y: 0, width: 1128, height: 900 } });

    await page.locator("#mcp-panel").scrollIntoViewIfNeeded();
    await shot(page, "settings-mcp");

    // -- Repositories --------------------------------------------------------
    await page.goto("/repositories");
    await expect(page.locator("#repositories")).toContainText("acme-billing");
    await shot(page, "repositories");

    // -- Agents --------------------------------------------------------------
    await page.goto("/agents");
    await expect(page.locator("#active-agents")).toContainText("@backend");
    await shot(page, "agents");

    await page.locator('#active-agents a[href^="/agents/"]', { hasText: "backend" }).first().click();
    await expect(page.locator("#agent-page")).toBeVisible();
    await expect(page.locator("#agent-memory")).toContainText("small PRs");
    await shot(page, "agent-page");

    await page.locator('[id^="edit-agent-"]').click();
    await expect(page.locator("#agent-form")).toBeVisible();
    await shot(page, "agent-edit");

    // -- The seeded conversation ------------------------------------------------
    await sidebarChannel(page, "payment-retries").click();
    await expect(page.locator("#channel-name")).toContainText("payment-retries");
    await expect(timeline(page)).toContainText("Approving with two small notes");
    await shot(page, "channel");

    // reactions: the approval's two chips and the open picker
    const approval = timeline(page).locator("article", { hasText: "Approving with two small notes" }).first();
    await approval.hover();
    await approval.locator('[id^="react-msg_"]').click();
    await expect(approval.locator('[id^="react-picker-"][role="menu"]')).toBeVisible();
    const box = (await approval.boundingBox())!;
    await shot(page, "reactions", { clip: { x: box.x, y: box.y, width: box.width, height: box.height + 40 } });
    await page.mouse.click(5, 5);

    // the start of the conversation: root cause with a code block, delegation
    await openThreads(page);
    await page.locator("#timeline-scroll").evaluate((el) => (el.scrollTop = 0));
    await page.waitForTimeout(300);
    await shot(page, "channel-conversation");
    await page.locator("#timeline-scroll").evaluate((el) => (el.scrollTop = el.scrollHeight));

    // Activity on, with the last turn's card open
    await clickHeader(page, "toggle-activity");
    await expect(timeline(page)).toContainText(/finished/);
    const cards = page.locator("#timeline details");
    const last = cards.last();
    await last.locator("summary").click();
    await last.scrollIntoViewIfNeeded();
    await shot(page, "channel-activity");
    await clickHeader(page, "toggle-activity");

    // the Details panel: the whole of it, then each part that opens in place
    await openDetails(page);
    await shot(page, "details-panel");

    await clickHeader(page, "edit-task");
    await expect(page.locator("#task-panel")).toBeVisible();
    await shot(page, "task-panel", { clip: await detailsClip(page) });
    await page.locator("#task-form button", { hasText: "Cancel" }).click();

    await clickHeader(page, "edit-members");
    await expect(page.locator("#members-panel")).toBeVisible();
    await shot(page, "members-panel", { clip: await detailsClip(page) });
    await clickHeader(page, "edit-members");

    await clickHeader(page, "edit-schedules");
    await expect(page.locator("#schedules-panel")).toBeVisible();
    await page.locator("#details-automation").scrollIntoViewIfNeeded();
    await shot(page, "schedules-panel", { clip: await detailsClip(page) });
    await clickHeader(page, "edit-schedules");

    await clickHeader(page, "edit-budget");
    await expect(page.locator("#budget-panel")).toBeVisible();
    await shot(page, "budget-panel", { clip: await detailsClip(page) });
    await clickHeader(page, "edit-budget-row");
    await page.locator("#toggle-details").click();
    await expect(page.locator("#details-panel")).toBeHidden();

    await clickHeader(page, "open-changes");
    await expect(page.locator("#changes-modal")).toBeVisible();
    await page.locator('[id^="changed-file-"]', { hasText: "payments.py" }).first().click();
    await expect(page.locator("#file-diff")).toContainText("claim_charge");
    await shot(page, "changes-modal");
    await page.locator("#close-changes").click();

    // composer autocomplete
    await page.locator("#composer-input").fill("@re");
    await expect(page.locator("#composer-suggestions")).toContainText("@researcher");
    await shot(page, "composer-autocomplete", { clip: { x: 312, y: 640, width: 1128, height: 260 } });
    await page.locator("#composer-input").fill("");

    // attachments: the ticket screenshot on Priya's first post and the
    // researcher's shared write-up, then the library picker
    const image = page.locator('[id^="attachment-"][data-kind="image"] img').first();
    await image.evaluate((el: HTMLImageElement) => el.complete || new Promise((r) => (el.onload = r)));
    await page.locator("article", { has: image }).first().scrollIntoViewIfNeeded();
    await page.waitForTimeout(300);
    await shot(page, "attachments");
    await page.locator("#timeline-scroll").evaluate((el) => (el.scrollTop = el.scrollHeight));
    await page.locator("#composer-library").click();
    await expect(page.locator("#library-documents")).toContainText("enqueue-paths.md");
    await shot(page, "library-picker");
    await page.locator("#close-library").click();

    // -- A channel over its spend limit -------------------------------------------
    await sidebarChannel(page, "invoice-pdf-export").click();
    await expect(page.locator("#limit-bar")).toBeVisible();
    await shot(page, "spend-limit-reached");

    // -- A thread and a schedule in the other repository -------------------------
    await sidebarChannel(page, "checkout-latency").click();
    await expect(timeline(page)).toContainText("priceCart");
    await openThread(page);
    await shot(page, "channel-thread");

    // -- The Threads inbox: the latency thread has replies Priya has not read --
    await page.locator("#thread-panel-close").click();
    await page.locator("#rail-threads").click();
    await expect(page.locator('[id^="thread-row-"]').first()).toContainText("priceCart");
    await shot(page, "threads-inbox");

    // -- Asking for feedback on an image -------------------------------------------
    await sidebarChannel(page, "brand-logo").click();
    const logo = page.locator('[id^="attachment-"][data-kind="image"] img').first();
    await logo.evaluate((el: HTMLImageElement) => el.complete || new Promise((r) => (el.onload = r)));
    await page.locator("#timeline-scroll").evaluate((el) => (el.scrollTop = 0));
    await page.waitForTimeout(300);
    await shot(page, "image-feedback");

    // -- Archived ------------------------------------------------------------------
    await page.locator('[id^="sidebar-archived-"] summary').first().click();
    await sidebarChannel(page, "q3-tax-rates").click();
    await expect(page.locator("#archived-bar")).toBeVisible();
    await shot(page, "archived-channel");

    // -- Direct messages --------------------------------------------------------------
    await page.locator("#sidebar-new-dm").click();
    await expect(page.locator("#dm-picker-dialog")).toBeVisible();
    await page.locator("#dm-agents label", { hasText: "reviewer" }).first().click();
    await page.locator("#dm-agents label", { hasText: "researcher" }).first().click();
    await shot(page, "dm-picker");
    await page.locator("#close-dm-picker").click();

    await sidebarDm(page, "@reviewer").click();
    await expect(timeline(page)).toContainText("review checklist");
    await shot(page, "dm");

    await sidebarDm(page, "@finops").click();
    await expect(timeline(page)).toContainText("Ranked by expected savings");
    await shot(page, "audit-dm");

    // -- Files ----------------------------------------------------------------------
    await page.goto("/files");
    await expect(page.locator("#files")).toContainText("support-ticket-4821.png");
    await shot(page, "files-page");

    // -- Costs ----------------------------------------------------------------------
    await page.setViewportSize({ width: 1440, height: 1780 });
    await page.goto("/costs");
    await expect(page.locator("#budgets")).toContainText("invoice-pdf-export");
    await expect(page.locator("#request-audit")).toContainText("@finops");
    await shot(page, "costs");
    await page.setViewportSize({ width: 1440, height: 900 });

    // -- Live: a new channel and an agent at work (fake OpenCode) --------------------
    await page.goto("/channels/new");
    await page.getByLabel("Repository").selectOption({ label: "acme-billing" });
    await page.getByLabel("Name (slug, shown as #name)").fill("refund-webhooks");
    await page.getByLabel("Topic").fill("Refund webhooks fail silently when the gateway times out");
    await page.getByLabel(/Spend limit/).fill("2");
    const owner = page.getByLabel("Initial owner");
    const backendValue = await owner.locator("option", { hasText: "backend" }).first().getAttribute("value");
    await owner.selectOption(backendValue!);
    await shot(page, "new-channel");
    await page.locator("#create-channel").click();
    await expect(page).toHaveURL(/\/channels\/ch_/);
    await dismissFlash(page);
    await shot(page, "channel-empty");

    await send(page, "Refund webhooks fail silently when the gateway times out. Read webhooks.py and post a plan before changing anything.");
    const card = page.locator('[id^="telemetry-"]').first();
    await expect(card).toContainText(/is (researching|thinking|building|working)/);
    await card.scrollIntoViewIfNeeded();
    await shot(page, "agent-working");

    await expect(timeline(page)).toContainText("Acknowledged", { timeout: 30_000 });
    await expect(card).toBeHidden();
    await shot(page, "agent-replied");

    await send(page, "Please append a line to notes.txt; this needs a permission.");
    const perm = page.locator('[id^="permission-"]').first();
    await expect(perm).toContainText("notes.txt", { timeout: 30_000 });
    await perm.scrollIntoViewIfNeeded();
    await shot(page, "permission-card");
    await page.locator('[id^="permission-"][id$="-once"]').first().click();
    await expect(perm).toBeHidden({ timeout: 30_000 });

    await send(page, "/delegate @researcher list every webhook handler that can reach the refund endpoint");
    await expect(timeline(page)).toContainText("Delegation result received", { timeout: 60_000 });
    await shot(page, "delegation");

    await send(page, "/handoff @reviewer needs a second pair of eyes on the plan");
    await expect(timeline(page).locator('[id^="line-"]', { hasText: "ownership moved" }).last()).toBeVisible({ timeout: 60_000 });
    await shot(page, "handoff");

    // -- Locks: @test holds the suite, @researcher waits its turn ------------------------
    // (last: from here on every acme-billing channel shows the lock in its header)
    await send(page, "@test take the tests lock and keep it");
    await expect(page.locator("#lock-chip-tests")).toContainText("@test", { timeout: 30_000 });
    await send(page, "@researcher take the tests lock");
    await expect(page.locator("#lock-chip-tests")).toContainText("next: @researcher", { timeout: 30_000 });
    await clickHeader(page, "lock-chip-tests");
    await expect(page.locator("#lock-tests-queue")).toContainText("@researcher");
    await shot(page, "locks-panel", { clip: await detailsClip(page) });
  });
});
