import { test, expect, Page } from "@playwright/test";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { gotoLive, uniq } from "./helpers";

// Sharing playbooks through GitHub, against the fake gh (e2e/fake-gh/gh.mjs):
// its repository is a plain directory, so a spec arranges GitHub by writing
// files there, and reads the pull requests Canopy opened from .fake-gh/prs.json.
// The first test sets sharing up, so the tests run in order.

const REPO_DIR =
  process.env.FAKE_GH_REPO_DIR || fileURLToPath(new URL("../../tmp/e2e-gh-repo", import.meta.url));
const STATE_DIR = path.join(REPO_DIR, ".fake-gh");

type PR = { number: number; title: string; head: string; base: string; body: string; files: Record<string, string>; state: string };

function putFile(file: string, text: string) {
  fs.mkdirSync(path.dirname(path.join(REPO_DIR, file)), { recursive: true });
  fs.writeFileSync(path.join(REPO_DIR, file), text);
}

function readJson<T>(file: string, fallback: T): T {
  try {
    return JSON.parse(fs.readFileSync(path.join(STATE_DIR, file), "utf8"));
  } catch {
    return fallback;
  }
}

function setFake(config: { push?: boolean; fail?: string }) {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  fs.writeFileSync(path.join(STATE_DIR, "config.json"), JSON.stringify(config));
}

const prs = () => readJson<PR[]>("prs.json", []);

// merges a pull request the way GitHub would: its files land on main
function mergePr(number: number) {
  const all = prs();
  const pr = all.find((p) => p.number === number)!;
  for (const [file, text] of Object.entries(pr.files)) putFile(file, text);
  Object.assign(pr, { state: "merged", applied: true });
  fs.writeFileSync(path.join(STATE_DIR, "prs.json"), JSON.stringify(all, null, 2));
}

// a valid playbook file, as GitHub has it
function playbook(name: string, opts: { version?: number; description?: string; steps?: string[]; instructions?: Record<string, string> } = {}) {
  const steps = opts.steps ?? ["work"];
  const version = opts.version ? `version: ${opts.version}\n` : "";
  const stepLines = steps.map((id) => `  - id: ${id}\n    title: ${id[0].toUpperCase()}${id.slice(1)}\n    owner: coordinator`).join("\n");
  const sections = steps.map((id) => `\n## ${id}\n\n${opts.instructions?.[id] ?? `Do ${id}.`}\n`).join("");
  return `---\nname: ${name}\n${version}description: ${opts.description ?? `Does ${name}.`}\nsteps:\n${stepLines}\n---\n\nWork carefully.\n${sections}`;
}

const fileOf = (name: string) => `playbooks/${name}.md`;
const dom = (name: string) => `playbooks-${name}-md`;
const row = (page: Page, name: string) => page.locator(`#playbooks li[data-playbook='${name}']`);

async function playbookId(page: Page, name: string) {
  return (await row(page, name).getAttribute("id"))!.replace(/^playbook-/, "");
}

// imports every ticked row from a fresh read of GitHub
async function importTicked(page: Page, count: number) {
  await gotoLive(page, "/playbooks?github=import");
  await expect(page.locator("#import-submit")).toHaveText(`Import ${count}`);
  await page.locator("#import-submit").click();
  await expect(page.locator("#undo-toast")).toContainText(count === 1 ? "Imported 1 playbook" : `Imported ${count} playbooks`);
  await expect(page.locator("#github-import-dialog")).toHaveCount(0);
}

// edits the description in the builder and saves: the version goes up by one
async function editDescription(page: Page, name: string, description: string) {
  await gotoLive(page, "/playbooks");
  const id = await playbookId(page, name);
  await gotoLive(page, `/playbooks/${id}/edit`);
  await page.locator("#about-description").fill(description);
  await expect(page.locator("#save-playbook")).toBeEnabled();
  await page.locator("#save-playbook").click();
  await expect(page.locator("#save-state")).toContainText("Saved");
  return id;
}

