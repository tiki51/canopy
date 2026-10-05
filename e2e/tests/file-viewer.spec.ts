// The file viewer: a message's files open in a lightbox over the channel
// (`?file=…&in=…`), ← → move through them, Esc closes and gives focus back to
// the tile, Download downloads, and an open thread stays open underneath.
import { test, expect } from "@playwright/test";
import { createChannel, send, timeline } from "./helpers";
import fs from "node:fs";
import path from "node:path";

const png = path.resolve("../test/support/files/red.png");
const md = path.resolve("../test/support/files/report.md");
const py = path.resolve("../test/support/files/retry.py");

test("open an image, browse to the Markdown, close with Esc", async ({ page }) => {
  await createChannel(page);
  await page.locator("#upload-form input[type=file]").setInputFiles([md, png]);
  await expect(page.locator("#composer-files")).toContainText("report.md");
  await send(page, "The screenshot and the analysis. No need to reply.");

  // images come first in the message, as in the viewer
  const tiles = timeline(page).locator("[data-viewer-link]");
  await expect(tiles).toHaveCount(2);
  await expect(tiles.first()).toHaveAttribute("data-kind", "image");

  const imageTile = tiles.first();
  await imageTile.focus();
  await page.keyboard.press("Enter");

  const viewer = page.locator("#file-viewer");
  await expect(viewer).toBeVisible();
  await expect(page).toHaveURL(/[?&]file=doc_.*&in=msg_/);
  expect(await viewer.evaluate((el) => el.matches(":modal"))).toBe(true);
  await expect(viewer).toBeFocused();
  await expect(page.locator("#file-viewer-name")).toHaveText("red.png");
  await expect(page.locator("#file-viewer-meta")).toContainText(/PNG · .* × /);

  await page.keyboard.press("ArrowRight");
  await expect(page.locator("#file-viewer-name")).toHaveText("report.md");
  await expect(page.locator("#file-viewer-preview")).toBeVisible();
  await expect(page.locator("#file-viewer-next")).toHaveAttribute("aria-disabled", "true");

  // Source is remembered for the next Markdown file
  await page.locator("#file-viewer-mode-source").click();
  await expect(page.locator("#file-viewer-source")).toBeVisible();
  await expect(page.locator("#file-viewer-preview")).toBeHidden();

  const download = page.waitForEvent("download");
  await page.locator("#file-viewer-download").click();
  expect((await download).suggestedFilename()).toBe("report.md");

  await page.keyboard.press("Escape");
  await expect(viewer).toHaveCount(0);
  await expect(page).not.toHaveURL(/file=/);
  await expect(imageTile).toBeFocused();

  // closing went Back, so Forward opens the file again (the arrows replaced
  // the entry, so it is the last one shown); this Close patches
  await page.goForward();
  await expect(page.locator("#file-viewer-name")).toHaveText("report.md");
  await expect(page.locator("#file-viewer-source")).toBeVisible();
  await page.locator("#file-viewer-close").click();
  await expect(viewer).toHaveCount(0);
  await expect(page).not.toHaveURL(/file=/);
});

test("Copy copies the file that is showing, after ← → too", async ({ page, context }) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await createChannel(page);
  await page.locator("#upload-form input[type=file]").setInputFiles([md, py]);
  await expect(page.locator("#composer-files")).toContainText("retry.py");
  await send(page, "The note and the module. No need to reply.");

  const tiles = timeline(page).locator("[data-viewer-link]");
  await expect(tiles).toHaveCount(2);
  await tiles.first().click();
  const name = page.locator("#file-viewer-name");
  await expect(name).not.toBeEmpty();

  const copy = async () => {
    await page.evaluate(() => navigator.clipboard.writeText(""));
    await page.locator("#file-viewer-copy").click();
    await expect(page.locator("#file-viewer-copy [data-copy-label]")).toHaveText("Copied");
    return page.evaluate(() => navigator.clipboard.readText());
  };
  const contents = (file: string) => fs.readFileSync(file === "retry.py" ? py : md, "utf8");

  const first = await name.innerText();
  expect(await copy()).toBe(contents(first));
  await page.keyboard.press("ArrowRight");
  await expect(name).not.toHaveText(first);
  expect(await copy()).toBe(contents(await name.innerText()));
});

test("a file opened from the feed keeps the thread panel open", async ({ page }) => {
  await createChannel(page);
  await page.locator("#upload-form input[type=file]").setInputFiles([png]);
  await expect(page.locator("#composer-files")).toContainText("red.png");
  await send(page, "One chart. No need to reply.");

  const message = timeline(page).locator("article", { hasText: "One chart." });
  await message.hover();
  await message.locator('[id^="reply-"]').click();
  await expect(page.locator("#thread-panel")).toBeVisible();
  await expect(page).toHaveURL(/thread=msg_/);

  await message.locator("[data-viewer-link]").click();
  await expect(page.locator("#file-viewer")).toBeVisible();
  await expect(page).toHaveURL(/thread=msg_.*file=doc_/);
  // one file: no arrows, no strip
  await expect(page.locator("#file-viewer-strip")).toHaveCount(0);

  await page.locator("#file-viewer-close").click();
  await expect(page.locator("#file-viewer")).toHaveCount(0);
  await expect(page.locator("#thread-panel")).toBeVisible();
  await expect(page).toHaveURL(/thread=msg_/);
});
