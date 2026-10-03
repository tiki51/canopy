import { test, expect, Page } from "@playwright/test";
import { createChannel, send, timeline, uniq } from "./helpers";

const fake = `http://127.0.0.1:${process.env.FAKE_OPENCODE_PORT || 4396}`;
const working = (page: Page) => page.locator('section[id^="telemetry-"]');
const turns = (page: Page) => timeline(page).locator('section[id^="turn-"]');

type FakeSession = { title: string; lastSystem?: string | null; lastText?: string };

/** What @backend's session in the channel was last prompted with (from the fake OpenCode). */
async function backendSession(page: Page, name: string): Promise<FakeSession | undefined> {
  const res = await page.request.get(`${fake}/__fake/sessions`);
  return ((await res.json()) as FakeSession[]).find((s) => s.title === `#${name} · @backend`);
}

async function saveBrief(page: Page, text: string) {
  await page.locator("#edit-brief").click();
  const box = page.locator("#brief-form textarea");
  await expect(box).toBeVisible();
  await box.fill(text);
  await expect(page.locator("#brief-chars")).toContainText(`${text.length} / 4,000 chars`);
  await page.locator("#save-brief").click();
  await expect(page.locator("#brief-form")).toHaveCount(0);
}

async function reloaded(page: Page) {
  await page.reload();
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
}

test.describe("channel brief", () => {
  test("a saved brief is pinned, reaches the agent's system text, and changes with an edit", async ({ page }) => {
    const name = uniq("brief");
    await createChannel(page, name);

    await saveBrief(page, "Goal: stop double charges. Don't touch stripe_client.ex.");
    await expect(page.locator("#channel-brief")).toBeVisible();
    await expect(page.locator("#brief-summary")).toContainText("Goal: stop double charges.");
    await expect(page.locator("#brief-dot")).toBeVisible();
    await expect(timeline(page)).toContainText("updated the channel brief");

    await send(page, "@backend what is the goal here?");
    await expect(turns(page)).toHaveCount(1);
    await expect(working(page)).toHaveCount(0);
    await expect
      .poll(async () => (await backendSession(page, name))?.lastSystem ?? "")
      .toContain("Goal: stop double charges. Don't touch stripe_client.ex.");
    const first = await backendSession(page, name);
    expect(first?.lastSystem).toContain(`Channel brief for #${name}`);

    await saveBrief(page, "Goal: refunds too.");
    await expect(page.locator("#brief-summary")).toContainText("Goal: refunds too.");

    await send(page, "@backend and now?");
    await expect(turns(page)).toHaveCount(2);
    await expect(working(page)).toHaveCount(0);
    await expect
      .poll(async () => (await backendSession(page, name))?.lastSystem ?? "")
      .toContain("Goal: refunds too.");
    const second = await backendSession(page, name);
    expect(second?.lastSystem).not.toContain("stop double charges");
    // the session had a turn under the old brief, so it is told once
    expect(second?.lastText).toContain("The channel brief changed since your last turn");
  });

  test("open or closed is remembered across a reload; History restores an older version", async ({ page }) => {
    await createChannel(page);
    await saveBrief(page, "First version of the brief.");
    await saveBrief(page, "Second version of the brief.");

    await expect(page.locator("#channel-brief")).toHaveAttribute("data-expanded", "false");
    await page.locator("#brief-toggle").click();
    await expect(page.locator("#brief-body")).toContainText("Second version of the brief.");

    await reloaded(page);
    await expect(page.locator("#brief-body")).toContainText("Second version of the brief.");

    await page.locator("#brief-toggle").click();
    await expect(page.locator("#brief-body")).toHaveCount(0);
    await reloaded(page);
    await expect(page.locator("#channel-brief")).toHaveAttribute("data-expanded", "false");
    await expect(page.locator("#brief-body")).toHaveCount(0);

    await page.locator("#brief-toggle").click();
    await page.locator("#brief-history-toggle").click();
    const older = page.locator('#brief-history li', { hasText: "First version of the brief." });
    await expect(older).toBeVisible();
    await older.locator('[id^="brief-restore-"]').click();

    await expect(page.locator("#brief-body")).toContainText("First version of the brief.");
    await expect(page.locator("#brief-history li").first()).toContainText("current");
    await expect(page.locator("#brief-history li")).toHaveCount(3);
  });
});
