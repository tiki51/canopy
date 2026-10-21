// Captures the screenshots for docs/user-guide.md against the seeded "Acme"
// workspace, in light and dark mode. Only runs when USER_GUIDE=1:
//
//   USER_GUIDE=1 CANOPY_SEED=e2e/bin/seed-acme.exs FAKE_TURN_DELAY_MS=2500 npx playwright test user-guide
//
// Everything already on screen comes from e2e/bin/seed-acme.exs; the live
// interactions (an agent working, a permission card, a delegation, a
// playbook run) run against the fake OpenCode, whose #refund-webhooks and
// #checkout-cache stories are scripted to read like real work.
import { test, expect, Locator, Page } from "@playwright/test";
import os from "node:os";
import path from "node:path";
import { send, timeline, clickHeader, openDetails } from "./helpers";
import { db, iso, sql } from "./site-helpers";
import { stubNotifications, turnOn } from "./notify-helpers";

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

/**
 * One screenshot per theme: <name>-light.png and <name>-dark.png. `before`
 * runs ahead of each, for state the theme switch could move (a scroll).
 */
async function shot(page: Page, name: string, opts: Record<string, unknown> = {}, before?: () => Promise<unknown>) {
  for (const t of ["light", "dark"] as const) {
    await theme(page, t);
    await page.waitForTimeout(200);
    if (before) await before();
    await page.screenshot({ path: `${dir}/${name}-${t}.png`, animations: "disabled", ...opts });
  }
  await theme(page, "light");
}

/**
 * Rewrites this machine's paths on the page as a user's would read: the
 * capture's repositories live under canopy/tmp in the developer's home.
 */
async function scrubPaths(page: Page) {
  const home = os.homedir();
  const tmp = path.resolve("../tmp") + "/";
  // the fake Codex and Claude Code server.sh puts first on PATH read as Homebrew installs
  const fakeCodex = path.resolve("fake-codex/codex");
  const fakeClaude = path.resolve("fake-claude/claude");
  const pairs: [string, string][] = [
    [fakeCodex, "/opt/homebrew/bin/codex"],
    [fakeCodex.replace(home, "~"), "/opt/homebrew/bin/codex"],
    [fakeClaude, "/opt/homebrew/bin/claude"],
    [fakeClaude.replace(home, "~"), "/opt/homebrew/bin/claude"],
    [tmp, "/Users/priya/code/"],
    [tmp.replace(home, "~"), "~/code/"],
    [home, "/Users/priya"],
  ];
  await page.evaluate((pairs) => {
    const fix = (s: string) => pairs.reduce((acc, [from, to]) => acc.split(from).join(to), s);
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) if (n.nodeValue) n.nodeValue = fix(n.nodeValue);
    for (const el of document.querySelectorAll<HTMLInputElement>("input, textarea")) {
      if (el.placeholder) el.placeholder = fix(el.placeholder);
      if (el.value) el.value = fix(el.value);
    }
    for (const el of document.querySelectorAll("[title]")) el.setAttribute("title", fix(el.getAttribute("title")!));
  }, pairs);
}

const bottomOfFeed = (page: Page) => page.locator("#timeline-scroll").evaluate((el) => (el.scrollTop = el.scrollHeight));

/** A shot clipped to one element, with a margin around it. */
async function shotOf(page: Page, name: string, el: Locator, margin = 16, before?: () => Promise<void>) {
  await el.scrollIntoViewIfNeeded();
  const box = (await el.boundingBox())!;
  const x = Math.max(0, box.x - margin);
  const y = Math.max(0, box.y - margin);
  await shot(page, name, { clip: { x, y, width: box.width + 2 * margin, height: box.height + 2 * margin } }, before);
}

/** The experimental "Mentioning a working agent interrupts it" setting. */
async function setInterrupt(page: Page, on: boolean) {
  await page.goto("/settings");
  const box = page.locator("#chatter-form input[type=checkbox][name='setting[interrupt_on_mention]']");
  if (on) await box.check();
  else await box.uncheck();
  await page.locator("#save-chatter").click();
  await expect(page.locator("#flash-info")).toBeVisible();
  await dismissFlash(page);
}

// A playbook for the library, the editor and the run. The fake OpenCode
// coordinator (e2e/fake-opencode.mjs) advances it to the sign-off on its own.
const playbook = `---
name: release-check
description: Plan, build and sign off a small change behind a flag.
roles:
  dev: backend
stall_after: off
steps:
  - id: plan
    title: Plan
    owner: coordinator
  - id: build
    title: Build
    owner: dev
  - id: sign-off
    title: Sign-off
    owner: coordinator
    approval: user
---

Keep the change behind a feature flag and post what changed at each step.

## plan

List the files to change and the test that proves it.

Done when: the plan names every file and its test.

## build

Make the change and run the tests.

Done when: the tests pass with the flag on and off.

## sign-off

Summarise the change and ask Priya to approve it.
`;

const sidebarChannel = (page: Page, name: string) =>
  page.locator('#sidebar a[id^="sidebar-channel-"]', { hasText: name }).first();

const sidebarDm = (page: Page, name: string) =>
  page.locator("#sidebar-dms a", { hasText: name }).first();

const sidebarProject = (page: Page, repo: string) =>
  page.locator("#sidebar-projects > [data-repo-id]", { hasText: repo }).first();

const sidebarSection = (page: Page, name: string) => page.locator(`ul[data-section-name="${name}"]`);

/** A channel's id, from its sidebar link. */
const channelIdOf = async (page: Page, name: string) =>
  (await sidebarChannel(page, name).getAttribute("id"))!.replace("sidebar-channel-", "");

