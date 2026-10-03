import { BrowserContext, Page, expect } from "@playwright/test";

// A stand-in for the browser's Notification API and page visibility, so the
// specs can see what Canopy would show (assets/js/notify.js) and pretend the
// tab is hidden or unfocused. Installed on the context: every tab gets it.
//
//   window.__notes      [{title, body, tag, silent}] in the order shown
//   window.__instances  the Notification objects, so a spec can fire onclick
//   window.__requests   how many times requestPermission was called
//
// Permission is kept in localStorage ("__perm"), so it survives a reload and
// is shared by the context's tabs, as a real grant per origin is.
export type StubOptions = {
  permission?: NotificationPermission;
  // what requestPermission() resolves to
  answer?: NotificationPermission;
  // no Notification API at all
  unsupported?: boolean;
  // every tab starts hidden and unfocused
  hidden?: boolean;
};

export async function stubNotifications(context: BrowserContext, opts: StubOptions = {}) {
  await context.addInitScript(({ permission, answer, unsupported, hidden }) => {
    const w = window as any;
    w.__notes = [];
    w.__instances = [];
    w.__requests = 0;
    w.__vis = hidden ? "hidden" : "visible";
    w.__focus = !hidden;
    Object.defineProperty(document, "visibilityState", { get: () => w.__vis, configurable: true });
    document.hasFocus = () => w.__focus;

    if (unsupported) {
      delete w.Notification;
      return;
    }

    const read = () => localStorage.getItem("__perm") || permission;
    class FakeNotification {
      static get permission() {
        return read();
      }
      static requestPermission() {
        w.__requests += 1;
        if (read() === "default") localStorage.setItem("__perm", answer);
        return Promise.resolve(read());
      }
      title: string;
      body?: string;
      tag?: string;
      silent?: boolean;
      closed = false;
      onclick: ((e: unknown) => void) | null = null;
      onclose: (() => void) | null = null;
      constructor(title: string, options: NotificationOptions = {}) {
        this.title = title;
        this.body = options.body;
        this.tag = options.tag;
        this.silent = options.silent ?? undefined;
        w.__notes.push({ title, body: options.body, tag: options.tag, silent: options.silent });
        w.__instances.push(this);
      }
      close() {
        this.closed = true;
      }
    }
    Object.defineProperty(window, "Notification", { value: FakeNotification, configurable: true, writable: true });
  }, {
    permission: opts.permission ?? "default",
    answer: opts.answer ?? "granted",
    unsupported: opts.unsupported ?? false,
    hidden: opts.hidden ?? false,
  });
}

/** Pretends the tab is hidden (or shown) and unfocused (or focused). */
export async function setVisible(page: Page, visible: boolean, focused = visible) {
  await page.evaluate(({ visible, focused }) => {
    const w = window as any;
    w.__vis = visible ? "visible" : "hidden";
    w.__focus = focused;
    document.dispatchEvent(new Event("visibilitychange"));
    if (focused) window.dispatchEvent(new Event("focus"));
  }, { visible, focused });
}

export const notes = (page: Page) =>
  page.evaluate(() => (window as any).__notes as { title: string; body: string; tag: string; silent: boolean }[]);

/** Loads a page and waits for its LiveView to connect. */
export async function open(page: Page, path: string) {
  await page.goto(path);
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
}

/** What waits on the user across channels, as the shell knows it. */
export const waiting = async (page: Page) =>
  Number(await page.locator("#canopy-notifier").getAttribute("data-attention"));

/** Turns desktop notifications on through Settings, as the user would. */
export async function turnOn(page: Page) {
  await open(page, "/settings");
  await page.locator("#notify-enabled").check();
  await expect(page.locator("#notify-prefs")).toHaveAttribute("data-state", "on");
}
