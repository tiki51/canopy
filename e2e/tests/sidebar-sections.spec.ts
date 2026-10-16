// Channel sections and easier archiving in the sidebar: sections made, named,
// reordered, collapsed and deleted in place; channels moved by drag, the row
// menu and the palette; archive from the row with an Undo toast; the "Task
// done" bar; the keyboard menu; the touch layout; two tabs kept in step; and
// the Start page's section picker.
import { test, expect, Page, Locator } from "@playwright/test";
import { clickHeader, createChannel, gotoLive, openDetails, reload, send, uniq } from "./helpers";

const menu = (page: Page) => page.locator("#sidebar-menu");
const submenu = (page: Page) => page.locator("#sidebar-submenu");
const toast = (page: Page) => page.locator("#sidebar-undo-toast");
const undo = (page: Page) => page.locator("#sidebar-undo-archive");
const project = (page: Page) => page.locator("#sidebar-projects > [data-repo-id]").first();
const row = (page: Page, id: string) => page.locator(`#sidebar-row-${id}`);
const link = (page: Page, id: string) => page.locator(`#sidebar-channel-${id}`);
const section = (page: Page, name: string) => page.locator(`ul[data-section-name="${name}"]`);
const top = (page: Page) => project(page).locator("ul[data-drop-section]");
const archivedFold = (page: Page) => project(page).locator('details[id^="sidebar-archived-"]');

async function connected(page: Page) {
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
}

/** The project's + → name → Enter; returns the section's id. */
async function newSection(page: Page, name: string): Promise<string> {
  await project(page).locator(".group\\/proj").hover();
  await project(page).locator("[data-new-section]").click();
  const input = project(page).locator('[data-section-editor="create"] input');
  await expect(input).toBeFocused();
  await input.fill(name);
  await input.press("Enter");
  await expect(section(page, name)).toBeAttached();
  await expect(input).toBeHidden();
  return (await section(page, name).getAttribute("data-section-id"))!;
}

// Through the row's ⋯. Right-click has its own test: on macOS the menu opens
// on mousedown and the popover's light dismiss shuts it on mouseup.
async function openRowMenu(page: Page, id: string) {
  await row(page, id).hover();
  await page.locator(`#sidebar-row-menu-${id}`).click();
  await expect(menu(page)).toBeVisible();
}

async function moveViaMenu(page: Page, id: string, sectionName: string) {
  await openRowMenu(page, id);
  await menu(page).getByRole("menuitem", { name: "Move to section" }).click();
  await expect(submenu(page)).toBeVisible();
  await submenu(page).getByRole("menuitemradio", { name: sectionName, exact: true }).click();
  await expect(section(page, sectionName).locator(`#sidebar-row-${id}`)).toBeAttached();
}

async function openSectionMenu(page: Page, name: string) {
  const header = section(page, name).locator("[data-section-header]");
  await header.hover();
  await header.locator("[data-menu]").click();
  await expect(menu(page)).toBeVisible();
}

async function setTask(page: Page, title: string, status: string) {
  await clickHeader(page, "edit-task");
  const form = page.locator("#task-form");
  await form.getByLabel("Title").fill(title);
  await form.getByLabel("Status").selectOption(status);
  await page.locator("#save-task").click();
}

async function completeTask(page: Page, title = "Ship the thing") {
  await setTask(page, title, "completed");
  await expect(page.locator("#done-bar")).toBeVisible();
}

const drawer = (page: Page) => page.locator("#app-drawer");
const drawerOpener = (page: Page) => page.locator('label[for="app-drawer"][aria-label="Open the menu"]').first();

/** Every row id appears once, and only inside the top list or a section's list. */
async function expectSidebarIntact(page: Page) {
  const report = await page.evaluate(() => {
    const ids = [...document.querySelectorAll("#sidebar-projects li[data-channel-id]")].map((li) => li.id);
    const dupes = ids.filter((id, i) => ids.indexOf(id) !== i);
    const stray = [...document.querySelectorAll("#sidebar-projects li[data-channel-id]")].filter(
      (li) => !li.parentElement!.matches("ul[data-section-id], ul[data-drop-section], details ul"),
    ).length;
    return { dupes, stray };
  });
  expect(report).toEqual({ dupes: [], stray: 0 });
}

/**
 * Posts in `channelId` from a second page. The user's own post isn't unread;
 * the owner's (fake) reply that follows is, and it arrives some seconds later.
 */
async function patchFrom(page: Page, channelId: string, text = uniq("ping")) {
  const other = await page.context().newPage();
  await gotoLive(other, `/channels/${channelId}`);
  await send(other, text);
  await expect(other.locator("#timeline")).toContainText(text);
  await other.close();
}

// Stepped, with a nudge at the target: Sortable decides on dragover, and
// locator.dragTo's single move sometimes gives it none over the target.
async function drag(page: Page, from: Locator, to: Locator) {
  await from.scrollIntoViewIfNeeded();
  const a = (await from.boundingBox())!;
  await page.mouse.move(a.x + 20, a.y + a.height / 2);
  await page.mouse.down();
  await page.mouse.move(a.x + 25, a.y + a.height / 2 + 4, { steps: 3 });
  await to.scrollIntoViewIfNeeded();
  const b = (await to.boundingBox())!;
  await page.mouse.move(b.x + 30, b.y + b.height / 2, { steps: 12 });
  // re-aim, as a hand does: on a scrolled sidebar the target can shift a row
  // while the dragged row passes through the lists above it
  const c = (await to.boundingBox())!;
  await page.mouse.move(c.x + 34, c.y + c.height / 2 + 1, { steps: 3 });
  await page.mouse.up();
}

