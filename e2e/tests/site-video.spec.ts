// Records the story run for the canopy_site homepage (design review §9.2): one
// session at 1032×900, 2x, dark, no cursor (the geometry of the narrow site
// stills, so the conversation pane is 720 CSS px wide and its text stays ≥11px in
// the homepage's story frame), and two cuts from it, each as WebM and MP4 with a
// poster frame, written to canopy_site/public/images:
//
//   story-02-working.{webm,mp4} + -poster.jpg   6–8s: the live card goes researching → building → testing,
//                                               cropped to the pane at 4:3; the poster is its last frame
//   full-run.{webm,mp4} + -poster.jpg            the whole run, message to review; the poster is the
//                                               root cause and delegation, with @backend researching
//
// Only runs when SITE_VIDEO=1, and needs ffmpeg with libx264 and libvpx-vp9
// (on PATH, or FFMPEG=/path/to/ffmpeg):
//
//   SITE_VIDEO=1 CANOPY_SEED=e2e/bin/seed-acme.exs FAKE_TURN_DELAY_MS=2500 npx playwright test site-video
//
// Frames come from Chromium's screencast rather than Playwright's recordVideo:
// recordVideo ignores deviceScaleFactor (it draws a 1x page in the corner of
// a 2x canvas) and encodes at about 1 Mbit/s, which blurs UI text. The
// screencast only delivers device pixels when the browser itself runs at 2x,
// hence --force-device-scale-factor and no emulated viewport.
import { test, expect } from "@playwright/test";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { dismissFlash, mediaDir, park, prepare } from "./site-helpers";

const enabled = process.env.SITE_VIDEO === "1" && process.env.CANOPY_SEED !== undefined;
const ffmpeg = process.env.FFMPEG || "ffmpeg";

// Top level: launch options can't be set inside a describe (they need their own worker).
test.use({
  viewport: null,
  launchOptions: { args: ["--force-device-scale-factor=2", "--window-size=1032,900"] },
});