/** A section from the repository's + in the sidebar; returns its id. */
async function newSection(page: Page, repo: string, name: string): Promise<string> {
  const project = sidebarProject(page, repo);
  await project.locator(".group\\/proj").first().hover();
  await project.locator("[data-new-section]").click();
  const input = project.locator('[data-section-editor="create"] input');
  await expect(input).toBeFocused();
  await input.fill(name);
  await input.press("Enter");
  await expect(sidebarSection(page, name)).toBeAttached();
  await expect(input).toBeHidden();
  return (await sidebarSection(page, name).getAttribute("data-section-id"))!;
}

/** The channel row's ⋯ › Move to section, the submenu open. */
async function openMoveMenu(page: Page, channel: string) {
  const id = await channelIdOf(page, channel);
  await page.locator(`#sidebar-row-${id}`).hover();
  await page.locator(`#sidebar-row-menu-${id}`).click();
  await expect(page.locator("#sidebar-menu")).toBeVisible();
  await page.locator("#sidebar-menu").getByRole("menuitem", { name: "Move to section" }).click();
  await expect(page.locator("#sidebar-submenu")).toBeVisible();
}

async function fileIn(page: Page, channel: string, section: string) {
  await openMoveMenu(page, channel);
  await page.locator("#sidebar-submenu").getByRole("menuitemradio", { name: section, exact: true }).click();
  await expect(sidebarSection(page, section).locator(`#sidebar-row-${await channelIdOf(page, channel)}`)).toBeAttached();
}