test.describe.serial("playbook sharing", () => {
  // nothing GitHub sends may reach a script or a native dialog
  let dialogs: string[] = [];

  test.beforeEach(async ({ page }) => {
    setFake({});
    dialogs = [];
    page.on("dialog", (dialog) => {
      dialogs.push(dialog.message());
      dialog.dismiss();
    });
  });

  test.afterEach(() => {
    expect(dialogs).toEqual([]);
  });

  test("first run: set up, view, import, undo, import again", async ({ page }) => {
    const [a, b] = [uniq("pb"), uniq("pb")];
    putFile(fileOf(a), playbook(a, { version: 3, instructions: { work: "Run <script>window.__pwned = 1</script> first." } }));
    putFile(fileOf(b), playbook(b, { version: 3 }));
    putFile("playbooks/broken.md", "---\nname: Broken Name\n---\n");

    await gotoLive(page, "/playbooks");
    await page.locator("#github-menu-toggle").click();
    await page.locator("#github-import").click();
    await expect(page).toHaveURL(/\?github=import$/);

    // not set up: a pasted address fills all three fields and the check runs,
    // even with Tab pressed at once (focus is in Branch before the server replies)
    await page.locator("#sharing-repo").fill("https://github.com/acme/playbooks/tree/main/playbooks");
    await page.locator("#sharing-repo").press("Tab");
    await expect(page.locator("#sharing-branch")).toBeFocused();
    await expect(page.locator("#sharing-repo")).toHaveValue("acme/playbooks");
    await expect(page.locator("#sharing-branch")).toHaveValue("main");
    await expect(page.locator("#sharing-folder")).toHaveValue("playbooks");
    await expect(page.locator("#sharing-check-ok")).toContainText("Connected as e2e-user · can push · 3 playbooks");
    await page.locator("#sharing-setup-continue").click();

    // both readable files are ready and ticked; the broken one can't import
    await expect(page.locator(`#import-ready #import-tick-${dom(a)}`)).toBeChecked();
    await expect(page.locator(`#import-ready #import-tick-${dom(b)}`)).toBeChecked();
    await expect(page.locator("#import-cant")).toContainText("broken.md");
    await expect(page.locator("#import-submit")).toHaveText("Import 2");

    // View shows the instructions as text, never as markup
    await page.locator(`#import-compare-${dom(a)}`).click();
    await expect(page.locator("#compare-view")).toContainText("<script>window.__pwned = 1</script>");
    await expect(page.locator("#compare-view script")).toHaveCount(0);
    expect(await page.evaluate(() => (window as any).__pwned)).toBeUndefined();
    await page.locator("#compare-close").click();
    await expect(page.locator("#compare-dialog")).toHaveCount(0);

    // Import 2, then Undo takes both back out
    await page.locator("#import-submit").click();
    await expect(page.locator("#undo-toast")).toContainText("Imported 2 playbooks");
    await expect(row(page, a)).toHaveCount(1);
    await page.locator("#undo-delete").click();
    await expect(row(page, a)).toHaveCount(0);
    await expect(row(page, b)).toHaveCount(0);

    // and again, for good: the expanded row says where it came from
    await importTicked(page, 2);
    const id = await playbookId(page, a);
    await page.locator(`#expand-playbook-${id}`).click();
    await expect(page.locator(`#playbook-version-${id}`)).toHaveText("v3 · from acme/playbooks (v3)");
  });

  test("edit, export a pull request, then its merge brings it up to date", async ({ page }) => {
    const name = uniq("pb");
    putFile(fileOf(name), playbook(name, { version: 3 }));
    await importTicked(page, 1);

    const id = await editDescription(page, name, "Edited in Canopy.");
    await expect(page.locator("#builder-version")).toHaveText("v4 · from acme/playbooks (v3) · edited since");

    // Export ticks only the edited row, and the title follows it
    await gotoLive(page, "/playbooks?github=export");
    await expect(page.locator(`#export-tick-${dom(name)}`)).toBeChecked();
    // playbooks never on GitHub (the starters among them) are opt-in
    const notOnGitHub = page.locator("input[id^='export-tick-local-']");
    await expect(notOnGitHub.first()).toBeVisible();
    for (const box of await notOnGitHub.all()) await expect(box).not.toBeChecked();
    await expect(page.locator(`#export-row-${dom(name)}`)).toContainText("Edited · v3 → v4");
    await expect(page.locator("#export-pr-form_title")).toHaveValue(`Update ${name} (v4)`);
    await expect(page.locator("#export-branch")).toContainText("main");
    const shown = await page.locator("#export-branch span.font-mono").first().textContent();
    await page.locator("#export-pr-form_note").fill("From the e2e suite.");
    await page.locator("#export-submit").click();

    await expect(page.locator("#pr-toast")).toContainText("on acme/playbooks");
    const pr = prs().at(-1)!;
    await expect(page.locator("#pr-toast")).toContainText(`Opened PR #${pr.number}`);
    await expect(page.locator("#pr-toast-link")).toHaveAttribute("href", `https://github.com/acme/playbooks/pull/${pr.number}`);
    await expect(page.locator("#pr-toast")).toContainText(`1 playbook. It shows In PR #${pr.number} until it's merged.`);
    await expect(page.locator("#pr-toast-branch")).toHaveText(`Branch ${pr.head}`);

    expect(pr.base).toBe("main");
    expect(pr.head).toMatch(/^canopy\/playbooks-\d{4}-\d{6}(-\d+)?$/);
    // the pull request is on the branch the footer showed
    expect(pr.head).toBe(shown);
    expect(pr.title).toBe(`Update ${name} (v4)`);
    expect(pr.body).toContain("From the e2e suite.");
    expect(pr.body).toContain("Exported from Canopy");
    expect(pr.files[fileOf(name)]).toContain("version: 4\n");
    expect(pr.files[fileOf(name)]).toContain("description: Edited in Canopy.");

    // the library row links to the pull request
    const chip = page.locator(`#sync-chip-${id}`);
    await expect(chip).toHaveAttribute("data-state", "in_pr");
    await expect(chip).toHaveText(`In PR #${pr.number}`);
    await expect(chip).toHaveAttribute("href", `https://github.com/acme/playbooks/pull/${pr.number}`);

    // merged on GitHub: the next read links the row to what was merged
    mergePr(pr.number);
    await gotoLive(page, "/playbooks?github=import");
    await expect(page.locator("#import-up-to-date")).toContainText(name);
    await gotoLive(page, "/playbooks");
    await expect(page.locator(`#sync-chip-${id}`)).toHaveCount(0);
  });

  test("both changed: Compare, Keep both, and the original's name is taken", async ({ page }) => {
    const name = uniq("pb");
    putFile(fileOf(name), playbook(name, { version: 3 }));
    await importTicked(page, 1);
    const id = await editDescription(page, name, "Changed in Canopy.");
    putFile(fileOf(name), playbook(name, { version: 4, description: "Changed on GitHub." }));

    // a fresh read puts it under Needs a look, and the library flags it
    await gotoLive(page, "/playbooks?github=import");
    await expect(page.locator(`#import-look #import-tick-${dom(name)}`)).toBeDisabled();
    await gotoLive(page, "/playbooks");
    await expect(page.locator("#playbook-github-notice")).toContainText("on GitHub");
    const chip = page.locator(`#sync-chip-${id}`);
    await expect(chip).toHaveAttribute("data-state", "both_changed");

    // the chip opens Import at that row; Compare shows both sides
    await chip.click();
    await expect(page).toHaveURL(/github=import&row=/);
    await page.locator(`#import-compare-${dom(name)}`).click();
    await expect(page.locator("#compare-changes")).toContainText("Changed on GitHub.");
    await expect(page.locator("#compare-steps")).toBeVisible();
    await expect(page.locator("#compare-file-diff")).not.toHaveAttribute("open", "");

    // stacked at phone width, each step says whose it is
    const size = page.viewportSize()!;
    await page.setViewportSize({ width: 390, height: 844 });
    const side = page.locator("#compare-remote-0").getByText("GitHub", { exact: true });
    await expect(page.locator("#compare-local-0").getByText("Yours", { exact: true })).toBeVisible();
    await expect(side).toBeVisible();
    await page.setViewportSize(size);
    await expect(side).toBeHidden();

    // Keep both: GitHub's copy imports beside yours
    await page.locator("#compare-keep-both").click();
    await expect(page.locator("#compare-dialog")).toHaveCount(0);
    await expect(page.locator(`#import-choice-${dom(name)}`)).toHaveText("Keep both");
    await expect(page.locator(`#import-as-${dom(name)}`)).toContainText(`${name}-2`);
    await expect(page.locator(`#import-tick-${dom(name)}`)).toBeChecked();
    await page.locator("#import-submit").click();
    await expect(page.locator("#undo-toast")).toContainText("Imported 1 playbook");
    await expect(row(page, `${name}-2`)).toHaveCount(1);
    await expect(row(page, name)).toHaveCount(1);

    // yours keeps its name, which on GitHub is now the copy's file
    await gotoLive(page, "/playbooks?github=export");
    await expect(page.locator("#export-cant")).toContainText(name);
    await expect(page.locator("#export-cant")).toContainText("Name taken on GitHub");
  });

  test("an update on GitHub: badge, notice, Compare, Import this", async ({ page }) => {
    const name = uniq("pb");
    putFile(fileOf(name), playbook(name, { version: 3 }));
    await importTicked(page, 1);
    putFile(fileOf(name), playbook(name, { version: 4, steps: ["work", "check"] }));

    await gotoLive(page, "/playbooks?github=import");
    await expect(page.locator(`#import-ready #import-tick-${dom(name)}`)).toBeChecked();
    await gotoLive(page, "/playbooks");
    const id = await playbookId(page, name);
    await expect(page.locator(`#sync-chip-${id}`)).toHaveText("⤓ Update · v3 → v4");
    await expect(page.locator("#github-import-badge")).toHaveText("1");
    await expect(page.locator("#playbook-github-notice")).toContainText("1 update on GitHub");

    // Review → Compare → Import this ticks it again
    await page.locator("#playbook-github-notice-review").click();
    await page.locator(`#import-tick-${dom(name)}`).uncheck();
    await expect(page.locator("#import-submit")).toBeDisabled();
    await page.locator(`#import-compare-${dom(name)}`).click();
    await expect(page.locator("#compare-dialog-sub")).toContainText("GitHub has v4; yours is v3");
    await expect(page.locator("#compare-changes")).toContainText("Check");
    await page.locator("#compare-import-this").click();
    await expect(page.locator(`#import-tick-${dom(name)}`)).toBeChecked();
    await page.locator("#import-submit").click();
    await expect(page.locator("#undo-toast")).toContainText("Imported 1 playbook");

    await page.locator(`#expand-playbook-${id}`).click();
    await expect(page.locator(`#playbook-version-${id}`)).toHaveText("v4 · from acme/playbooks (v4)");
    await expect(page.locator(`#sync-chip-${id}`)).toHaveCount(0);
  });

  test("import only, and a pull request GitHub refuses", async ({ page }) => {
    const name = uniq("pb");
    putFile(fileOf(name), playbook(name, { version: 2 }));
    await importTicked(page, 1);
    const id = await editDescription(page, name, "Refused by GitHub.");

    // no push access: Export explains and won't open a pull request
    setFake({ push: false });
    await gotoLive(page, "/playbooks?github=export");
    await expect(page.locator("#export-read-only")).toBeVisible();
    await expect(page.locator("#export-submit")).toBeDisabled();

    // GitHub refuses the pull request: the branch is cleaned up, nothing changes here
    setFake({ fail: "pulls" });
    const before = prs().length;
    await gotoLive(page, "/playbooks?github=export");
    await expect(page.locator(`#export-tick-${dom(name)}`)).toBeChecked();
    const branch = page.locator("#export-branch span.font-mono").first();
    await page.locator("#export-submit").click();
    await expect(page.locator("#sharing-error")).toContainText("Couldn't open the pull request");
    await expect(page.locator("#sharing-error")).toContainText("The e2e fake was told to fail pulls.");
    expect(prs()).toHaveLength(before);
    expect(readJson<{ deleted: string[] }>("git.json", { deleted: [] }).deleted.at(-1)).toMatch(/^refs\/heads\/canopy\/playbooks-/);
    await expect(page.locator(`#export-tick-${dom(name)}`)).toBeChecked();

    // and once GitHub takes it, the same dialog opens it, on the branch it shows
    // (names go to the second, and the failed one's branch was deleted)
    const retry = await branch.textContent();
    setFake({});
    await page.locator("#export-submit").click();
    await expect(page.locator("#pr-toast")).toContainText(`Opened PR #${before + 1}`);
    await expect(page.locator(`#sync-chip-${id}`)).toHaveAttribute("data-state", "in_pr");
    expect(prs().at(-1)!.head).toBe(retry);
    await expect(page.locator("#pr-toast-branch")).toHaveText(`Branch ${prs().at(-1)!.head}`);
  });

  test("keyboard: the GitHub menu, Import, Compare and Export, Esc and focus", async ({ page }) => {
    const name = uniq("pb");
    putFile(fileOf(name), playbook(name, { version: 1 }));
    await gotoLive(page, "/playbooks");
    const toggle = page.locator("#github-menu-toggle");
    const inDialog = (id: string) =>
      page.evaluate((id) => !!document.activeElement?.closest(`#${id}`), id);

    // the menu opens from the keyboard and its items are reachable with Tab
    async function openFromMenu(item: string) {
      await toggle.focus();
      await expect(toggle).toBeFocused();
      await expect(page.locator(item)).toBeVisible();
      for (let i = 0; i < 4 && !(await page.locator(item).evaluate((el) => el === document.activeElement)); i++)
        await page.keyboard.press("Tab");
      await expect(page.locator(item)).toBeFocused();
      await page.keyboard.press("Enter");
    }

    // Import: Space ticks and unticks, Tab stays inside, Esc closes back to the menu
    await openFromMenu("#github-import");
    await expect(page).toHaveURL(/\?github=import$/);
    const tick = page.locator(`#import-tick-${dom(name)}`);
    await expect(tick).toBeChecked();
    await expect(page.locator("#import-submit")).toHaveText("Import 1");
    await tick.focus();
    await page.keyboard.press("Space");
    await expect(tick).not.toBeChecked();
    await expect(page.locator("#import-submit")).toHaveText("Import");
    await expect(page.locator("#import-submit")).toBeDisabled();
    await page.keyboard.press("Space");
    await expect(tick).toBeChecked();
    await expect(page.locator("#import-submit")).toHaveText("Import 1");
    for (let i = 0; i < 12; i++) {
      await page.keyboard.press("Tab");
      expect(await inDialog("github-import-dialog")).toBe(true);
    }

    // Compare from the keyboard; Esc closes only Compare and goes back to the row's tick
    await page.locator(`#import-compare-${dom(name)}`).focus();
    await page.keyboard.press("Enter");
    await expect(page.locator("#compare-dialog")).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(page.locator("#compare-dialog")).toHaveCount(0);
    await expect(page.locator("#github-import-dialog")).toBeVisible();
    await expect(tick).toBeFocused();

    await page.keyboard.press("Escape");
    await expect(page.locator("#github-import-dialog")).toHaveCount(0);
    await expect(page).toHaveURL(/\/playbooks$/);
    await expect(toggle).toBeFocused();

    // Export the same way
    await openFromMenu("#github-export");
    await expect(page).toHaveURL(/\?github=export$/);
    const box = page.locator("input[id^='export-tick-local-']").first();
    await box.focus();
    await page.keyboard.press("Space");
    await expect(box).toBeChecked();
    await page.keyboard.press("Space");
    await expect(box).not.toBeChecked();
    await page.keyboard.press("Escape");
    await expect(page.locator("#github-export-dialog")).toHaveCount(0);
    await expect(page).toHaveURL(/\/playbooks$/);
    await expect(toggle).toBeFocused();
  });
});
