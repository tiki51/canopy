// Shared files: upload and paste from the composer, cards in the timeline, an
// agent publishing a report through canopy_document_share, and the library.
import { test, expect } from "@playwright/test";
import { createChannel, send, timeline } from "./helpers";
import path from "node:path";

const png = path.resolve("../test/support/files/red.png");
const md = path.resolve("../test/support/files/report.md");

test("the user uploads and pastes files; they render as cards", async ({ page }) => {
  await createChannel(page);
  await page.locator("#upload-form input[type=file]").setInputFiles([png, md]);
  await expect(page.locator("#composer-files")).toContainText("red.png");
  await expect(page.locator("#composer-files")).toContainText("report.md");

  await send(page, "Here are the screenshot and the analysis. No need to reply.");
  const cards = timeline(page).locator('[id^="attachment-"]');
  await expect(cards).toHaveCount(2);
  await expect(cards.filter({ has: page.locator("img") })).toHaveCount(1);
  await expect(timeline(page)).toContainText("report.md");
  await expect(page.locator("#composer-files")).toBeHidden();

  // the image is served inline with strict headers
  const src = await timeline(page).locator('[id^="attachment-"] img').first().getAttribute("src");
  const response = await page.request.get(src!);
  expect(response.status()).toBe(200);
  expect(response.headers()["content-type"]).toBe("image/png");
  expect(response.headers()["content-security-policy"]).toBe("sandbox");

  // a paste of a file lands in the composer as an upload
  await page.locator("#composer-input").evaluate((el) => {
    const file = new File([new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10])], "image.png", { type: "image/png" });
    const dt = new DataTransfer();
    dt.items.add(file);
    el.dispatchEvent(new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true }));
  });
  await expect(page.locator("#composer-files")).toContainText(/paste-\d{8}-\d{6}\.png/);
  await page.locator("#composer-files button").first().click();
  await expect(page.locator("#composer-files")).toBeHidden();
});

test("an agent publishes a report and the library shares it into another channel", async ({ page }) => {
  await createChannel(page);
  await send(page, "Please publish a report on the retry race.");
  const card = timeline(page).locator('[id^="attachment-"][data-kind="text"]');
  await expect(card).toContainText("retry-report.md", { timeout: 30_000 });
  await expect(timeline(page)).toContainText("Report attached.");

  const other = await createChannel(page);
  await page.locator("#composer-library").click();
  await page.locator("#library-search input").fill("retry");
  await page.locator('[id^="library-doc_"]').first().click();
  await expect(page.locator('[id^="picked-doc_"]')).toHaveCount(1);
  await send(page, "Sharing the report here too. No need to reply.");
  await expect(timeline(page).locator('[id^="attachment-"][data-kind="text"]')).toContainText("retry-report.md");

  await page.goto("/files");
  const row = page.locator('#files li', { hasText: "retry-report.md" });
  await expect(row).toContainText("@backend");
  await expect(row.locator(`a[href="/channels/${other}"]`)).toBeVisible();
});
