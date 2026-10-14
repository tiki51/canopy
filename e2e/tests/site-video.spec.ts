// Records the Feature build story for the canopy_site homepage: one session
// at 1440×900, 2x, dark, no cursor, with the run panel open in Details beside
// the feed, and two cuts from it, each as WebM and MP4 with a poster frame,
// written to canopy_site/public/images:
//
//   pb-story-03-build.{webm,mp4} + -poster.jpg   the build: @frontend's live card and its delegation to
//                                                @backend, up to the moment @backend's edit asks; the
//                                                poster is its last frame (the homepage's reduced-motion state)
//   pb-full-run.{webm,mp4} + -poster.jpg          the whole run, Start to sign-off; the poster is the
//                                                design approval card
//
// Only runs when SITE_VIDEO=1 with the reports seed, and needs ffmpeg with
// libx264 and libvpx-vp9 (on PATH, or FFMPEG=/path/to/ffmpeg):
//
//   SITE_VIDEO=1 CANOPY_SEED=e2e/bin/seed-reports.exs FAKE_TURN_DELAY_MS=2500 npx playwright test tests/site-video.spec.ts
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
import { gotoLive } from "./helpers";
import { BRIEF, bottom, dismissFlash, mediaDir, park, prepare, sql, waitUntilLocal } from "./site-helpers";

const enabled = process.env.SITE_VIDEO === "1" && process.env.CANOPY_SEED?.includes("seed-reports");
const ffmpeg = process.env.FFMPEG || "ffmpeg";

// Top level: launch options can't be set inside a describe (they need their own worker).
test.use({
  viewport: null,
  launchOptions: { args: ["--force-device-scale-factor=2", "--window-size=1440,900"] },
});