/** Waits for the CSS transitions and animations inside `el` to finish. */
const settled = (el: Locator) =>
  expect.poll(() => el.evaluate((node) => node.getAnimations({ subtree: true }).length)).toBe(0);

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
  // a click on a selector that has gone fails in seconds, not at the end of the long test
  test.use({ viewport: { width: 1440, height: 900 }, actionTimeout: 30_000 });

  test("capture every screen", async ({ page }) => {
    test.setTimeout(480_000);

    // -- Sidebar sections, first, so every later shot has them ---------------------
    // Payments and Invoicing in acme-billing, Design in acme-storefront
    await page.goto("/");
    await sidebarChannel(page, "payment-retries").click();
    await expect(page.locator("#channel-name")).toContainText("payment-retries");
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
    await newSection(page, "acme-billing", "Payments");
    const invoicing = await newSection(page, "acme-billing", "Invoicing");
    await newSection(page, "acme-storefront", "Design");
    await fileIn(page, "payment-retries", "Payments");
    await fileIn(page, "invoice-pdf-export", "Invoicing");
    await fileIn(page, "brand-logo", "Design");
    await page.keyboard.press("Escape");

    // -- Settings, with the billing hold the seed engaged ---------------------
    await page.goto("/settings");
    await expect(page.locator("#engine-pause-opencode")).toContainText("insufficient balance");
    await expect(sidebarSection(page, "Payments")).toBeAttached();
    await page.mouse.move(700, 600);
    await shot(page, "hold-banner", { clip: { x: 0, y: 0, width: 1440, height: 300 } });
    await page.locator("#resume-engine-opencode").click();
    await expect(page.locator("#engine-pause-opencode")).toBeHidden();
    await dismissFlash(page);

    // Invoicing collapsed (its channel unread, so the dot), and the
    // payment-retries row's ⋯ › Move to section open
    await sidebarChannel(page, "payment-retries").click();
    await expect(page.locator("#channel-name")).toContainText("payment-retries");
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
    await page.locator(`#sidebar-section-toggle-${invoicing}`).click();
    await expect(page.locator(`#sidebar-section-toggle-${invoicing}`)).toHaveAttribute("aria-expanded", "false");
    await expect(page.locator(`#sidebar-section-count-${invoicing}`)).toHaveText("1");
    await expect.soft(page.locator(`#sidebar-section-dot-${invoicing}`)).toBeVisible();
    await openMoveMenu(page, "payment-retries");
    const submenu = (await page.locator("#sidebar-submenu").boundingBox())!;
    await shot(page, "sidebar-sections", { clip: { x: 0, y: 0, width: Math.ceil(submenu.x + submenu.width + 24), height: 900 } });
    await page.keyboard.press("Escape");
    await page.keyboard.press("Escape");
    await expect(page.locator("#sidebar-menu")).toBeHidden();
    // open again: the later shots go to invoice-pdf-export from the sidebar
    await page.locator(`#sidebar-section-toggle-${invoicing}`).click();
    await expect(page.locator(`#sidebar-section-toggle-${invoicing}`)).toHaveAttribute("aria-expanded", "true");
    await page.goto("/settings");
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();

    await page.locator("#check-connection").click();
    // the version playwright.config gives the fake OpenCode for this capture
    await expect(page.locator("#health-result")).toContainText("1.18.11");
    // Codex isn't checked on mount (too slow): Check Codex turns its card Ready
    await page.locator("#check-codex").click();
    await expect(page.locator("#codex-check-result")).toContainText("signed in");
    await expect(page.locator("#default-engine-choice-codex")).toHaveAttribute("data-ready", "ready");
    // and Check Claude Code, so all three cards read Ready, not Claude Code alone Installed
    await page.locator("#check-claude").click();
    await expect(page.locator("#claude-check-result")).toContainText("logged in");
    await expect(page.locator("#default-engine-choice-claude_code")).toHaveAttribute("data-ready", "ready");
    await page.locator("#engine-panel").evaluate((el) => {
      let box = el.parentElement!;
      while (box.scrollHeight <= box.clientHeight) box = box.parentElement!;
      box.scrollTop = 0;
    });
    await shot(page, "settings", {}, () => scrubPaths(page));

    // the Codex panel alone, its models loaded from the fake
    await expect(page.locator("#codex-default-model")).toBeEnabled();
    await shotOf(page, "settings-codex", page.locator("#codex-panel"), 12, () => scrubPaths(page));

    // from the You panel above it, whole, so no label is cut at the top edge
    await page.locator("#profile-panel").evaluate((el) => {
      let box = el.parentElement!;
      while (box.scrollHeight <= box.clientHeight) box = box.parentElement!;
      box.scrollTop += el.getBoundingClientRect().top - box.getBoundingClientRect().top - 24;
    });
    await page.waitForTimeout(200);
    await shot(page, "settings-appearance", { clip: { x: 312, y: 0, width: 1128, height: 900 } });

    await page.locator("#mcp-panel").scrollIntoViewIfNeeded();
    await shot(page, "settings-mcp", {}, () => scrubPaths(page));

    // -- Repositories --------------------------------------------------------
    await page.goto("/repositories");
    await expect(page.locator("#repositories")).toContainText("acme-billing");
    // scrubbed right before each theme: the page re-renders after it loads
    await shot(page, "repositories", {}, () => scrubPaths(page));

    // a repository's MCP servers, both engines' sections open
    await page.locator("#repositories li", { hasText: "acme-billing" }).locator("[id^=repository-mcp-]").click();
    await expect(page.locator("#repository-mcp-panel")).toBeVisible();
    for (const engine of ["opencode", "claude_code"]) {
      if (!(await page.locator(`#mcp-servers-${engine}`).isVisible())) await page.locator(`#mcp-engine-${engine}-toggle`).click();
      await expect(page.locator(`#mcp-servers-${engine}`)).toBeVisible();
    }
    await expect(page.locator("#mcp-server-opencode-github")).toBeVisible();
    await shot(page, "repository-mcp", {}, () => scrubPaths(page));

    // -- Agents --------------------------------------------------------------
    await page.goto("/agents");
    await expect(page.locator("#active-agents")).toContainText("@backend");
    await shot(page, "agents");

    await page.locator("#agents-teams").click();
    await expect(page).toHaveURL(/\/teams$/);
    const teams = page.locator('[id^="team-tm_"]');
    await expect(teams.filter({ hasText: "@bugfix-team" })).toBeVisible();
    // just below the last team, above the sidebar's next repository
    const lastTeam = (await teams.last().boundingBox())!;
    await shot(page, "teams", { clip: { x: 0, y: 0, width: 1440, height: Math.ceil(lastTeam.y + lastTeam.height + 21) } });

    // the gallery, then the bug-fix bundle's import preview (not applied): a
    // new agent, agents and a team that differ from Acme's, and the playbook;
    // the first agent that differs is imported under a new name, its changes open
    await page.goto("/agents/gallery");
    await expect(page.locator("#gallery-add-security-reviewer")).toBeVisible();
    await shot(page, "agent-gallery");
    await page.locator("#gallery-add-bundle-bug-fix").click();
    await expect(page).toHaveURL(/\/agents\/import/);
    const differs = page
      .locator('li[id^="import-item-"][data-status="conflict"]')
      .filter({ has: page.locator('[id$="-rename"]') })
      .filter({ has: page.locator('details[id$="-changes"]') })
      .first();
    await expect(differs).toBeVisible();
    const item = (await differs.getAttribute("id"))!;
    await page.locator(`#${item}-rename`).check();
    await expect(page.locator(`#${item}-name`)).toBeEnabled();
    await page.locator(`#${item}-changes summary`).click();
    await expect(page.locator(`#${item}-changes`)).toHaveAttribute("open", "");
    await shot(page, "agent-import", { fullPage: true });

    // -- Playbooks: the builder with release-check in it, then the library --------
    // a blank playbook saved once, then the whole file pasted through Edit file text
    await page.goto("/playbooks/new/blank");
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
    await page.locator("#about-title").fill("release-check");
    await page.locator("#about-description").fill("Plan, build and sign off a small change behind a flag.");
    await page.locator("#step-s1-title").fill("Plan");
    await page.locator("#add-owner-s1").click();
    await page.locator("#owner-agent-backend").click();
    await expect(page.locator("#save-playbook")).toBeEnabled();
    await page.locator("#save-playbook").click();
    await expect(page).toHaveURL(/\/playbooks\/pb_[^/]+\/edit$/);
    await dismissFlash(page);
    await page.locator("#builder-menu-toggle").click();
    await page.locator("#builder-edit-text").click();
    await page.locator("#canopy-confirm-ok").click();
    await page.locator("#playbook-body").fill(playbook);
    await page.locator("#save-playbook-text").click();
    await expect(page.locator("#playbook-text-panel")).toHaveCount(0);
    await expect(page.locator("#builder-step-list > li")).toHaveCount(3);
    await expect(page.locator("#save-state")).toContainText("Saved");
    await dismissFlash(page);
    await page.mouse.move(5, 5);
    await shot(page, "playbook-builder");
    await page.goto("/playbooks");
    await expect(page.locator("#playbooks li[data-playbook='release-check']")).toBeVisible();
    await expect(page.locator("#playbooks li[data-playbook='bug-fix']")).toContainText("Bug fix");
    await dismissFlash(page);
    // bug-fix starred, so Starred sits above Other playbooks
    await page.locator("li[data-playbook='bug-fix'] [id^='star-playbook-']").click();
    await expect(page.locator("#playbooks-starred li[data-playbook='bug-fix']")).toBeVisible();
    await expect(page.locator("#playbooks-other-heading")).toBeVisible();
    await dismissFlash(page);
    await page.mouse.move(5, 5);
    await settled(page.locator("#playbooks-starred"));
    await shot(page, "playbooks", { clip: { x: 312, y: 0, width: 1128, height: 360 } });

    // release-check's Start page: a new channel in acme-billing, filed in
    // Payments, with a brief (not started)
    await page.locator("li[data-playbook='release-check'] a[id^='start-playbook-']").click();
    await expect(page.locator("#start-preview")).toContainText("What will happen");
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
    await page.locator("#start-repository").selectOption({ label: "acme-billing" });
    await page.locator("#start-section").selectOption({ label: "Payments" });
    await page.locator("#start-brief").fill("Retry refunds on timeout");
    await page.locator("#start-upload-form input[type=file]").setInputFiles({
      name: "refund-timeouts.md",
      mimeType: "text/markdown",
      buffer: Buffer.from("# Refund timeouts\n\nSeven refunds stuck pending last week, all after a gateway timeout.\n"),
    });
    await expect(page.locator("#start-brief-files")).toContainText("refund-timeouts.md");
    await expect(page.locator("#start-brief-count")).toContainText("1 of 10 files");
    await expect(page.locator("#start-channel-name")).toHaveValue(/^release-check/);
    await expect(page.locator("#start-section")).toHaveValue("Payments");
    await page.locator("#start-coordinator").selectOption({ label: "@backend" });
    await expect(page.locator("#start-consequence")).toContainText("@backend is woken");
    await expect(page.locator("#start-consequence")).toContainText("#release-check");
    await page.mouse.move(5, 5);
    await shot(page, "playbook-start");

    // two global permissions on @backend, as Allow globally leaves them
    const ago = (days: number) => iso(new Date(Date.now() - days * 86_400_000));
    sql(`INSERT INTO global_permissions (id, agent_id, tool, label, channel_id, granted_at, use_count, last_used_at, inserted_at, updated_at)
      SELECT 'gp_guide_' || g.tool, a.id, g.tool, g.label, c.id, g.at, g.uses, g.used, g.at, g.at
      FROM agents a, channels c,
        (SELECT 'bash' AS tool, 'Bash' AS label, '${ago(6)}' AS at, 23 AS uses, '${ago(0.1)}' AS used
         UNION ALL SELECT 'webfetch', 'WebFetch', '${ago(2)}', 4, '${ago(1)}') g
      WHERE a.name = 'backend' AND c.name = 'payment-retries'`);

    await page.goto("/agents");
    await expect(page.locator("#active-agents")).toContainText("@backend");

    await page.locator('#active-agents a[href^="/agents/"]', { hasText: "backend" }).first().click();
    await expect(page.locator("#agent-page")).toBeVisible();
    await expect(page.locator("#agent-memory")).toContainText("small PRs");
    await expect(page.locator("#agent-grants li")).toHaveCount(2);
    // a taller window when needed, so the page reaches the Global permissions panel
    const grants = (await page.locator("#agent-global-permissions").boundingBox())!;
    await page.setViewportSize({ width: 1440, height: Math.max(900, Math.ceil(grants.y + grants.height + 32)) });
    await shot(page, "agent-page");
    await page.setViewportSize({ width: 1440, height: 900 });

    await page.locator('[id^="edit-agent-"]').click();
    await expect(page.locator("#agent-form")).toBeVisible();
    await shot(page, "agent-edit");

    // the Codex fields, switched to in the form and not saved
    await page.locator("#agent-engine-select").selectOption("codex");
    await expect(page.locator("#codex-model")).toBeEnabled();
    await expect(page.locator("#codex-permissions-help")).toBeVisible();
    await page.locator("#agent-engine-select").scrollIntoViewIfNeeded();
    await shot(page, "agent-edit-codex");
    await page.locator("#agent-engine-select").selectOption("claude_code");
    await expect(page.locator("#claude-model")).toBeVisible();

    // model routing (experimental) switched on in the form, not saved
    const routing = page.locator("#agent-routing-fields");
    await page.locator("#agent-routing-enabled").check();
    await page.locator("#claude-light-model").selectOption("haiku");
    await expect(routing).toContainText("experimental");
    await shotOf(page, "agent-routing", routing, 12);

    // -- The seeded conversation ------------------------------------------------
    await sidebarChannel(page, "payment-retries").click();
    await expect(page.locator("#channel-name")).toContainText("payment-retries");
    await expect(timeline(page)).toContainText("Approving with two small notes");
    await shot(page, "channel");

    // reactions: the approval's two chips and the open picker
    const approval = timeline(page).locator("article", { hasText: "Approving with two small notes" }).first();
    await approval.hover();
    await approval.locator('[id^="react-msg_"]').click();
    const picker = approval.locator('[id^="react-picker-"][role="menu"]');
    await expect(picker).toBeVisible();
    const box = (await approval.boundingBox())!;
    const pickerBox = (await picker.boundingBox())!;
    // the article's own padding is the margin; any more shows the next row
    const bottom = Math.max(box.y + box.height, pickerBox.y + pickerBox.height + 12);
    await shot(page, "reactions", { clip: { x: box.x, y: box.y, width: box.width, height: Math.ceil(bottom - box.y) } });
    await page.mouse.click(5, 5);

    // the start of the conversation: root cause with a code block, delegation
    await page.locator("#timeline-scroll").evaluate((el) => (el.scrollTop = 0));
    await page.waitForTimeout(300);
    await shot(page, "channel-conversation");
    await page.locator("#timeline-scroll").evaluate((el) => (el.scrollTop = el.scrollHeight));

    // Activity on, with the last turn's card open
    await clickHeader(page, "toggle-activity");
    await expect(timeline(page)).toContainText(/finished/);
    // the toggle lives in Details; close it so the feed has the width
    if (await page.locator("#details-panel").isVisible()) await page.locator("#toggle-details").click();
    await expect(page.locator("#details-panel")).toBeHidden();
    // the reviewer's review turn, not the pass that follows it
    const last = timeline(page).locator('section[id^="turn-"]', { hasText: "@reviewer finished" }).last();
    await last.locator('[id^="turn-toggle-"]').click();
    await last.scrollIntoViewIfNeeded();
    await shot(page, "channel-activity");
    await clickHeader(page, "toggle-activity");

    // the Details panel: the whole of it, then each part that opens in place
    await openDetails(page);
    await shot(page, "channel-details");

    // the task, with a description typed in (not saved)
    await clickHeader(page, "edit-task");
    await expect(page.locator("#task-panel")).toBeVisible();
    await page
      .locator("#task-form textarea")
      .fill("Two retry paths can both call enqueue_charge. Make it idempotent with claim_charge and add a concurrency test.");
    await shot(page, "task-panel", { clip: await detailsClip(page) });
    await page.locator("#task-form button", { hasText: "Cancel" }).click();
    await expect(page.locator("#task-panel")).toBeHidden();

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
    // from Priya's last post down, so the clip starts on a whole row
    const lastPost = (await timeline(page).locator("article", { hasText: "Great work all" }).last().boundingBox())!;
    const top = Math.floor(lastPost.y - 8);
    await shot(page, "composer-autocomplete", { clip: { x: 312, y: top, width: 1128, height: 900 - top } });
    await page.locator("#composer-input").fill("");

    // attachments: the ticket screenshot on Priya's first post and the
    // researcher's shared write-up, then the library picker
    const image = page.locator('[id^="attachment-"][data-kind="image"] img').first();
    await image.evaluate((el: HTMLImageElement) => el.complete || new Promise((r) => (el.onload = r)));
    await page.locator("article", { has: image }).first().scrollIntoViewIfNeeded();
    await page.waitForTimeout(300);
    await shot(page, "attachments");
    await bottomOfFeed(page);
    await page.locator("#composer-library").click();
    await expect(page.locator("#library-documents")).toContainText("enqueue-paths.md");
    // the feed behind the picker at its end in both themes
    await shot(page, "library-picker", {}, async () => {
      await bottomOfFeed(page);
      await page.waitForTimeout(200);
    });
    await page.locator("#close-library").click();

    // the command palette over the channel
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
    await page.keyboard.press("ControlOrMeta+k");
    await expect(page.locator("#cmdk-dialog")).toBeVisible();
    await expect(page.locator("#cmdk-list [role=option]").first()).toBeVisible();
    await shot(page, "command-palette");
    await page.keyboard.press("Escape");
    await expect(page.locator("#cmdk-dialog")).toBeHidden();

    // -- A channel over its spend limit -------------------------------------------
    await sidebarChannel(page, "invoice-pdf-export").click();
    await expect(page.locator("#limit-bar")).toBeVisible();
    await shot(page, "spend-limit-reached");

    // -- A thread and a schedule in the other repository -------------------------
    await sidebarChannel(page, "checkout-latency").click();
    await expect(timeline(page)).toContainText("priceCart");
    await openThread(page);
    await shot(page, "channel-thread");
    await page.locator("#thread-panel-close").click();
    // opening it read the seed's new replies; mark them unread again for the
    // Threads inbox, captured later with an agent at work in a thread
    sql(`UPDATE thread_reads SET last_read_at = '${iso(new Date(Date.now() - 3 * 86_400_000))}'`);

    // -- Asking for feedback on an image: from Priya's request down -----------------
    await sidebarChannel(page, "brand-logo").click();
    const logo = page.locator('[id^="attachment-"][data-kind="image"] img').first();
    await logo.evaluate((el: HTMLImageElement) => el.complete || new Promise((r) => (el.onload = r)));
    await page.locator("article", { has: logo }).first().evaluate((el) => el.scrollIntoView({ block: "start" }));
    await page.waitForTimeout(300);
    await shot(page, "image-feedback");

    // -- Archived: #checkout-latency from its row's archive button, Undo up -----------
    // (an open channel stays put when archived, so archive one that isn't)
    const latency = await channelIdOf(page, "checkout-latency");
    await page.locator(`#sidebar-row-${latency}`).hover();
    await page.locator(`#sidebar-archive-${latency}`).click();
    await expect(page.locator("#sidebar-undo-toast")).toContainText(/Archived\s*#checkout-latency/);
    await expect(sidebarProject(page, "acme-storefront").locator('details[id^="sidebar-archived-"] summary')).toContainText("1 archived");
    // hovering the toast holds it for both themes
    await page.locator("#sidebar-undo-toast > *").first().hover({ position: { x: 8, y: 8 } });
    // the feed scrolls to its end after the archive, so back to the top per theme
    await shot(page, "archived-channel", {}, async () => {
      await page.locator("#timeline-scroll").evaluate((el) => (el.scrollTop = 0));
      await page.waitForTimeout(300);
    });
    await page.locator("#sidebar-undo-archive").click();
    await expect(sidebarProject(page, "acme-storefront").locator(`#sidebar-row-${latency}`)).toBeAttached();
    await expect(sidebarProject(page, "acme-storefront").locator('details[id^="sidebar-archived-"]')).toHaveCount(0);

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

    // -- Search -----------------------------------------------------------------------
    await page.goto("/search?q=charge");
    await expect(page.locator('#search-results a[id^="result-"]').first()).toBeVisible();
    await shot(page, "search");

    // -- Costs ----------------------------------------------------------------------
    await page.setViewportSize({ width: 1440, height: 1780 });
    await page.goto("/costs");
    await expect(page.locator("#budgets")).toContainText("invoice-pdf-export");
    await expect(page.locator("#request-audit")).toContainText("@finops");
    // By engine shares the Last 14 days row
    await expect(page.locator("#by-engine")).toBeVisible();
    // down to the end of the By agent / channel / model / trigger row
    let breakdown = 0;
    for (const id of ["by-agent", "by-channel", "by-model", "by-trigger"]) {
      const b = (await page.locator(`#${id}`).boundingBox())!;
      breakdown = Math.max(breakdown, b.y + b.height);
    }
    await shot(page, "costs", { clip: { x: 0, y: 0, width: 1440, height: Math.ceil(breakdown + 2) } });
    await page.setViewportSize({ width: 1440, height: 900 });

    // -- Live: a new channel and an agent at work (fake OpenCode) --------------------
    // @test owns it: the seed puts @backend and @reviewer on the fake Claude
    // Code, which has no permission story for this channel.
    await page.goto("/channels/new");
    await page.getByLabel("Repository").selectOption({ label: "acme-billing" });
    await page.getByLabel("Name (slug, shown as #name)").fill("refund-webhooks");
    await page.getByLabel("Topic").fill("Refund webhooks fail silently when the gateway times out");
    await page.getByLabel(/Spend limit/).fill("2");
    const owner = page.getByLabel("Initial owner");
    await owner.selectOption((await owner.locator("option", { hasText: "@test" }).first().getAttribute("value"))!);
    await page.locator("#channel-section-row select").selectOption({ label: "Payments" });
    await expect(page.locator("#channel-section-row select")).toHaveValue("Payments");
    // from the top of the form, nothing focused (filling the spend limit scrolled it)
    await page.evaluate(() => {
      (document.activeElement as HTMLElement | null)?.blur();
      window.scrollTo(0, 0);
      for (const el of document.querySelectorAll("*")) if (el.scrollTop > 0) el.scrollTop = 0;
    });
    // a taller window for this one, so the form ends on its Create button
    const create = (await page.locator("#create-channel").boundingBox())!;
    await page.setViewportSize({ width: 1440, height: Math.max(900, Math.ceil(create.y + create.height + 32)) });
    await shot(page, "new-channel");
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.locator("#create-channel").click();
    await expect(page).toHaveURL(/\/channels\/ch_/);
    await dismissFlash(page);
    await shot(page, "channel-empty");

    // the story is scripted in the fake OpenCode (refundTurn)
    const idle = () => expect(page.locator('section[id^="telemetry-"]')).toHaveCount(0, { timeout: 60_000 });
    await send(page, "Refund webhooks fail silently when the gateway times out. Read webhooks.py and post a plan before changing anything.");
    const card = page.locator('[id^="telemetry-"]').first();
    await expect(card).toContainText(/is (researching|thinking|building|working)/);
    await expect(card).toContainText("webhooks.py");
    await card.scrollIntoViewIfNeeded();
    await shot(page, "agent-working");

    await expect(timeline(page)).toContainText("I'll wait for a go-ahead", { timeout: 30_000 });
    await expect(card).toBeHidden();
    await shot(page, "agent-replied");

    await send(page, "Go ahead and add the timeout handling to webhooks.py.");
    const perm = page.locator('[id^="permission-"]').first();
    await expect(perm).toContainText("webhooks.py", { timeout: 30_000 });
    await expect(page.locator('[id^="permission-"][id$="-global"]').first()).toBeVisible();
    // 30px taller, so Priya's name clears the header with the card whole
    await page.setViewportSize({ width: 1440, height: 930 });
    await bottomOfFeed(page);
    await page.waitForTimeout(200);
    await shot(page, "permission-card");
    await page.setViewportSize({ width: 1440, height: 900 });
    // Allow globally: @test's next edit, after the delegation, goes through without a card
    await page.locator('[id^="permission-"][id$="-global"]').first().click();
    await expect(perm).toBeHidden({ timeout: 30_000 });
    await expect(timeline(page)).toContainText("Added the timeout", { timeout: 30_000 });
    await idle();

    await send(page, "/delegate @researcher list every webhook handler that can reach the refund endpoint");
    await expect(timeline(page)).toContainText("so the fix covers both", { timeout: 60_000 });
    await expect(timeline(page)).toContainText("Added the same timeout to on_refund_failed", { timeout: 30_000 });
    await idle();
    await expect(page.locator('[id^="permission-"][id$="-global"]')).toHaveCount(0);
    // off the feed, so no message shows its hover toolbar
    await page.mouse.move(5, 5);
    // from the /delegate down, so the delegation reads from its start
    const delegated = timeline(page)
      .getByText("list every webhook handler")
      .first()
      .locator("xpath=ancestor-or-self::*[self::article or starts-with(@id, 'line-')][1]");
    await shot(page, "delegation", {}, () => delegated.evaluate((el) => el.scrollIntoView({ block: "start" })));

    // the auto-approval line, between the handler list and the second edit
    const auto = timeline(page).locator('[id^="line-"]', { hasText: "without asking" }).last();
    await expect(auto).toContainText("global permission");
    const from = timeline(page).locator("article", { hasText: "so the fix covers both" }).last();
    const to = timeline(page).locator("article", { hasText: "Added the same timeout" }).last();
    await to.scrollIntoViewIfNeeded();
    const fromBox = (await from.boundingBox())!;
    const toBox = (await to.boundingBox())!;
    await shot(page, "permission-auto-approved", {
      clip: { x: 312, y: Math.floor(fromBox.y), width: 1128, height: Math.ceil(toBox.y + toBox.height - fromBox.y) },
    });

    // a question in a thread on the plan; @test answers there, and the Threads
    // inbox shows it at work next to the latency thread's unread replies
    const plan = timeline(page).locator("article", { hasText: "I'll wait for a go-ahead" }).first();
    await plan.hover();
    await plan.locator('[id^="reply-"]').click();
    await expect(page.locator("#thread-panel")).toBeVisible();
    await page.locator("#thread-composer-input").fill("Does refund_failed need the same timeout?");
    await page.locator("#thread-composer-input").press("Enter");
    await expect(page.locator('#thread-panel section[id^="telemetry-"]')).toBeVisible({ timeout: 30_000 });
    await page.locator("#rail-threads").click();
    await expect(page.locator('[id^="thread-row-"][id$="-working"]')).toBeVisible();
    await expect(page.locator('[id^="thread-row-"][id$="-unread"]').first()).toBeVisible();
    await shot(page, "threads-inbox");
    await sidebarChannel(page, "refund-webhooks").click();
    await expect(page.locator('[id^="thread-summary-"]').first()).toContainText("2 replies", { timeout: 30_000 });
    await idle();

    await send(page, "/handoff @reviewer needs a second pair of eyes on the plan");
    await expect(timeline(page).locator('[id^="line-"]', { hasText: "ownership moved" }).last()).toBeVisible({ timeout: 60_000 });
    // both themes at the same moment: the reviewer has posted and its turn is over
    await expect(timeline(page)).toContainText("Took over the task", { timeout: 60_000 });
    await idle();
    await bottomOfFeed(page);
    await shot(page, "handoff");

    // -- Live: a brief, an interrupt, a playbook run and a question (@test, fake OpenCode)
    await setInterrupt(page, true);
    await page.goto("/channels/new");
    await page.getByLabel("Repository").selectOption({ label: "acme-storefront" });
    await page.getByLabel("Name (slug, shown as #name)").fill("checkout-cache");
    await page.getByLabel("Topic").fill("Cache priceCart per cart to bring checkout p95 back down");
    const tester = page.getByLabel("Initial owner");
    await tester.selectOption((await tester.locator("option", { hasText: "test" }).first().getAttribute("value"))!);
    await page.locator("#create-channel").click();
    await expect(page).toHaveURL(/\/channels\/ch_/);
    await dismissFlash(page);

    await clickHeader(page, "edit-brief");
    await page.locator("#brief-form textarea").fill(
      "Goal: cache priceCart per cart so checkout p95 is back under 400 ms.\n\n" +
        "- Keep the cache behind the `checkout_cache` flag.\n" +
        "- Don't change the pricing rules.\n" +
        "- @test owns the load test; @reviewer signs off.",
    );
    await page.locator("#save-brief").click();
    await expect(page.locator("#brief-form")).toHaveCount(0);
    await dismissFlash(page);
    // Edit lives in Details; close it so the brief spans the main column
    if (await page.locator("#details-panel").isVisible()) await page.locator("#toggle-details").click();
    await expect(page.locator("#details-panel")).toBeHidden();
    if ((await page.locator("#channel-brief").getAttribute("data-expanded")) !== "true") await page.locator("#brief-toggle").click();
    await expect(page.locator("#brief-body")).toContainText("checkout_cache");
    const brief = (await page.locator("#channel-brief").boundingBox())!;
    await shot(page, "brief", { clip: { x: 312, y: 0, width: 1128, height: Math.ceil(brief.y + brief.height) } });
    await page.locator("#brief-toggle").click();
    await expect(page.locator("#brief-body")).toHaveCount(0);

    // a mention of the working agent goes into its turn after the current step
    await send(page, "@test run the checkout suite slowly");
    const live = page.locator('section[id^="telemetry-"]').first();
    await expect(live.locator('[id$="-current"]')).toContainText("k6 run", { timeout: 30_000 });
    await send(page, "@test skip the payment tests");
    await expect(live.locator('[id^="steer-chip-"]')).toContainText("Interrupting after current step");
    await shot(page, "interrupt");
    await expect(page.locator('section[id^="telemetry-"]')).toHaveCount(0, { timeout: 60_000 });

    // the playbook run waiting on sign-off; its panel opens the first time
    await send(page, "@test run the release-check playbook: Cache priceCart behind the checkout_cache flag.");
    const chip = page.locator("#playbook-chip");
    await expect(chip).toHaveAttribute("data-status", "awaiting_approval", { timeout: 60_000 });
    await expect(page.locator("#playbook-panel")).toBeVisible();
    await expect(page.locator('section[id^="telemetry-"]')).toHaveCount(0, { timeout: 30_000 });
    await shot(page, "playbook-run");
    // accept the card, so it isn't pinned under the feed in the later shots
    await page.locator('[id^="signoff-"][id$="-accept"]').click();
    await expect(page.locator('#playbook-chip[data-status="awaiting_approval"]')).toHaveCount(0);
    await expect(timeline(page)).toContainText("Signed off; closing the run.", { timeout: 30_000 });
    await expect(page.locator('section[id^="telemetry-"]')).toHaveCount(0, { timeout: 30_000 });
    // the panel opened in Details; close Details
    await page.locator("#toggle-details").click();
    await expect(page.locator("#details-panel")).toBeHidden();

    // a question card
    await send(page, "@test ask me how the retry key should work before you change it");
    const question = page.locator('[id^="question-"][data-detached]').first();
    await expect(question).toContainText("Should the retry key include the attempt number?", { timeout: 30_000 });
    await question.scrollIntoViewIfNeeded();
    await shot(page, "question-card");
    await question.getByLabel("Invoice only").check();
    await question.locator('[id$="-send"]').click();
    await expect(timeline(page)).toContainText("Going with Invoice only.", { timeout: 30_000 });
    await expect(page.locator('section[id^="telemetry-"]')).toHaveCount(0, { timeout: 30_000 });

    // a freestanding sign-off card: three options, B recommended
    await send(page, "@test can you write up a few receipt layouts and let me pick one?");
    const signoff = page.locator('section[id^="signoff-so_"]').first();
    await expect(signoff).toContainText("receipt layout", { timeout: 30_000 });
    await expect(page.locator('section[id^="telemetry-"]')).toHaveCount(0, { timeout: 30_000 });
    await signoff.scrollIntoViewIfNeeded();
    await page.mouse.move(5, 5);
    await shot(page, "signoff-card");
    const so = (await signoff.getAttribute("id"))!.replace(/^signoff-/, "");
    await page.locator(`#signoff-${so}-accept-1`).click();
    await expect(page.locator(`#signoff-${so}`)).toHaveCount(0);
    await expect(timeline(page)).toContainText("Heard: you accepted B.", { timeout: 30_000 });
    await expect(page.locator('section[id^="telemetry-"]')).toHaveCount(0, { timeout: 30_000 });

    // @test's session transcript, from its row in Details › Agents
    await openDetails(page);
    await page.locator('#members li[id^="member-"]', { hasText: "@test" }).first().locator('a[id^="transcript-"]').click();
    await expect(page.locator("#transcript-summary")).toContainText("OpenCode");
    await expect(page.locator("#transcript-entries")).toContainText("ask me how the retry key");
    // from the turn that took a message mid-turn (the interrupt): k6, the steered message, the reply
    await page
      .locator('#transcript-entries [id^="transcript-turn-"]', { hasText: "mid-turn" })
      .first()
      .evaluate((el) => el.scrollIntoView({ block: "start" }));
    await page.waitForTimeout(300);
    // down to the end of the sign-off prompt, before the next entry starts
    await shot(page, "transcript", { clip: { x: 0, y: 0, width: 1440, height: 856 } });

    await setInterrupt(page, false);
    await page.goto("/");
    await sidebarChannel(page, "refund-webhooks").click();
    await expect(page.locator("#channel-name")).toContainText("refund-webhooks");

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

  // its own test, so it can be captured alone: npx playwright test user-guide -g "file viewer"
  test("capture the file viewer", async ({ page }) => {
    await page.goto("/");
    await sidebarChannel(page, "payment-retries").click();
    await expect(page.locator("#channel-name")).toContainText("payment-retries");

    // the researcher's write-up opened as a document
    await page.locator("[data-viewer-link]", { hasText: "enqueue-paths.md" }).first().click();
    await expect(page.locator("#file-viewer-preview")).toBeVisible();
    await shot(page, "file-viewer");
    await page.keyboard.press("Escape");
    await expect(page.locator("#file-viewer")).toHaveCount(0);
  });

  test("capture the notification settings", async ({ context, page }) => {
    await stubNotifications(context, { permission: "granted" });
    await turnOn(page);
    await page.locator("#notify-prefs").evaluate((el) => el.scrollIntoView({ block: "center" }));
    await shot(page, "settings-notifications", { clip: { x: 312, y: 0, width: 1128, height: 900 } });
  });

  // near the end: it clears setup in the database, so the app opens as a fresh install
  test("capture the first-run setup", async ({ page }) => {
    // as on a fresh install: no default engine yet, so setup picks Claude Code
    sql("UPDATE settings SET onboarded_at = NULL, default_engine = NULL");
    try {
      await page.goto("/");
      await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
      await expect(page.locator("#setup.phx-connected")).toBeAttached();
      await expect(page.locator("#setup-dialog")).toBeVisible();
      // the Engines step, with the three fake engines answering
      await page.locator("#setup-step-engines").click();
      await expect(page.locator("#setup-steps [aria-current=step]")).toHaveAttribute("id", "setup-step-engines");
      await expect(page.locator("#welcome-claude")).toHaveAttribute("data-state", "ready");
      await expect(page.locator("#welcome-codex")).toHaveAttribute("data-state", "ready");
      await expect(page.locator("#welcome-opencode")).toHaveAttribute("data-state", "ready");
      await scrubPaths(page);
      await shot(page, "setup-modal");
    } finally {
      sql(`UPDATE settings SET onboarded_at = '${iso(new Date())}'`);
    }
  });

  // Last of all: Rerun seeder puts back the starter agents the Acme seed
  // deletes, so every capture before this one keeps Acme's sidebar. The reset
  // modal is never submitted.
  test("capture the environment section", async ({ page }) => {
    await page.goto("/settings");
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
    // A hold isn't part of a reset. The Settings captures above release Acme's;
    // run on its own (-g), this capture still finds it engaged.
    if (await page.locator("#resume-engine-opencode").isVisible()) {
      await page.locator("#resume-engine-opencode").click();
      await expect(page.locator("#engine-pause-opencode")).toBeHidden();
      await dismissFlash(page);
    }
    const panel = page.locator("#environment-panel");
    await panel.scrollIntoViewIfNeeded();

    // the modal, phrase half typed (Reset Canopy still disabled), then Cancel
    await page.locator("#open-reset").click();
    await expect(page.locator("#reset-dialog")).toBeVisible();
    await page.locator("#reset-confirm").pressSequentially("res");
    await expect(page.locator("#confirm-reset")).toBeDisabled();
    // the backup sits next to the e2e database; show where an installed Canopy keeps it
    await page.locator("#reset-backup-preview").evaluate(
      (el, [dir, base]) => {
        el.textContent = el.textContent!.replace(dir, "~/Library/Application Support/Canopy/").replace(base, "canopy.");
      },
      [path.dirname(db) + "/", path.basename(db, ".db") + "."],
    );
    await shot(page, "settings-reset", {}, () => scrubPaths(page));
    await page.locator("#cancel-reset").click();
    await expect(page.locator("#reset-modal")).toHaveCount(0);

    await page.locator("#rerun-seeder").click();
    await expect(page.locator("#seed-result")).toBeVisible();
    await page.locator("#seed-result details summary").click();
    await shotOf(page, "settings-environment", panel);
  });
});
