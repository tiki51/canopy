// Captures the stills for the canopy_site homepage at 2x, in dark and light,
// into canopy_site/src/assets/shots, all from one Feature build playbook run:
// "Add a CSV export to the Reports page". Only runs when SITE=1:
//
//   SITE=1 CANOPY_SEED=e2e/bin/seed-reports.exs FAKE_TURN_DELAY_MS=2500 npx playwright test tests/site-shots.spec.ts
//
// The run is started from the Start page and played live: the coordinator
// (@project-manager) and its roster run on the fake Claude Code, which scripts
// every turn (e2e/fake-claude/claude.mjs, "the site's playbook story"), so
// every card, line and diff is the app's own rendering of a real turn. The
// user's part is the spec's: start the run, pick design B, allow @backend's
// edit, and sign off. playwright.config.ts moves the server's clock to 10:40,
// and the run starts at 10:42:00, so the timestamps match on every run.
//
// The story frames (pb-story-*) are 1032×900 with Details closed: the site
// zooms a 720×540 window of the channel pane, and each frame logs that
// window's top (`y`) for the site's crop. The rest are taken at 1440×900.
//
// Files are named pb-* so they sit beside the billing-story stills until the
// site switches over.
import { test, expect, Locator, Page } from "@playwright/test";
import { clickHeader, gotoLive } from "./helpers";
import { BRIEF, around, bottom, dismissFlash, park, prepare, shot, sidebarChannel, sql, waitUntilLocal, wanted } from "./site-helpers";

const enabled = process.env.SITE === "1" && process.env.CANOPY_SEED?.includes("seed-reports");
const timeline = (page: Page) => page.locator("#timeline");
const wide = { width: 1440, height: 900 };
// Story frames: the site zooms a 720×540 window of the channel pane (x 312–1032) at about 1:1.
const narrow = { width: 1032, height: 900 };
const zoomWindow = 540;

/**
 * A story frame at 1032×900, Details closed: scrolls `anchor` to `margin` px below
 * the top of its scroll area, shoots, and logs the zoom window's top as a fraction of
 * the frame (the site's `zoom: { ...pane, y }`). Warns when an element in `fit`
 * ends below the window.
 */
async function storyShot(page: Page, name: string, anchor: Locator, fit: Locator[], margin = 24) {
  if (!wanted(name)) return;
  await page.setViewportSize(narrow);
  await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
  await anchor.evaluate((el, margin) => {
    let p = el.parentElement;
    while (p && !(p.scrollHeight > p.clientHeight + 1 && /(auto|scroll)/.test(getComputedStyle(p).overflowY))) p = p.parentElement;
    const scroller = p ?? document.scrollingElement!;
    const top = p ? p.getBoundingClientRect().top : 0;
    scroller.scrollTop += el.getBoundingClientRect().top - (top + margin);
  }, margin);
  await park(page);
  await page.waitForTimeout(200);
  const a = (await anchor.boundingBox())!;
  const top = Math.min(Math.max(0, Math.round(a.y - margin)), narrow.height - zoomWindow);
  for (const f of fit) {
    const b = (await f.boundingBox())!;
    if (b.y + b.height > top + zoomWindow) console.warn(`${name}: ${Math.round(b.y + b.height - top - zoomWindow)}px below the window`);
  }
  console.log(`${name}: y ${(top / narrow.height).toFixed(3)} (window top ${top}px)`);
  await shot(page, name);
  await page.setViewportSize(wide);
}

/** A card with 20px of background either side and 8px above and below, so no neighbour shows. */
async function cardCrop(target: Locator) {
  const clip = await around(target, 20);
  const box = (await target.boundingBox())!;
  const y = Math.floor(box.y - 8);
  return { ...clip, y, height: Math.ceil(box.y + box.height + 8) - y };
}

const agentId = (page: Page, name: string) =>
  page
    .locator(`#sidebar a[href^="/agents/"]`, { hasText: `@${name}` })
    .first()
    .getAttribute("href")
    .then((href) => href!.split("/agents/")[1]);

/** Opens an agent's live card, if it is collapsed. */
async function openLive(page: Page, id: string) {
  const card = page.locator(`#telemetry-${id}`);
  await expect(card).toBeVisible({ timeout: 60_000 });
  if ((await card.getAttribute("data-open")) !== "true") await page.locator(`#telemetry-toggle-${id}`).click();
  return card;
}

