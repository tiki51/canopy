// Shared by the site capture specs (site-shots, site-video): theme switching,
// element crops at 2x in both themes, and the small amount of direct database
// access the story needs to show "the next morning".
import { expect, Locator, Page } from "@playwright/test";
import { execFileSync } from "node:child_process";
import path from "node:path";

/** Where the stills go: the site's `<Shot>` folder (canopy_site/src/assets/shots). */
export const shotsDir = process.env.SITE_SHOTS_DIR || "../../canopy_site/src/assets/shots";
/** Where the recordings go: served as-is from canopy_site/public/images. */
export const mediaDir = process.env.SITE_MEDIA_DIR || "../../canopy_site/public/images";

export const db = process.env.CANOPY_DB || path.resolve("../canopy_e2e.db");

export type Theme = "dark" | "light";

export async function theme(page: Page, name: Theme) {
  await page.evaluate((t) => {
    localStorage.setItem("phx:theme", t);
    document.documentElement.setAttribute("data-theme", t);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, name);
}

/**
 * Capture conventions (canopy_site/.canopy/out/shot-api.md): no composer hint
 * line, no caret, no hover left behind by the last click. Runs on every load.
 */
export async function prepare(page: Page, initial: Theme = "dark") {
  await page.addInitScript((t) => {
    localStorage.setItem("phx:theme", t);
    const css = `
      #composer-form > p { display: none !important; }
      * { caret-color: transparent !important; }
    `;
    const add = () => {
      const style = document.createElement("style");
      style.textContent = css;
      document.head.appendChild(style);
    };
    if (document.head) add();
    else document.addEventListener("DOMContentLoaded", add);
  }, initial);
}

/** Parks the pointer where nothing reacts to hover (the page header's empty middle). */
export async function park(page: Page) {
  const [w, h] = await page.evaluate(() => [innerWidth, innerHeight]);
  await page.mouse.move(w - 2, h - 2);
}

type Clip = { x: number; y: number; width: number; height: number };

/** The clip for an element plus `pad` px of surrounding app background, kept inside the viewport. */
export async function around(target: Locator, pad = 20, extra: Partial<Clip> = {}): Promise<Clip> {
  const box = (await target.boundingBox())!;
  const vp = target.page().viewportSize()!;
  const x = Math.max(0, Math.floor(box.x - pad));
  const y = Math.max(0, Math.floor(box.y - pad));
  const width = Math.min(vp.width - x, Math.ceil(box.width + pad * 2));
  const height = Math.min(vp.height - y, Math.ceil(box.height + pad * 2));
  return { x, y, width, height, ...extra };
}

/**
 * SITE_SHOTS=name,name… captures only those shots (the story still plays in
 * full), so a re-shoot doesn't overwrite stills that are already signed off.
 */
const only = process.env.SITE_SHOTS?.split(",").map((s) => s.trim()).filter(Boolean);
export const wanted = (...names: string[]) => !only || names.some((n) => only.includes(n));

/**
 * One capture per theme: <name>-dark.png and <name>-light.png. `clip` may be a
 * function so a crop is measured after the theme switch (heights can differ).
 */
export async function shot(
  page: Page,
  name: string,
  clip?: Clip | (() => Promise<Clip>),
  themes: Theme[] = ["dark", "light"],
) {
  if (!wanted(name)) return;
  for (const t of themes) {
    await theme(page, t);
    await page.waitForTimeout(150);
    const c = typeof clip === "function" ? await clip() : clip;
    await page.screenshot({ path: `${shotsDir}/${name}-${t}.png`, animations: "disabled", clip: c });
  }
  await theme(page, "dark");
}

/** Runs SQL against the e2e database (the server keeps running; SQLite is in WAL mode). */
export function sql(statement: string): string {
  // The messages table's update trigger writes to the messages_fts virtual
  // table, which the sqlite3 CLI refuses unless the schema is trusted.
  return execFileSync("sqlite3", ["-cmd", "PRAGMA trusted_schema=ON", db, statement], { encoding: "utf8" }).trim();
}

/** ISO timestamp in the format the app stores (microseconds, Z). */
export const iso = (d: Date) => d.toISOString().replace(/\.(\d{3})Z$/, ".$1000Z");

/** Local wall-clock hour → UTC Date, for the server's TZ (see playwright.config.ts). */
export function localAt(daysFromToday: number, hour: number, minute = 0): Date {
  // The config passes the offset along: Node ignores the POSIX TZ it gives the server.
  const offsetMin = Number(process.env.SITE_UTC_OFFSET_MIN ?? -new Date().getTimezoneOffset());
  const now = new Date();
  const local = new Date(now.getTime() + offsetMin * 60_000);
  const utcMidnightOfLocalDay = Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate() + daysFromToday);
  return new Date(utcMidnightOfLocalDay + (hour * 60 + minute - offsetMin) * 60_000);
}

/**
 * Waits until the server's clock reads hour:minute:00 today, so what follows is
 * stamped the same on every run. If that has passed (a slow boot), waits for the
 * next whole minute instead: the minutes shift, but the gaps between them don't.
 */
export async function waitUntilLocal(page: Page, hour: number, minute: number) {
  let target = localAt(0, hour, minute).getTime();
  if (target < Date.now()) {
    target = Math.ceil(Date.now() / 60_000) * 60_000;
    console.warn(`site capture: server clock already past ${hour}:${String(minute).padStart(2, "0")}; the story's minutes will differ from the copy`);
  }
  await page.waitForTimeout(target - Date.now() + 200);
}

export const sidebarChannel = (page: Page, name: string) =>
  page.locator('#sidebar a[id^="sidebar-channel-"]', { hasText: name }).first();

export async function dismissFlash(page: Page) {
  for (const id of ["#flash-info", "#flash-error"]) {
    const flash = page.locator(id);
    if (await flash.isVisible()) {
      await flash.click();
      await expect(flash).toBeHidden();
    }
  }
}

export async function send(page: Page, text: string) {
  const input = page.locator("#composer-input");
  await input.fill(text);
  await input.press("Enter");
}

export const bottom = (page: Page) =>
  page.locator("#timeline-scroll").evaluate((el) => (el.scrollTop = el.scrollHeight));
