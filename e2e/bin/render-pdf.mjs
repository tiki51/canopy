// Prints an HTML file to PDF with Playwright's Chromium.
// Run from e2e/: node bin/render-pdf.mjs <in.html> <out.pdf>
import { chromium } from "@playwright/test";
import { pathToFileURL } from "node:url";
import path from "node:path";
const [input, output] = process.argv.slice(2);
const browser = await chromium.launch();
const page = await browser.newPage();
await page.goto(pathToFileURL(path.resolve(input)).href, { waitUntil: "networkidle" });
await page.pdf({ path: output, format: "A4", printBackground: true, displayHeaderFooter: true,
  headerTemplate: "<span></span>",
  footerTemplate: '<div style="font-size:8px;color:#888;width:100%;text-align:center;">Canopy user guide · <span class="pageNumber"></span> / <span class="totalPages"></span></div>',
  margin: { top: "18mm", bottom: "18mm", left: "16mm", right: "16mm" } });
await browser.close();
console.log("wrote", output);