/** Answers any permission card that shows up (a later edit, if "Always" did not stick). */
async function allowAny(page: Page) {
  const always = page.locator('[id^="permission-"][id$="-always"]').first();
  if (await always.isVisible()) await always.click();
}

test.describe("stills for canopy_site", () => {
  test.skip(!enabled, "set SITE=1 and CANOPY_SEED=e2e/bin/seed-reports.exs to capture");
  test.use({ viewport: wide, deviceScaleFactor: 2 });

  test("capture the Feature build story and the feature shots", async ({ page }) => {
    test.setTimeout(900_000);
    await prepare(page);

    // -- Bento: the Agents page, both engines ---------------------------------------------
    if (wanted("pb-agents", "pb-agents-bento")) {
      await gotoLive(page, "/agents");
      const roster = page.locator("section", { has: page.locator("#active-agents") }).first();
      await expect(roster).toContainText("opus");
      await park(page);
      await shot(page, "pb-agents", () => around(roster, 24));
      await page.locator("#agents-panel").evaluate((el: HTMLElement) => (el.style.width = "880px"));
      // Researcher (OpenCode) over Reviewer (Claude Code), the next row bleeding off the bottom.
      await shot(page, "pb-agents-bento", async () => {
        const researcher = page.locator('#active-agents li[id^="agent-"]', { hasText: "@researcher" });
        const row = (await researcher.boundingBox())!;
        const name = (await researcher.getByText("Researcher", { exact: true }).boundingBox())!;
        const engine = (await researcher.locator('[id^="engine-"]').boundingBox())!;
        const x = Math.floor(row.x - 12);
        const y = Math.floor(name.y - 4);
        return { x, y, width: Math.ceil(engine.x + engine.width) - x, height: 190 };
      });
      await page.locator("#agents-panel").evaluate((el: HTMLElement) => el.style.removeProperty("width"));
    }

    // -- Step 0: the Start page, filled in ------------------------------------------------
    await gotoLive(page, "/playbooks");
    await page.locator("#playbooks li", { hasText: "feature-build" }).locator("a[id^='start-playbook-']").click();
    await expect(page.locator("#start-preview")).toContainText("What will happen");
    await page.locator("#start-repository").selectOption({ label: "acme-reports" });
    await page.waitForTimeout(600);
    await page.locator("#start-coordinator").selectOption({ label: "@project-manager" });
    await page.waitForTimeout(600);
    await page.locator("#start-brief").fill(BRIEF);
    await page.locator("#start-channel-name").click();
    await page.locator("#start-channel-name").fill("csv-export");
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await expect(page.locator("#start-consequence")).toContainText("#csv-export");
    for (const role of ["designer", "frontend", "backend", "test", "reviewer"])
      await expect(page.locator(`#start-role-${role}-agent`)).toHaveValue(role);
    await park(page);
    await storyShot(page, "pb-story-00-start", page.locator('label[for="start-brief"]'), [page.locator("#start-role-test-agent")]);
    await shot(page, "pb-story-00-start-full");

    // The run starts at 10:42:00 on every run (playwright.config.ts starts the clock at 10:40).
    await waitUntilLocal(page, 10, 42);
    await page.locator("#start-playbook-submit").click();
    await expect(page).toHaveURL(/\/channels\/ch_/);
    const channelId = page.url().split("/channels/")[1];
    // A calm spend meter: $5.00 for the run (the Start page has no limit field).
    sql(`update channels set spend_limit = 5.0 where id = '${channelId}'`);
    await page.reload();
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
    await dismissFlash(page);
    const frontend = await agentId(page, "frontend");
    const backend = await agentId(page, "backend");
    const pm = await agentId(page, "project-manager");

    // -- Step 1: @designer's three options, as images ---------------------------------------
    const designs = timeline(page).locator('[id^="message-"]', { hasText: "Three designs for the CSV export" }).last();
    await expect(designs).toBeVisible({ timeout: 120_000 });
    for (const img of await designs.locator("img").all())
      await img.evaluate((el: HTMLImageElement) => el.complete || new Promise((r) => (el.onload = r)));

    // -- Step 2: the approval gate, Option B ---------------------------------------------------
    const gate = page.locator('section[id^="signoff-so_"]').first();
    await expect(gate).toContainText("Which design should we build?", { timeout: 60_000 });
    await bottom(page);
    await park(page);
    await designs.scrollIntoViewIfNeeded();
    await shot(page, "pb-story-01-designs");
    await gate.scrollIntoViewIfNeeded();
    await park(page);
    await shot(page, "pb-approval-card", () => cardCrop(gate));
    await storyShot(page, "pb-story-02-approval", gate, [gate]);
    await bottom(page);
    await gate.locator('[id$="-accept-1"]').click();
    await expect(gate).toBeHidden({ timeout: 30_000 });

    // -- Step 3: @frontend builds and delegates the endpoint to @backend -------------------------
    // Tech design and its review come first (quick turns); then @frontend's build turn.
    await expect(timeline(page)).toContainText("Implement, and write the test plan", { timeout: 180_000 });
    const card = await openLive(page, frontend);
    // @frontend holds its turn open (writing its memory) once the delegation line is up
    await expect(timeline(page)).toContainText("@frontend delegated to @backend", { timeout: 120_000 });
    await expect(card).toBeVisible();
    const delegated = timeline(page).locator('[id^="line-"]', { hasText: "@frontend delegated to @backend" }).last();
    await storyShot(page, "pb-story-03-build", delegated, [card]);
    await bottom(page);

    // -- Step 4: @backend's edit asks first -------------------------------------------------------
    const perm = page.locator('section[id^="permission-"]').first();
    await expect(perm).toContainText("export_csv", { timeout: 120_000 });
    await perm.scrollIntoViewIfNeeded();
    await park(page);
    await shot(page, "pb-story-04-permission-card", () => cardCrop(perm));
    await storyShot(page, "pb-story-04-permission", perm, [perm]);
    await page.locator('[id^="permission-"][id$="-always"]').first().click();
    await expect(perm).toBeHidden({ timeout: 30_000 });

    // -- Step 5: review sends Build back ------------------------------------------------------------
    await expect(timeline(page)).toContainText("Changes requested on Build", { timeout: 240_000 });
    await expect(timeline(page)).toContainText("Sent back to Build", { timeout: 120_000 });
    await allowAny(page);
    // The run panel beside the feed: Build open again, round 2.
    await page.locator("#playbook-chip").click();
    await expect(page.locator("#playbook-panel")).toBeVisible();
    await expect(page.locator("#playbook-step-build")).toContainText("round 2");
    const review = timeline(page).locator('[id^="message-"]', { hasText: "Changes requested on Build" }).last();
    await review.evaluate((el) => el.scrollIntoView({ block: "start" }));
    await park(page);
    await shot(page, "pb-run-panel", () => around(page.locator("#details-panel"), 0));
    await page.locator("#toggle-details").click();
    await expect(page.locator("#details-panel")).toBeHidden();
    // From the review that sent it back down to the fix's delegation line, Details closed.
    const fix = timeline(page).locator('[id^="line-"]', { hasText: "Sent back from verify" }).last();
    await expect(fix).toBeVisible({ timeout: 60_000 });
    await storyShot(page, "pb-story-05-sendback", review, [fix]);
    await bottom(page);

    // -- Step 6: @test attaches test-report.md --------------------------------------------------------
    const report = timeline(page).locator('[id^="message-"]', { hasText: "Report attached" }).last();
    await expect(report).toBeVisible({ timeout: 240_000 });
    await expect(report).toContainText("test-report.md");
    await bottom(page);
    await park(page);
    await shot(page, "pb-story-06-report");
    await report.scrollIntoViewIfNeeded();
    await park(page);
    await shot(page, "pb-documents", () => cardCrop(report));

    // -- Step 7: the User sign-off card, and Changes · 5 files -------------------------------------------
    const signoff = page.locator('section[id^="signoff-so_"]', { hasText: "Accept the CSV export" }).first();
    await expect(signoff).toBeVisible({ timeout: 180_000 });
    await bottom(page);
    await park(page);
    await shot(page, "pb-story-07-signoff-card", () => cardCrop(signoff));
    // The summary is on the card itself, so the card is the anchor.
    await storyShot(page, "pb-story-07-signoff", signoff, [signoff]);
    await bottom(page);
    await clickHeader(page, "open-changes");
    await expect(page.locator("#changes-modal")).toBeVisible();
    await expect(page.locator("#changed-files li")).toHaveCount(5);
    await page.locator('[id^="changed-file-"]', { hasText: "reports.py" }).first().click();
    await expect(page.locator("#file-diff")).toContainText("export_csv");
    await park(page);
    await shot(page, "pb-story-07-changes");
    await shot(page, "pb-story-07-changes-modal", () => around(page.locator("#changes-dialog"), 0));
    await page.locator("#close-changes").click();

    // Sign off: accepting the last step completes the run; the coordinator closes the task.
    await signoff.locator('[id$="-accept"]').click();
    await expect(timeline(page)).toContainText("the feature-build playbook is complete", { timeout: 60_000 });
    await expect(page.locator(`#telemetry-${backend}`)).toBeHidden({ timeout: 60_000 });
    await expect(page.locator(`#telemetry-${pm}`)).toBeHidden({ timeout: 60_000 });
    const closing = timeline(page).locator('[id^="message-"]', { hasText: "Signed off; the run is complete" }).last();
    await expect(closing).toBeVisible({ timeout: 60_000 });
    // The accepted card stays in place, collapsed to "You accepted @project-manager's User sign-off".
    const accepted = timeline(page).locator('[id^="signoff-resolved-"]', { hasText: "User sign-off" }).last();
    await expect(accepted).toBeVisible({ timeout: 30_000 });
    const complete = timeline(page).locator('[id^="line-"]', { hasText: "the feature-build playbook is complete" }).last();
    await storyShot(page, "pb-story-08-done", accepted, [complete, closing]);
    await bottom(page);

    // -- Bento: the spend meter, calm --------------------------------------------------------------------
    const spend = page.locator("#edit-budget");
    console.log(`spend: ${await spend.innerText()}`);
    await shot(page, "pb-spend", () => around(page.locator("#channel-header"), 0));

    // -- Bento: @frontend remembered the DataTable --------------------------------------------------------
    await gotoLive(page, `/agents/${frontend}`);
    const memory = page.locator("section", { has: page.locator("#agent-memory") }).first();
    await expect(memory).toContainText("Reports use the shared DataTable component");
    await park(page);
    await shot(page, "pb-memory-panel", () => around(memory, 24));

    // -- Bento: what the run cost, by agent --------------------------------------------------------------
    await gotoLive(page, "/costs");
    const byAgent = page.locator("#by-agent");
    await expect(byAgent).toContainText("@frontend");
    console.log(`costs by agent:\n${await byAgent.innerText()}`);
    await byAgent.scrollIntoViewIfNeeded();
    await park(page);
    await shot(page, "pb-costs-by-agent", () => around(byAgent, 24));

    // -- Bento: #dashboard-load-time's schedules (a CI watch) and its thread --------------------------
    await gotoLive(page, "/");
    await sidebarChannel(page, "dashboard-load-time").click();
    await expect(timeline(page)).toContainText("/api/teams/members");
    await clickHeader(page, "edit-schedules");
    const schedules = page.locator("#schedules-panel");
    await expect(schedules).toContainText("failed CI");
    await schedules.scrollIntoViewIfNeeded();
    await park(page);
    // from the "Scheduled · 2 active" header down
    const scheduledHeader = (await page.locator("#schedule-count").boundingBox())!;
    await shot(page, "pb-schedules-watch", async () => {
      const clip = await around(schedules, 16);
      const y = Math.floor(scheduledHeader.y - 14);
      return { ...clip, y, height: clip.y + clip.height - y };
    });
    await clickHeader(page, "edit-schedules");
    await page.locator('[id^="thread-summary-"]').first().click();
    const thread = page.locator("#thread-panel");
    await expect(thread).toContainText("last_active_at");
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await park(page);
    // the header and the conversation, not the empty space and the reply box below it
    const lastReply = (await thread.locator("#thread-replies > *").last().boundingBox())!;
    await shot(page, "pb-thread", async () => {
      const clip = await around(thread, 0);
      return { ...clip, height: Math.ceil(lastReply.y + lastReply.height + 28) - clip.y };
    });
  });
});
