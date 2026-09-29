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
 * One capture per theme: <name>-dark.png and <name>-light.png. `clip` may be a
 * function so a crop is measured after the theme switch (heights can differ).
 */
export async function shot(
  page: Page,
  name: string,
  clip?: Clip | (() => Promise<Clip>),
  themes: Theme[] = ["dark", "light"],
) {
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
  return execFileSync("sqlite3", [db, statement], { encoding: "utf8" }).trim();
}

/** ISO timestamp in the format the app stores (microseconds, Z). */
export const iso = (d: Date) => d.toISOString().replace(/\.(\d{3})Z$/, ".$1000Z");

/** Local wall-clock hour → UTC Date, for the server's TZ (see playwright.config.ts). */
export function localAt(daysFromToday: number, hour: number, minute = 0): Date {
  const offsetMin = -new Date().getTimezoneOffset(); // this process shares the server's TZ
  const now = new Date();
  const local = new Date(now.getTime() + offsetMin * 60_000);
  const utcMidnightOfLocalDay = Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate() + daysFromToday);
  return new Date(utcMidnightOfLocalDay + (hour * 60 + minute - offsetMin) * 60_000);
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