test.describe("recording for canopy_site", () => {
  test.skip(!enabled, "set SITE_VIDEO=1 and CANOPY_SEED=e2e/bin/seed-acme.exs to record");

  test("record the story run", async ({ page }, info) => {
    test.setTimeout(300_000);
    await prepare(page);
    expect(await page.evaluate(() => [innerWidth, innerHeight, devicePixelRatio])).toEqual([1032, 900, 2]);

    // Set up off camera: the channel, as the story's first step would have it.
    await page.goto("/channels/new");
    await page.getByLabel("Repository").selectOption({ label: "acme-billing" });
    await page.getByLabel("Name (slug, shown as #name)").fill("payment-retries");
    await page.getByLabel("Topic").fill("Invoices are occasionally charged twice");
    const finops = page.locator("label", { hasText: "@finops" }).first();
    if (await finops.locator("input").isChecked()) await finops.click();
    const owner = page.getByLabel("Initial owner");
    await owner.selectOption((await owner.locator("option", { hasText: "backend" }).first().getAttribute("value"))!);
    await page.getByLabel(/Spend limit/).fill("5");
    await page.locator("#create-channel").click();
    await expect(page).toHaveURL(/\/channels\/ch_/);
    await dismissFlash(page);
    const backend = (await page
      .locator('#sidebar a[href^="/agents/"]', { hasText: "@backend" })
      .first()
      .getAttribute("href"))!.split("/agents/")[1];
    await park(page);

    // -- Record ------------------------------------------------------------------------
    const framesDir = info.outputPath("frames");
    fs.mkdirSync(framesDir, { recursive: true });
    const frames: { file: string; t: number }[] = [];
    const cdp = await page.context().newCDPSession(page);
    cdp.on("Page.screencastFrame", async ({ data, metadata, sessionId }) => {
      const file = path.join(framesDir, `${String(frames.length).padStart(5, "0")}.jpg`);
      fs.writeFileSync(file, Buffer.from(data, "base64"));
      frames.push({ file, t: metadata.timestamp! });
      await cdp.send("Page.screencastFrameAck", { sessionId }).catch(() => {});
    });
    // Full device size (2064×1800): a smaller cap scales frames down, breaking the crop and even dimensions.
    await cdp.send("Page.startScreencast", { format: "jpeg", quality: 95, maxWidth: 2064, maxHeight: 1800 });
    const now = () => Date.now() / 1000;
    await page.waitForTimeout(1200);
    const start = now();

    const input = page.locator("#composer-input");
    await input.click();
    await input.pressSequentially(
      "Invoices are occasionally charged twice after a failed webhook. Find the root cause and fix it, then hand it to review.",
      { delay: 18 },
    );
    await input.press("Enter");
    await park(page);

    // @backend reads, then delegates; open its live card so the tools show.
    const card = page.locator(`#telemetry-${backend}`);
    await expect(card).toBeVisible({ timeout: 30_000 });
    await page.locator(`#telemetry-toggle-${backend}`).click();
    await park(page);

    // @researcher reports back; @backend resumes and builds the fix.
    await expect(page.locator("#timeline")).toContainText("enqueue-paths.md", { timeout: 60_000 });
    await expect(card).toContainText("is researching", { timeout: 60_000 });
    const researching = now();
    if (!(await card.evaluate((el) => (el as HTMLDetailsElement).open))) {
      await page.locator(`#telemetry-toggle-${backend}`).click();
      await park(page);
    }
    await expect(card).toContainText("is building", { timeout: 30_000 });
    // The edit to payments.py asks first (acme's @backend runs in default mode); approve it.
    const perm = page.locator('section[id^="permission-"]').first();
    await expect(perm).toContainText("claim_charge", { timeout: 30_000 });
    await page.waitForTimeout(1200);
    await page.locator('[id^="permission-"][id$="-always"]').first().click();
    await expect(perm).toBeHidden({ timeout: 30_000 });
    await expect(card).toContainText("is testing", { timeout: 30_000 });
    const testing = now();
    // ST-2 keeps only the conversation pane, at 4:3, ending just under the live card (which grows upwards).
    const crop = await page.evaluate((id) => {
      const x = document.getElementById("timeline-scroll")!.getBoundingClientRect().left;
      const w = innerWidth - x;
      const h = Math.round((w * 3) / 4);
      const bottom = Math.min(innerHeight, document.getElementById(id)!.getBoundingClientRect().bottom + 12);
      return { x, y: Math.max(0, bottom - h), w, h };
    }, `telemetry-${backend}`);

    // The handoff, the owner badge, and the review.
    await expect(page.locator("#owner-badge")).toContainText("reviewer", { timeout: 60_000 });
    await expect(page.locator("#timeline")).toContainText("Approving with two small notes", { timeout: 60_000 });
    await page.waitForTimeout(2500);
    const end = now();
    await cdp.send("Page.stopScreencast");

    // -- Encode ------------------------------------------------------------------------
    // Screencast frames arrive only when something changes: turn them into a
    // constant 30 fps master with each frame held until the next one.
    const list = frames
      .map((f, i) => `file '${f.file}'\nduration ${Math.max(0.001, (frames[i + 1]?.t ?? end) - f.t).toFixed(4)}`)
      .join("\n");
    const listFile = info.outputPath("frames.txt");
    fs.writeFileSync(listFile, `${list}\nfile '${frames.at(-1)!.file}'\n`);
    const master = info.outputPath("master.mp4");
    const run = (...args: string[]) => execFileSync(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", ...args]);
    run("-f", "concat", "-safe", "0", "-i", listFile, "-vf", "fps=30,format=yuv420p", "-c:v", "libx264", "-crf", "10", "-preset", "veryfast", master);

    const t0 = frames[0].t;
    const even = (n: number) => 2 * Math.round(n); // CSS px → device px, even for yuv420p
    const cropFilter = `crop=${even(crop.w)}:${even(crop.h)}:${even(crop.x)}:${even(crop.y)}`;
    const cuts = {
      // from a beat into "researching" to just after "testing" appears; the poster is the last frame,
      // which is also the homepage's static (reduced-motion) state
      "story-02-working": { from: researching + 1.0 - t0, to: Math.min(testing + 1.5, researching + 9) - t0, poster: "end", vf: [cropFilter] },
      "full-run": { from: Math.max(0, start - 0.5 - t0), to: end - t0, poster: researching + 1.2 - t0, vf: [] },
    } as const;
    for (const [name, cut] of Object.entries(cuts)) {
      const span = ["-ss", cut.from.toFixed(2), "-to", cut.to.toFixed(2), "-i", master];
      const vf = cut.vf.length ? ["-vf", cut.vf.join(",")] : [];
      const poster = cut.poster === "end" ? cut.to - 0.05 : cut.poster;
      run(...span, ...vf, "-an", "-c:v", "libx264", "-crf", "23", "-preset", "slow", "-pix_fmt", "yuv420p", "-movflags", "+faststart", `${mediaDir}/${name}.mp4`);
      run(...span, ...vf, "-an", "-c:v", "libvpx-vp9", "-crf", "34", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "2", `${mediaDir}/${name}.webm`);
      run("-ss", poster.toFixed(2), "-i", master, ...vf, "-frames:v", "1", "-q:v", "3", `${mediaDir}/${name}-poster.jpg`);
      console.log(`${name}: ${(cut.to - cut.from).toFixed(1)}s`);
    }
  });
});
