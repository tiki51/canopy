// The file viewer: a message's files open in a lightbox over the channel
// (`?file=…&in=…`), ← → move through them, Esc closes and gives focus back to
// the tile, Download downloads, and an open thread stays open underneath.
import { test, expect, Page } from "@playwright/test";
import { createChannel, send, timeline } from "./helpers";
import fs from "node:fs";
import path from "node:path";

const png = path.resolve("../test/support/files/red.png");
const md = path.resolve("../test/support/files/report.md");
const py = path.resolve("../test/support/files/retry.py");

// Writes `files` (name => contents) into the test's own output directory.
function scratch(files: Record<string, string | Buffer>): string[] {
  const dir = test.info().outputPath("files");
  fs.mkdirSync(dir, { recursive: true });
  return Object.entries(files).map(([name, contents]) => {
    const file = path.join(dir, name);
    fs.writeFileSync(file, contents);
    return file;
  });
}

async function share(page: Page, files: string[], text: string) {
  await page.locator("#upload-form input[type=file]").setInputFiles(files);
  await expect(page.locator("#composer-files")).toContainText(path.basename(files[files.length - 1]));
  await send(page, text);
}

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

  // Back closes the viewer too (opening it pushed its URL); Source is remembered
  await tiles.last().click();
  await expect(page.locator("#file-viewer-source")).toBeVisible();
  await page.goBack();
  await expect(viewer).toHaveCount(0);
  await expect(page).not.toHaveURL(/file=/);
});

test("double-click zooms every image of a message, not every other one", async ({ page }) => {
  await createChannel(page);
  const red = fs.readFileSync(png);
  await share(page, scratch({ "one.png": red, "two.png": red, "three.png": red }), "Three charts. No need to reply.");

  const tiles = timeline(page).locator("[data-viewer-link]");
  await expect(tiles).toHaveCount(3);
  await tiles.first().click();

  const image = page.locator("#file-viewer-image");
  const label = page.locator("#file-viewer-zoom-label");
  const seen: string[] = [];
  for (const position of ["1 of 3", "2 of 3", "3 of 3"]) {
    await expect(page.locator("#file-viewer-position")).toHaveText(position);
    seen.push((await page.locator("#file-viewer-name").innerText()).trim());
    await expect(image).toHaveJSProperty("complete", true);
    await expect(label).toHaveText("Fit");
    await image.dblclick();
    await expect(label).toHaveText("100%");
    await image.dblclick();
    await expect(label).toHaveText("Fit");
    await page.keyboard.press("ArrowRight");
  }
  expect(seen.sort()).toEqual(["one.png", "three.png", "two.png"]);
});

test("a PDF opens in a frame its viewer can render in", async ({ page }) => {
  // the smallest well-formed PDF: one blank page
  const pdf = [
    "%PDF-1.4",
    "1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj",
    "2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj",
    "3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >> endobj",
    "trailer << /Root 1 0 R >>",
    "%%EOF",
    "",
  ].join("\n");
  await createChannel(page);
  await share(page, scratch({ "spec.pdf": pdf }), "The spec. No need to reply.");

  const frame = page.locator("#file-viewer-pdf");
  const response = page.waitForResponse((res) => /\/files\/doc_[^/]+\/spec\.pdf$/.test(res.url()));
  await timeline(page).locator("[data-viewer-link]").click();
  await expect(frame).toBeVisible();

  // a sandboxed response is one Chrome's PDF viewer refuses to show
  const headers = (await response).headers();
  expect(headers["content-type"]).toBe("application/pdf");
  expect(headers["content-disposition"]).toMatch(/^inline/);
  expect(headers["x-content-type-options"]).toBe("nosniff");
  expect(headers["content-security-policy"] || "").not.toContain("sandbox");
});

test("→ scrolls a long unwrapped line instead of moving on", async ({ page }) => {
  await createChannel(page);
  const files = scratch({ "wide.log": "x".repeat(4_000) + "\n", "short.log": "ok\n" });
  await share(page, files, "Two logs. No need to reply.");

  await timeline(page).locator('[data-viewer-link][aria-label="Open wide.log"]').click();
  const name = page.locator("#file-viewer-name");
  await expect(name).toHaveText("wide.log");
  const body = page.locator("#file-viewer .doc-body");
  // toward the other file, whichever side it is on
  const first = (await page.locator("#file-viewer-position").innerText()).startsWith("1 ");
  const key = first ? "ArrowRight" : "ArrowLeft";
  if (!first) await body.evaluate((el) => (el.scrollLeft = el.scrollWidth));
  const start = await body.evaluate((el) => el.scrollLeft);

  await page.keyboard.press(key);
  await expect.poll(() => body.evaluate((el) => el.scrollLeft)).not.toBe(start);
  await expect(name).toHaveText("wide.log");

  // wrapped, nothing scrolls sideways and the key moves on
  await page.locator("#file-viewer-wrap").click();
  await page.locator("#file-viewer").focus();
  await page.keyboard.press(key);
  await expect(name).toHaveText("short.log");
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

test("Copy copies the exact bytes: CRLFs and all", async ({ page, context }) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await createChannel(page);
  const text = "line one\r\nline two\r\n\ttabbed <b>&amp;</b>\r\n";
  await share(page, scratch({ "windows.txt": text }), "A CRLF file. No need to reply.");

  await timeline(page).locator("[data-viewer-link]").click();
  await expect(page.locator("#file-viewer-name")).toHaveText("windows.txt");
  await page.evaluate(() => navigator.clipboard.writeText(""));
  await page.locator("#file-viewer-copy").click();
  await expect(page.locator("#file-viewer-copy [data-copy-label]")).toHaveText("Copied");
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(text);
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
  // the tile's link has only file and in; the server lays them over the thread
  await expect(page).toHaveURL(/[?&]thread=msg_/);
  await expect(page).toHaveURL(/[?&]file=doc_/);
  // one file: no arrows, no strip
  await expect(page.locator("#file-viewer-strip")).toHaveCount(0);

  await page.locator("#file-viewer-close").click();
  await expect(page.locator("#file-viewer")).toHaveCount(0);
  await expect(page.locator("#thread-panel")).toBeVisible();
  await expect(page).toHaveURL(/thread=msg_/);
});