test.describe("sidebar sections", () => {
  // -- F2 first: Sortable's zones ---------------------------------------------

  test("E-M4/E-M6: drag a row onto a collapsed section header, into a section's rows, and back to the top", async ({ page }) => {
    const a = await createChannel(page, uniq("drag-a"));
    const b = await createChannel(page, uniq("drag-b"));
    const holder = await createChannel(page, uniq("drag-in"));
    const coll = uniq("Coll");
    const open = uniq("Open");
    const collId = await newSection(page, coll);
    await newSection(page, open);
    await moveViaMenu(page, holder, open);

    // collapse `coll`; its count shows 0
    await page.locator(`#sidebar-section-toggle-${collId}`).click();
    await expect(page.locator(`#sidebar-section-toggle-${collId}`)).toHaveAttribute("aria-expanded", "false");
    await expect(page.locator(`#sidebar-section-count-${collId}`)).toHaveText("0");

    // into an open section's rows
    await drag(page, link(page, b), link(page, holder));
    await expect(section(page, open).locator(`#sidebar-row-${b}`)).toBeAttached();
    await expectSidebarIntact(page);

    // onto the collapsed header, passing over the open section on the way (as a hand does).
    // Bug 2: it must land in the section under the pointer, not the one passed over.
    await drag(page, link(page, a), page.locator(`#sidebar-section-toggle-${collId}`));
    await expect(section(page, coll).locator(`#sidebar-row-${a}`), "dropped on the collapsed header").toBeAttached();
    await expect(section(page, open).locator(`#sidebar-row-${a}`)).toHaveCount(0);
    await expect(page.locator(`#sidebar-section-toggle-${collId}`)).toHaveAttribute("aria-expanded", "false");
    await expect(page.locator(`#sidebar-section-count-${collId}`)).toHaveText("1");
    await expectSidebarIntact(page);

    // back out to the top list. On a fresh DB it is empty now and the drop strip
    // shows while dragging; after other specs it holds their channels, so drop on one.
    const leftover = top(page).locator("li[data-channel-id]");
    if ((await leftover.count()) === 0) {
      await link(page, b).scrollIntoViewIfNeeded();
      const from = (await link(page, b).boundingBox())!;
      await page.mouse.move(from.x + 20, from.y + from.height / 2);
      await page.mouse.down();
      await page.mouse.move(from.x + 25, from.y + from.height / 2 + 5, { steps: 3 });
      await expect(project(page)).toHaveAttribute("data-dragging", "");
      const strip = (await top(page).boundingBox())!;
      expect(strip.height).toBeGreaterThanOrEqual(20);
      await page.mouse.move(strip.x + 30, strip.y + strip.height / 2, { steps: 10 });
      await page.mouse.up();
    } else {
      test.info().annotations.push({ type: "note", description: "top list not empty (shared DB): drop strip not checked" });
      await drag(page, link(page, b), leftover.last().locator("a"));
    }
    await expect(top(page).locator(`#sidebar-row-${b}`)).toBeAttached();
    await expectSidebarIntact(page);

    // it all holds after a reload
    await reload(page);
    await expect(section(page, coll).locator(`#sidebar-row-${a}`)).toBeAttached();
    await expect(top(page).locator(`#sidebar-row-${b}`)).toBeAttached();
  });

  test("E-M5: while dragging, the zone under the pointer lights up (not the origin); a patch mid-drag keeps it", async ({ page }) => {
    const only = await createChannel(page, uniq("strip"));
    const other = await createChannel(page, uniq("strip-o"));
    await createChannel(page, uniq("strip-here")); // current channel: never unread
    const name = uniq("Strip");
    await newSection(page, name);
    await moveViaMenu(page, only, name);

    const proj = project(page);
    const lit = proj.locator(".sidebar-drop-target");
    const origin = section(page, name);
    const box = (await link(page, only).boundingBox())!;
    await page.mouse.move(box.x + 20, box.y + box.height / 2);
    await page.mouse.down();
    await page.mouse.move(box.x + 30, box.y + box.height / 2 + 4, { steps: 5 });
    await expect(proj).toHaveAttribute("data-dragging", "");
    // over its own section: nothing lit (dropping there changes nothing)
    await expect(lit).toHaveCount(0);

    // Bug 3: over the top list, which then carries the highlight, and only it
    const over = (await link(page, other).boundingBox())!;
    await page.mouse.move(over.x + 30, over.y + over.height / 2, { steps: 12 });
    await page.mouse.move(over.x + 34, over.y + over.height / 2 + 1, { steps: 3 });
    await expect(top(page)).toHaveClass(/\bsidebar-drop-target\b/);
    await expect(lit).toHaveCount(1);
    await expect(origin).not.toHaveClass(/\bsidebar-drop-target\b/);

    // an unread patch lands mid-drag: the highlight and data-dragging hold
    await patchFrom(page, other);
    await expect(row(page, other)).toHaveAttribute("data-unread", "true", { timeout: 30_000 });
    await expect(proj).toHaveAttribute("data-dragging", "");
    await expect(top(page)).toHaveClass(/\bsidebar-drop-target\b/);

    await page.mouse.move(over.x + 36, over.y + over.height / 2 + 2, { steps: 2 });
    await page.mouse.up();
    await expect(proj).not.toHaveAttribute("data-dragging", "");
    await expect(lit).toHaveCount(0);
    await expect(top(page).locator(`#sidebar-row-${only}`)).toBeAttached();
    await expectSidebarIntact(page);
  });

  test("E-M7: a drag cancelled with Esc, or dropped on the main pane, leaves the row where it was", async ({ page }) => {
    const ch = await createChannel(page, uniq("cancel"));
    await createChannel(page, uniq("cancel-here"));
    const name = uniq("Away");
    const sid = await newSection(page, name);
    const start = async () => {
      await link(page, ch).scrollIntoViewIfNeeded();
      const a = (await link(page, ch).boundingBox())!;
      await page.mouse.move(a.x + 20, a.y + a.height / 2);
      await page.mouse.down();
      await page.mouse.move(a.x + 25, a.y + a.height / 2 + 4, { steps: 3 });
      await expect(project(page)).toHaveAttribute("data-dragging", "");
      // over the section, which lights up
      const b = (await page.locator(`#sidebar-section-toggle-${sid}`).boundingBox())!;
      await page.mouse.move(b.x + 30, b.y + b.height / 2, { steps: 12 });
      await page.mouse.move(b.x + 34, b.y + b.height / 2 + 1, { steps: 3 });
      await expect(section(page, name)).toHaveClass(/\bsidebar-drop-target\b/);
    };
    const stays = async () => {
      await expect(project(page)).not.toHaveAttribute("data-dragging", "");
      await page.waitForTimeout(500);
      await expect(section(page, name).locator(`#sidebar-row-${ch}`)).toHaveCount(0);
      await expect(top(page).locator(`#sidebar-row-${ch}`)).toBeAttached();
      await expect(page.locator(".sidebar-drop-target")).toHaveCount(0);
    };

    // Esc: a dragend with no drop
    await start();
    await page.keyboard.press("Escape");
    await page.mouse.up();
    await stays();

    // a drop on the main pane, outside the sidebar
    await start();
    const main = (await page.locator("#main").boundingBox())!;
    await page.mouse.move(main.x + main.width / 2, main.y + main.height / 2, { steps: 12 });
    // out of the project: no zone takes the drop, so none stays lit
    await expect(page.locator(".sidebar-drop-target")).toHaveCount(0);
    await page.mouse.up();
    await stays();

    await reload(page);
    await expect(top(page).locator(`#sidebar-row-${ch}`)).toBeAttached();
  });

  test("E-S6: drag a section header to reorder; the order survives a reload", async ({ page }) => {
    await createChannel(page, uniq("order"));
    const first = uniq("First");
    const second = uniq("Second");
    await newSection(page, first); // pos 0
    await newSection(page, second); // pos 0, `first` now 1
    const names = () => project(page).locator("ul[data-section-id]").evaluateAll((els) => els.map((e) => (e as HTMLElement).dataset.sectionName));
    expect((await names()).slice(0, 2)).toEqual([second, first]);

    await drag(page, section(page, first).locator("[data-section-handle]"), section(page, second).locator("[data-section-handle]"));
    await expect.poll(async () => (await names()).slice(0, 2)).toEqual([first, second]);
    await reload(page);
    expect((await names()).slice(0, 2)).toEqual([first, second]);
  });

  test("E-S6b: a section drag cancelled with Esc keeps the order, after a reload too", async ({ page }) => {
    await createChannel(page, uniq("order-esc"));
    const first = uniq("First");
    const second = uniq("Second");
    await newSection(page, first);
    await newSection(page, second);
    const names = () => project(page).locator("ul[data-section-id]").evaluateAll((els) => els.map((e) => (e as HTMLElement).dataset.sectionName));
    expect((await names()).slice(0, 2)).toEqual([second, first]);

    const from = section(page, first).locator("[data-section-handle]");
    const a = (await from.boundingBox())!;
    await page.mouse.move(a.x + 20, a.y + a.height / 2);
    await page.mouse.down();
    await page.mouse.move(a.x + 25, a.y + a.height / 2 - 4, { steps: 3 });
    const b = (await section(page, second).locator("[data-section-handle]").boundingBox())!;
    await page.mouse.move(b.x + 30, b.y + b.height / 2, { steps: 12 });
    await page.mouse.move(b.x + 34, b.y + b.height / 2 - 1, { steps: 3 });
    // Sortable sorts live: the preview has the new order
    await expect.poll(async () => (await names()).slice(0, 2)).toEqual([first, second]);
    await page.keyboard.press("Escape");
    await page.mouse.up();

    await expect.poll(async () => (await names()).slice(0, 2)).toEqual([second, first]);
    await page.waitForTimeout(500);
    expect((await names()).slice(0, 2)).toEqual([second, first]);
    await reload(page);
    expect((await names()).slice(0, 2)).toEqual([second, first]);
  });

  // -- Sections: create, rename, reorder, delete, collapse ---------------------

  test("E-S1..S5, S7: make, refuse a duplicate, cancel, rename, move up/down, delete", async ({ page }) => {
    const ch = await createChannel(page, uniq("sec"));
    const name = uniq("Releases");
    const id = await newSection(page, name);
    // the new header is first among sections and has focus
    await expect(project(page).locator("ul[data-section-id]").first()).toHaveAttribute("data-section-id", id);
    await expect(page.locator(`#sidebar-section-toggle-${id}`)).toBeFocused();

    // a duplicate in another case: inline error, editor stays open, text kept
    await project(page).locator(".group\\/proj").hover();
    await project(page).locator("[data-new-section]").click();
    const input = project(page).locator('[data-section-editor="create"] input');
    await input.fill(name.toUpperCase());
    await input.press("Enter");
    const error = project(page).locator('[data-section-editor="create"] [role="alert"]');
    await expect(error).toHaveText("Name is already a section in this project");
    await expect(input).toBeVisible();
    await expect(input).toHaveValue(name.toUpperCase());
    await expect(page.locator("#flash-error")).toHaveCount(0);
    // Esc cancels; reopening shows an empty field and no error
    await input.press("Escape");
    await expect(input).toBeHidden();
    await project(page).locator("[data-new-section]").click();
    await expect(input).toHaveValue("");
    await expect(error).toHaveText("");
    // leaving the field cancels too
    await input.fill(uniq("Blurred"));
    await page.locator("#composer-input").click();
    await expect(input).toBeHidden();

    // rename through the section menu
    await openSectionMenu(page, name);
    await menu(page).getByRole("menuitem", { name: "Rename section" }).click();
    const rename = page.locator(`#sidebar-rename-section-${id} input`);
    await expect(rename).toBeFocused();
    await expect(rename).toHaveValue(name);
    const renamed = uniq("Shipped");
    await rename.fill(renamed);
    await rename.press("Enter");
    await expect(page.locator(`#sidebar-section-label-${id}`)).toHaveText(renamed);
    await expect(page.locator(`#sidebar-section-toggle-${id}`)).toBeFocused();

    // Move up is disabled on the first section; Move down moves it
    const other = uniq("Other");
    const otherId = await newSection(page, other);
    await openSectionMenu(page, other);
    await expect(menu(page).getByRole("menuitem", { name: "Move up" })).toHaveAttribute("aria-disabled", "true");
    await menu(page).getByRole("menuitem", { name: "Move down" }).click();
    await expect(project(page).locator("ul[data-section-id]").nth(1)).toHaveAttribute("data-section-id", otherId);
    await openSectionMenu(page, other);
    await menu(page).getByRole("menuitem", { name: "Move up" }).click();
    await expect(project(page).locator("ul[data-section-id]").first()).toHaveAttribute("data-section-id", otherId);
    await page.keyboard.press("Escape");

    // delete: its channels go to the top, nothing archived, no confirm
    await moveViaMenu(page, ch, renamed);
    const foldBefore = await archivedFold(page).count() ? await archivedFold(page).locator("summary").innerText() : "none";
    await openSectionMenu(page, renamed);
    await expect(menu(page)).toContainText("Its channels move back to the top of the project. Nothing is archived.");
    await menu(page).getByRole("menuitem", { name: "Delete section" }).click();
    await expect(page.locator("#canopy-confirm")).toBeHidden();
    await expect(section(page, renamed)).toHaveCount(0);
    await expect(top(page).locator(`#sidebar-row-${ch}`)).toBeAttached();
    const foldAfter = await archivedFold(page).count() ? await archivedFold(page).locator("summary").innerText() : "none";
    expect(foldAfter).toBe(foldBefore);
  });

  test("E-S8: collapse shows a count, survives a reload, and a dot appears for unread inside", async ({ page }) => {
    const inside = await createChannel(page, uniq("unread"));
    const here = await createChannel(page, uniq("here"));
    const name = uniq("Quiet");
    const id = await newSection(page, name);
    await moveViaMenu(page, inside, name);
    await page.locator(`#sidebar-section-toggle-${id}`).click();
    await expect(row(page, inside)).toBeHidden();
    await expect(page.locator(`#sidebar-section-count-${id}`)).toHaveText("1");
    await expect(page.locator(`#sidebar-section-dot-${id}`)).toHaveCount(0);
    await reload(page);
    await expect(page.locator(`#sidebar-section-toggle-${id}`)).toHaveAttribute("aria-expanded", "false");
    await patchFrom(page, inside);
    await expect(page.locator(`#sidebar-section-dot-${id}`)).toBeVisible({ timeout: 30_000 });
    await page.locator(`#sidebar-section-toggle-${id}`).click();
    await expect(row(page, inside)).toBeVisible();
    void here;
  });

  test("E-S9: an open editor survives an unread patch; after a save, a patch doesn't reopen it", async ({ page }) => {
    const other = await createChannel(page, uniq("patch"));
    await createChannel(page, uniq("patch-here"));
    await project(page).locator(".group\\/proj").hover();
    await project(page).locator("[data-new-section]").click();
    const input = project(page).locator('[data-section-editor="create"] input');
    await input.fill("half typed");
    await patchFrom(page, other);
    await expect(row(page, other)).toHaveAttribute("data-unread", "true", { timeout: 30_000 });
    await expect(input).toBeVisible();
    await expect(input).toHaveValue("half typed");

    const name = uniq("Saved");
    await input.fill(name);
    await input.press("Enter");
    await expect(section(page, name)).toBeAttached();
    await expect(input).toBeHidden();
    await patchFrom(page, other);
    await expect(page.locator(`#sidebar-row-${other} [id^="unread-"], #sidebar-row-${other}`).first()).toBeAttached();
    await page.waitForTimeout(300);
    await expect(input).toBeHidden();
  });

  // -- Moving a channel --------------------------------------------------------

  // Bug 1: on macOS contextmenu fires on mousedown; the menu must survive the mouseup.
  test("E-M1 right-click: the row menu opens at the pointer and stays open after the button is released", async ({ page }) => {
    const ch = await createChannel(page, uniq("rc"));
    await link(page, ch).scrollIntoViewIfNeeded();
    const box = (await link(page, ch).boundingBox())!;
    await page.mouse.move(box.x + 20, box.y + box.height / 2);
    await page.mouse.down({ button: "right" });
    await page.waitForTimeout(150);
    await page.mouse.up({ button: "right" });
    await page.waitForTimeout(300);
    await expect(menu(page)).toBeVisible();
    await expect(menu(page).getByRole("menuitem", { name: "Move to section" })).toBeFocused();
    // at the pointer, not at the ⋯ button
    const m = (await menu(page).boundingBox())!;
    expect(Math.abs(m.x - (box.x + 20))).toBeLessThan(40);
  });

  test("E-M1 right-click on a section header opens the section menu", async ({ page }) => {
    await createChannel(page, uniq("rch"));
    const name = uniq("Rch");
    await newSection(page, name);
    await section(page, name).locator("[data-section-handle]").click({ button: "right", delay: 150 });
    await page.waitForTimeout(300);
    await expect(menu(page)).toBeVisible();
    await expect(menu(page).getByRole("menuitem", { name: "Rename section" })).toBeVisible();
  });

  test("E-M1..M3: the row menu moves, ✓ marks the current section, Remove from section, New section… files it", async ({ page }) => {
    const ch = await createChannel(page, uniq("mv"));
    const name = uniq("Alpha");
    await newSection(page, name);

    // no section yet: Remove from section is disabled
    await openRowMenu(page, ch);
    await menu(page).getByRole("menuitem", { name: "Move to section" }).click();
    await expect(submenu(page).getByRole("menuitem", { name: "Remove from section" })).toHaveAttribute("aria-disabled", "true");
    await page.keyboard.press("Escape");
    await page.keyboard.press("Escape");

    await moveViaMenu(page, ch, name);
    await openRowMenu(page, ch);
    await menu(page).getByRole("menuitem", { name: "Move to section" }).click();
    await expect(submenu(page).getByRole("menuitemradio", { name, exact: true })).toHaveAttribute("aria-checked", "true");
    await submenu(page).getByRole("menuitem", { name: "Remove from section" }).click();
    await expect(top(page).locator(`#sidebar-row-${ch}`)).toBeAttached();

    // New section… from the row: made first, the channel filed in it
    await openRowMenu(page, ch);
    await menu(page).getByRole("menuitem", { name: "Move to section" }).click();
    await submenu(page).getByRole("menuitem", { name: "New section…" }).click();
    const input = project(page).locator('[data-section-editor="create"] input');
    await expect(input).toBeFocused();
    const ops = uniq("Ops");
    await input.fill(ops);
    await input.press("Enter");
    await expect(section(page, ops).locator(`#sidebar-row-${ch}`)).toBeAttached();
    await expect(project(page).locator("ul[data-section-id]").first()).toHaveAttribute("data-section-name", ops);
    await expect(link(page, ch)).toBeFocused();
  });

  test("E-M9/E-M10/E-A6: the palette moves the open channel and archives it", async ({ page }) => {
    const ch = await createChannel(page, uniq("pal"));
    const name = uniq("Pal");
    await newSection(page, name);
    await gotoLive(page, `/channels/${ch}`);
    await page.keyboard.press("ControlOrMeta+k");
    await page.locator("#cmdk-input").fill("move to section");
    await page.locator("#cmdk-list [role=option]", { hasText: "Move to section" }).first().click();
    await expect(page.locator("#cmdk-list")).toContainText(name);
    await expect(page.locator("#cmdk-list")).not.toContainText("No section");
    await page.locator("#cmdk-input").fill(name);
    await page.keyboard.press("Enter");
    await expect(section(page, name).locator(`#sidebar-row-${ch}`)).toBeAttached();

    // now in a section: "No section" is offered, ✓ on the current one
    await page.keyboard.press("ControlOrMeta+k");
    await page.locator("#cmdk-input").fill("move to section");
    await page.locator("#cmdk-list [role=option]", { hasText: "Move to section" }).first().click();
    await expect(page.locator("#cmdk-list")).toContainText("No section");
    // Backspace on an empty query steps back to the commands, with the query restored
    await page.locator("#cmdk-input").fill("");
    await page.keyboard.press("Backspace");
    await expect(page.locator("#cmdk-list")).toContainText("Move to section…");
    await page.locator("#cmdk-input").fill("archive this channel");
    await expect(page.locator("#cmdk-list [role=option]").first()).toContainText("Archive this channel");
    await page.keyboard.press("Enter");
    await expect(page.locator("#archived-bar")).toBeVisible();
    await expect(toast(page)).toContainText("Archived");
    await expect(undo(page)).toBeFocused();
    await undo(page).press("Enter");
    await expect(page.locator("#archived-bar")).toBeHidden();
    await expect(section(page, name).locator(`#sidebar-row-${ch}`)).toBeAttached();
  });

  // -- Archive, Undo, unarchive ------------------------------------------------

  test("E-A1/E-A10: the row's archive button folds it away with a toast; Undo puts it back in its section", async ({ page }) => {
    const ch = await createChannel(page, uniq("arch"));
    const here = await createChannel(page, uniq("arch-here"));
    const name = uniq("Beta");
    await newSection(page, name);
    await moveViaMenu(page, ch, name);

    await row(page, ch).hover();
    await page.locator(`#sidebar-archive-${ch}`).click();
    await expect(toast(page)).toContainText(/Archived\s*#arch-/);
    await expect(archivedFold(page).locator(`#sidebar-channel-${ch}`)).toBeAttached();
    await expect(section(page, name).locator(`#sidebar-row-${ch}`)).toHaveCount(0);
    // a mouse archive leaves focus alone
    await expect(undo(page)).not.toBeFocused();
    await undo(page).click();
    await expect(toast(page)).toBeEmpty();
    await expect(section(page, name).locator(`#sidebar-row-${ch}`)).toBeAttached();
    // still on the page we were on
    expect(page.url()).toContain(here);
  });

  test("E-A2: the toast leaves after about 6 s; hovering holds it", async ({ page }) => {
    const a = await createChannel(page, uniq("t-a"));
    const b = await createChannel(page, uniq("t-b"));
    await row(page, a).hover();
    await page.locator(`#sidebar-archive-${a}`).click();
    await expect(undo(page)).toBeVisible();
    await page.mouse.move(5, 600);
    await page.waitForTimeout(5_000);
    await expect(undo(page)).toBeVisible();
    await page.waitForTimeout(2_500);
    await expect(undo(page)).toHaveCount(0);

    await row(page, b).hover();
    await page.locator(`#sidebar-archive-${b}`).click();
    await expect(undo(page)).toBeVisible();
    await page.waitForTimeout(3_000);
    await page.locator("#sidebar-undo-toast-alert").hover();
    await page.waitForTimeout(5_000);
    await expect(undo(page)).toBeVisible();
    await page.mouse.move(5, 600);
    await page.waitForTimeout(6_800);
    await expect(undo(page)).toHaveCount(0);
  });

  test("E-A3/E-A4/E-A5: keyboard archive focuses Undo; a newer archive replaces the toast and Undo applies to it", async ({ page }) => {
    const x = await createChannel(page, uniq("x"));
    const y = await createChannel(page, uniq("y"));
    await createChannel(page, uniq("z-here"));

    await link(page, x).focus();
    await page.keyboard.press("Shift+F10");
    await expect(menu(page)).toBeVisible();
    await page.keyboard.press("End");
    await expect(menu(page).getByRole("menuitem", { name: "Archive channel" })).toBeFocused();
    await page.keyboard.press("Enter");
    await expect(undo(page)).toBeFocused();
    // the nav refresh landed in the same moment; the toast is still there a second later
    await page.waitForTimeout(1_000);
    await expect(undo(page)).toBeVisible();

    await row(page, y).hover();
    await page.locator(`#sidebar-archive-${y}`).click();
    await expect(toast(page)).toContainText("#y-");
    await undo(page).click();
    await expect(top(page).locator(`#sidebar-row-${y}`)).toBeAttached();
    await expect(archivedFold(page).locator(`#sidebar-channel-${x}`)).toBeAttached();
  });

  test("E-A7/E-A8: Details archives at once, no confirm; Reopen from the fold returns it to its section without the bar", async ({ page }) => {
    const ch = await createChannel(page, uniq("det"));
    const name = uniq("Gamma");
    await newSection(page, name);
    await moveViaMenu(page, ch, name);
    await completeTask(page);
    await openDetails(page);
    await page.locator("#archive-channel").click();
    await expect(page.locator("#canopy-confirm")).toBeHidden();
    await expect(page.locator("#archived-bar")).toBeVisible();
    await expect(toast(page)).toContainText("Archived");
    // the open channel stays in its section while archived
    await expect(section(page, name).locator(`#sidebar-row-${ch}`)).toBeAttached();

    await page.locator("#archived-bar button", { hasText: "Reopen" }).click();
    await expect(page.locator("#archived-bar")).toBeHidden();
    await expect(page.locator("#done-bar")).toBeHidden();
    await expect(page.locator(`#sidebar-done-${ch}`)).toHaveCount(0);
    await expect(section(page, name).locator(`#sidebar-row-${ch}`)).toBeAttached();
  });

  // -- The Task done bar -------------------------------------------------------

  test("E-O1: a completed task shows the bar and the ✓; Keep open hides both for good", async ({ page }) => {
    const ch = await createChannel(page, uniq("done"));
    await completeTask(page, "Write the release notes");
    await expect(page.locator("#done-bar")).toContainText("Task done.");
    // Bug 6: the user completed it, so the bar credits them, not the owner (@backend)
    await expect(page.locator("#done-bar")).toContainText("You marked “Write the release notes” complete");
    await expect(page.locator("#done-bar")).not.toContainText("@backend");
    await expect(page.locator(`#sidebar-done-${ch}`)).toBeVisible();
    // hover hides the badges under the row actions
    await row(page, ch).hover();
    await expect(page.locator(`#sidebar-done-${ch}`)).toBeHidden();
    await expect(page.locator(`#sidebar-archive-${ch}`)).toBeVisible();

    await page.locator("#done-bar-keep").click();
    await expect(page.locator("#done-bar")).toBeHidden();
    await expect(page.locator(`#sidebar-done-${ch}`)).toHaveCount(0);
    await reload(page);
    await expect(page.locator("#done-bar")).toBeHidden();
  });

  test("E-O2: Archive in the bar, then Undo: the bar comes back (Undo restores what was there)", async ({ page }) => {
    const ch = await createChannel(page, uniq("done-undo"));
    await completeTask(page);
    await page.locator("#done-bar-archive").click();
    await expect(page.locator("#archived-bar")).toBeVisible();
    await expect(page.locator("#done-bar")).toBeHidden();
    await undo(page).click();
    await expect(page.locator("#archived-bar")).toBeHidden();
    await expect(page.locator("#done-bar")).toBeVisible();
    await expect(page.locator(`#sidebar-done-${ch}`)).toBeAttached();
  });

  test("E-O4: archived mid-task and reopened from the header, the offer still comes when the task completes", async ({ page }) => {
    const ch = await createChannel(page, uniq("mid"));
    await setTask(page, "Half way", "working");
    await expect(page.locator("#done-bar")).toBeHidden();
    await openDetails(page);
    await page.locator("#archive-channel").click();
    await expect(page.locator("#archived-bar")).toBeVisible();
    await page.locator("#archived-bar button", { hasText: "Reopen" }).click();
    await expect(page.locator("#archived-bar")).toBeHidden();
    await expect(page.locator("#done-bar")).toBeHidden();

    await completeTask(page, "Half way");
    await expect(page.locator("#done-bar")).toContainText("“Half way”");
    await expect(page.locator(`#sidebar-done-${ch}`)).toBeVisible();
    await reload(page);
    await expect(page.locator("#done-bar")).toBeVisible();
  });

  // -- Keyboard ----------------------------------------------------------------

  test("E-K1..K7, K9..K11: Shift+F10 opens the row menu; arrows, submenu, type-ahead, Esc and Tab", async ({ page, context }) => {
    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    const a = await createChannel(page, uniq("k-a"));
    const b = await createChannel(page, uniq("k-b"));
    const name = uniq("Keys");
    const sid = await newSection(page, name);

    await link(page, a).focus();
    await expect(link(page, a)).toBeFocused();
    await page.keyboard.press("Shift+F10");
    await expect(menu(page)).toBeVisible();
    await expect(menu(page)).toHaveAttribute("role", "menu");
    await expect(page.locator(`#sidebar-row-menu-${a}`)).toHaveAttribute("aria-expanded", "true");
    const items = menu(page).locator('[role^="menuitem"]');
    await expect(items.first()).toBeFocused();
    await expect(items.first()).toHaveText(/Move to section/);

    // ↑ from the first wraps to the last; Home goes back
    await page.keyboard.press("ArrowUp");
    await expect(menu(page).getByRole("menuitem", { name: "Archive channel" })).toBeFocused();
    await page.keyboard.press("Home");
    await expect(items.first()).toBeFocused();
    // Mark as read is disabled but focusable
    await page.keyboard.press("ArrowDown");
    await expect(menu(page).getByRole("menuitem", { name: "Mark as read" })).toBeFocused();
    await expect(menu(page).getByRole("menuitem", { name: "Mark as read" })).toHaveAttribute("aria-disabled", "true");
    // type-ahead
    await page.keyboard.press("a");
    await expect(menu(page).getByRole("menuitem", { name: "Archive channel" })).toBeFocused();
    await page.keyboard.press("Home");
    // → opens the submenu, ← closes it back to its item
    await page.keyboard.press("ArrowRight");
    await expect(submenu(page)).toBeVisible();
    await expect(submenu(page).getByRole("menuitemradio", { name, exact: true })).toBeFocused();
    await page.keyboard.press("ArrowLeft");
    await expect(submenu(page)).toBeHidden();
    await expect(items.first()).toBeFocused();
    // Enter into it and choose
    await page.keyboard.press("Enter");
    await expect(submenu(page)).toBeVisible();
    await page.keyboard.press("Enter");
    await expect(section(page, name).locator(`#sidebar-row-${a}`)).toBeAttached();
    await expect(link(page, a)).toBeFocused();

    // Esc closes and gives focus back to the row
    await page.keyboard.press("Shift+F10");
    await expect(menu(page)).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(menu(page)).toBeHidden();
    await expect(link(page, a)).toBeFocused();
    await expect(page.locator(`#sidebar-row-menu-${a}`)).toHaveAttribute("aria-expanded", "false");
    // Tab closes it
    await page.keyboard.press("Shift+F10");
    await page.keyboard.press("Tab");
    await expect(menu(page)).toBeHidden();

    // ContextMenu key
    await link(page, a).focus();
    await page.keyboard.press("ContextMenu");
    await expect(menu(page)).toBeVisible();
    await page.keyboard.press("Escape");

    // Copy link
    await page.keyboard.press("Shift+F10");
    await menu(page).getByRole("menuitem", { name: "Copy link" }).focus();
    await page.keyboard.press("Enter");
    await expect(menu(page)).toContainText("Copied");
    await expect(menu(page)).toBeHidden();
    const copied = await page.evaluate(() => navigator.clipboard.readText());
    expect(copied).toMatch(new RegExp(`^http://127\\.0\\.0\\.1:\\d+/channels/${a}$`));

    // the section header: Shift+F10 opens its menu; Rename then Esc returns to it
    await page.locator(`#sidebar-section-toggle-${sid}`).focus();
    await page.keyboard.press("Shift+F10");
    await expect(menu(page).getByRole("menuitem", { name: "Rename section" })).toBeFocused();
    await page.keyboard.press("Enter");
    await expect(page.locator(`#sidebar-rename-section-${sid} input`)).toBeFocused();
    await page.keyboard.press("Escape");
    await expect(page.locator(`#sidebar-rename-section-${sid} input`)).toBeHidden();
    await expect(page.locator(`#sidebar-section-toggle-${sid}`)).toBeFocused();

    // one Tab stop per row: the row buttons are out of the tab order
    await expect(page.locator(`#sidebar-archive-${b}`)).toHaveAttribute("tabindex", "-1");
    await expect(page.locator(`#sidebar-row-menu-${b}`)).toHaveAttribute("tabindex", "-1");

    // Mark as read on an unread row
    await patchFrom(page, b);
    await gotoLive(page, `/channels/${a}`);
    await expect(row(page, b)).toHaveAttribute("data-unread", "true", { timeout: 30_000 });
    await link(page, b).focus();
    await page.keyboard.press("Shift+F10");
    await menu(page).getByRole("menuitem", { name: "Mark as read" }).click();
    await expect(row(page, b)).toHaveAttribute("data-unread", "false");
  });

  test("E-K8: an open menu survives an unread patch, aria-expanded included", async ({ page }) => {
    const a = await createChannel(page, uniq("k8"));
    const other = await createChannel(page, uniq("k8-o"));
    await gotoLive(page, `/channels/${a}`);
    await row(page, a).hover();
    await page.locator(`#sidebar-row-menu-${a}`).click();
    await expect(menu(page)).toBeVisible();
    await expect(page.locator(`#sidebar-row-menu-${a}`)).toHaveAttribute("aria-expanded", "true");
    // the agent's reply lands unread once the posting tab has closed
    await patchFrom(page, other);
    await expect(row(page, other)).toHaveAttribute("data-unread", "true", { timeout: 30_000 });
    await expect(menu(page)).toBeVisible();
    await expect(page.locator(`#sidebar-row-menu-${a}`)).toHaveAttribute("aria-expanded", "true");
  });

  // -- Two tabs ----------------------------------------------------------------

  test("W1..W4, W6, W10: a second tab follows sections, moves, archives and Keep open", async ({ page, context }) => {
    const ch = await createChannel(page, uniq("w"));
    const b = await context.newPage();
    await gotoLive(b, `/channels/${ch}`);

    const name = uniq("Wide");
    const id = await newSection(page, name);
    await expect(section(b, name)).toBeAttached();
    await moveViaMenu(page, ch, name);
    await expect(section(b, name).locator(`#sidebar-row-${ch}`)).toBeAttached();
    await page.locator(`#sidebar-section-toggle-${id}`).click();
    await expect(b.locator(`#sidebar-section-toggle-${id}`)).toHaveAttribute("aria-expanded", "false");
    await page.locator(`#sidebar-section-toggle-${id}`).click();
    await expect(b.locator(`#sidebar-section-toggle-${id}`)).toHaveAttribute("aria-expanded", "true");

    // the task completes in A: B, on the same channel, gets the bar; Keep open in A clears it in B
    await completeTask(page);
    await expect(b.locator("#done-bar")).toBeVisible();
    await expect(b.locator(`#sidebar-done-${ch}`)).toBeVisible();
    await page.locator("#done-bar-keep").click();
    await expect(b.locator("#done-bar")).toBeHidden();
    await expect(b.locator(`#sidebar-done-${ch}`)).toHaveCount(0);

    // archive in A: B, viewing it, stays and sees the archived bar; only A has the toast
    await row(page, ch).hover();
    await page.locator(`#sidebar-archive-${ch}`).click();
    await expect(b.locator("#archived-bar")).toBeVisible();
    await expect(undo(b)).toHaveCount(0);
    await undo(page).click();
    await expect(b.locator("#archived-bar")).toBeHidden();

    // A deletes the section: B's channel goes to the top
    await openSectionMenu(page, name);
    await menu(page).getByRole("menuitem", { name: "Delete section" }).click();
    await expect(section(b, name)).toHaveCount(0);
    await expect(top(b).locator(`#sidebar-row-${ch}`)).toBeAttached();
    await b.close();
  });

  test("W8: a section menu left open in another tab answers 'That section no longer exists.'", async ({ page, context }) => {
    await createChannel(page, uniq("stale"));
    const name = uniq("Stale");
    const keep = uniq("Keep");
    await newSection(page, keep);
    await newSection(page, name); // first, so Move down is enabled
    const b = await context.newPage();
    await gotoLive(b, "/channels/new");
    await openSectionMenu(b, name);
    await openSectionMenu(page, name);
    await menu(page).getByRole("menuitem", { name: "Delete section" }).click();
    await expect(section(b, name)).toHaveCount(0);
    await expect(menu(b)).toBeVisible();
    await menu(b).getByRole("menuitem", { name: "Move down" }).click();
    await expect(b.locator("#flash-error")).toContainText("That section no longer exists.");
    await b.close();
  });

  // -- Start page --------------------------------------------------------------

  test("E-T1: Start page, New section…: the run's new channel lands in a new last section", async ({ page }) => {
    await createChannel(page, uniq("seed"));
    await gotoLive(page, "/playbooks");
    const href = await page.locator("#playbooks li", { hasText: "bug-fix" }).locator('a[href$="/start"]').first().getAttribute("href");
    await gotoLive(page, href!);
    const chName = uniq("launch");
    await page.locator("#start-channel-name").fill(chName);
    await page.locator("#start-section").selectOption({ label: "New section…" });
    const secName = uniq("Launches");
    await page.locator("#start-section-new").fill(secName);
    const lead = page.locator("#start-coordinator");
    const value = await lead.locator("option", { hasText: "@backend" }).first().getAttribute("value");
    await lead.selectOption(value!);
    await page.locator("#start-run-form [type=submit]").click();
    await expect(page).toHaveURL(/\/channels\/ch_/);
    await expect(section(page, secName)).toBeAttached();
    await expect(section(page, secName)).toContainText(chName);
    await expect(project(page).locator("ul[data-section-id]").last()).toHaveAttribute("data-section-name", secName);
  });
});

// -- Touch: the drawer on a phone ---------------------------------------------

test.describe("sidebar sections on a touch screen", () => {
  test.use({ hasTouch: true, isMobile: true, viewport: { width: 390, height: 844 } });

  test("E-P1..P6: ⋯ in the row's flow, + and section ⋯ always shown, menu works, no drag, no contextmenu", async ({ page }) => {
    const ch = await createChannel(page, uniq("touch"));
    await createChannel(page, uniq("touch-2"));
    await gotoLive(page, "/channels/new");
    expect(await page.evaluate(() => matchMedia("(pointer: coarse)").matches)).toBe(true);
    await drawerOpener(page).click();
    await expect(drawer(page)).toBeChecked();

    const more = page.locator(`#sidebar-row-menu-${ch}`);
    await expect(more).toBeVisible();
    await expect(page.locator(`#sidebar-archive-${ch}`)).toBeHidden();
    await expect(project(page).locator("[data-new-section]")).toHaveCSS("opacity", "1");
    const mb = await more.boundingBox();
    expect(mb!.width).toBeGreaterThanOrEqual(32);
    expect(mb!.height).toBeGreaterThanOrEqual(32);

    // a section via the always-shown +
    await project(page).locator("[data-new-section]").tap();
    const input = project(page).locator('[data-section-editor="create"] input');
    const name = uniq("Thumb");
    await input.fill(name);
    await input.press("Enter");
    await expect(section(page, name)).toBeAttached();
    // Bug 5: the drawer stays open after every sidebar action (the nav refresh mustn't reset it)
    await page.waitForTimeout(500);
    await expect(drawer(page), "drawer open after New section").toBeChecked();
    await expect(section(page, name).locator("[data-menu]")).toHaveCSS("opacity", "1");

    // collapse and expand: still open
    const sid = (await section(page, name).getAttribute("data-section-id"))!;
    await page.locator(`#sidebar-section-toggle-${sid}`).tap();
    await expect(page.locator(`#sidebar-section-toggle-${sid}`)).toHaveAttribute("aria-expanded", "false");
    await page.waitForTimeout(500);
    await expect(drawer(page), "drawer open after collapse").toBeChecked();
    await page.locator(`#sidebar-section-toggle-${sid}`).tap();
    await expect(page.locator(`#sidebar-section-toggle-${sid}`)).toHaveAttribute("aria-expanded", "true");

    await more.tap();
    await expect(menu(page)).toBeVisible();
    const item = menu(page).getByRole("menuitem", { name: "Move to section" });
    expect((await item.boundingBox())!.height).toBeGreaterThanOrEqual(40);
    await item.tap();
    await submenu(page).getByRole("menuitemradio", { name, exact: true }).tap();
    await expect(section(page, name).locator(`#sidebar-row-${ch}`)).toBeAttached();
    await page.waitForTimeout(500);
    await expect(drawer(page), "drawer open after Move to section").toBeChecked();

    // no contextmenu binding
    await link(page, ch).dispatchEvent("contextmenu");
    await expect(menu(page)).toBeHidden();
    // no drag on coarse pointers: no Sortable instance on the zones
    const sortable = await page.evaluate(() =>
      [...document.querySelectorAll("ul[data-section-id], ul[data-drop-section]")].some((el) =>
        Object.keys(el).some((k) => k.startsWith("Sortable")),
      ),
    );
    expect(sortable).toBe(false);
  });
});