test.describe("recording for canopy_site", () => {
  test.skip(!enabled, "set SITE_VIDEO=1 and CANOPY_SEED=e2e/bin/seed-reports.exs to record");

  test("record the Feature build run", async ({ page }, info) => {
    test.setTimeout(900_000);
    await prepare(page);
    expect(await page.evaluate(() => [innerWidth, innerHeight, devicePixelRatio])).toEqual([1440, 900, 2]);

    // Set up off camera: the Start page, filled in.
    await gotoLive(page, "/playbooks");
    await page.locator("#playbooks li", { hasText: "feature-build" }).locator("a[id^='start-playbook-']").click();
    await expect(page.locator("#start-preview")).toContainText("What will happen");
    await page.locator("#start-repository").selectOption({ label: "acme-reports" });
    await page.waitForTimeout(600);
    await page.locator("#start-coordinator").selectOption({ label: "@project-manager" });
    await page.waitForTimeout(600);
    await page.locator("#start-channel-name").click();
    await page.locator("#start-channel-name").fill("csv-export");
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
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
    // Full device size (2880×1800): a smaller cap scales frames down.
    await cdp.send("Page.startScreencast", { format: "jpeg", quality: 95, maxWidth: 2880, maxHeight: 1800 });
    const now = () => Date.now() / 1000;
    await waitUntilLocal(page, 10, 42);
    const start = now();

    const brief = page.locator("#start-brief");
    await brief.click();
    await brief.pressSequentially(BRIEF, { delay: 18 });
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await page.waitForTimeout(800);
    await page.locator("#start-playbook-submit").click();
    await expect(page).toHaveURL(/\/channels\/ch_/);
    const channelId = page.url().split("/channels/")[1];
    sql(`update channels set spend_limit = 5.0 where id = '${channelId}'`);
    await dismissFlash(page);
    await park(page);
    const frontend = (await page
      .locator('#sidebar a[href^="/agents/"]', { hasText: "@frontend" })
      .first()
      .getAttribute("href"))!.split("/agents/")[1];

    // The designs, and the approval gate: Option B.
    const gate = page.locator('section[id^="signoff-so_"]').first();
    await expect(gate).toContainText("Which design should we build?", { timeout: 120_000 });
    await bottom(page);
    const approval = now();
    await page.waitForTimeout(2500);
    await gate.locator('[id$="-accept-1"]').click();
    await park(page);

    // The build: @frontend's live card, then its delegation to @backend, whose edit asks first.
    const card = page.locator(`#telemetry-${frontend}`);
    // Keep the run panel on the step in progress, so it ticks forward on camera.
    const follow = (step: string) => page.locator(`#playbook-step-${step}`).evaluate((el) => el.scrollIntoView({ block: "center" }));
    await expect(page.locator("#playbook-step-tech-design")).toHaveAttribute("data-status", "active", { timeout: 60_000 });
    await follow("tech-design");
    await expect(page.locator("#timeline")).toContainText("Implement, and write the test plan", { timeout: 180_000 });
    await follow("build");
    await expect(card).toBeVisible({ timeout: 60_000 });
    if ((await card.getAttribute("data-open")) !== "true") await page.locator(`#telemetry-toggle-${frontend}`).click();
    await park(page);
    const building = now();
    const perm = page.locator('section[id^="permission-"]').first();
    // When the ask first shows (its timeline line or the card), polled every frame:
    // expect's polling can trail it by a second.
    const asked = await page
      .waitForFunction(
        () =>
          (document.querySelector('section[id^="permission-"]') ||
            document.querySelector("#timeline")?.textContent?.includes("asked for Edit permission")) &&
          Date.now() / 1000,
        null,
        { polling: "raf", timeout: 120_000 },
      )
      .then((handle) => handle.jsonValue() as Promise<number>);
    await expect(perm).toContainText("export_csv");
    await perm.scrollIntoViewIfNeeded();
    await page.waitForTimeout(2000);
    await page.locator('[id^="permission-"][id$="-always"]').first().click();
    await park(page);
    await expect(perm).toBeHidden({ timeout: 30_000 });

    // Review sends Build back; the fix; the test report; the sign-off.
    await expect(page.locator("#timeline")).toContainText("Sent back to Build", { timeout: 240_000 });
    await follow("build");
    await expect(page.locator("#playbook-step-design-check")).toHaveAttribute("data-status", "active", { timeout: 240_000 });
    await follow("sign-off");
    const signoff = page.locator('section[id^="signoff-so_"]', { hasText: "Accept the CSV export" }).first();
    await expect(signoff).toBeVisible({ timeout: 300_000 });
    await bottom(page);
    await page.waitForTimeout(2500);
    await signoff.locator('[id$="-accept"]').click();
    await park(page);
    await expect(page.locator("#timeline")).toContainText("the feature-build playbook is complete", { timeout: 60_000 });
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
    const cuts = {
      // Ends as @backend's edit asks, before the permission card: step 4 shows that.
      "pb-story-03-build": { from: building - 0.5 - t0, to: asked - 0.1 - t0, poster: "end" },
      "pb-full-run": { from: Math.max(0, start - 0.5 - t0), to: end - t0, poster: approval + 1.5 - t0 },
    } as const;
    // The full run plays in a smaller frame on the site: 1920 wide keeps UI text sharp at a quarter of the bytes.
    const scale: Record<string, string[]> = { "pb-full-run": ["-vf", "scale=1920:-2:flags=lanczos"], "pb-story-03-build": [] };
    for (const [name, cut] of Object.entries(cuts)) {
      const span = ["-ss", cut.from.toFixed(2), "-to", cut.to.toFixed(2), "-i", master];
      const poster = cut.poster === "end" ? cut.to - 0.05 : cut.poster;
      const vf = scale[name];
      run(...span, ...vf, "-an", "-c:v", "libx264", "-crf", "24", "-preset", "slow", "-pix_fmt", "yuv420p", "-movflags", "+faststart", `${mediaDir}/${name}.mp4`);
      run(...span, ...vf, "-an", "-c:v", "libvpx-vp9", "-crf", "36", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "2", `${mediaDir}/${name}.webm`);
      run("-ss", poster.toFixed(2), "-i", master, ...vf, "-frames:v", "1", "-q:v", "3", `${mediaDir}/${name}-poster.jpg`);
      console.log(`${name}: ${(cut.to - cut.from).toFixed(1)}s`);
    }
  });
});
