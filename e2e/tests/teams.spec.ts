import { test, expect, Page } from "@playwright/test";
import { send, timeline, uniq } from "./helpers";

/** Creates a channel whose only member (and owner) is @backend; returns its id. */
async function backendOnlyChannel(page: Page, name = uniq("solo")): Promise<string> {
  await page.goto("/channels/new");
  await page.getByLabel("Repository").selectOption({ label: "e2e-repo" });
  await page.getByLabel("Name (slug, shown as #name)").fill(name);
  await page.locator("#toggle-all-members").click();
  await expect(page.locator("#toggle-all-members")).toHaveText("Select all");
  await page.locator("#channel-members label", { hasText: "@backend" }).first().locator("input").check();
  await page.locator("#create-channel").click();
  await expect(page).toHaveURL(/\/channels\/ch_/);
  return page.url().split("/channels/")[1];
}

async function agentId(page: Page, name: string): Promise<string> {
  const option = page.locator("#team-members label", { hasText: `@${name}` }).first().locator("input");
  return (await option.getAttribute("value"))!;
}

test.describe("teams", () => {
  test("create a team, start a channel with it, invite it, and mention it", async ({ page }) => {
    const team = uniq("qa");

    // create @qa-… on /teams with @test and @reviewer, @reviewer leading
    await page.goto("/agents");
    await page.locator("#agents-teams").click();
    await expect(page).toHaveURL(/\/teams$/);
    await page.locator("#new-team").click();
    await page.getByLabel("Name (slug, used as @name)").fill(team);
    const testId = await agentId(page, "test");
    const reviewerId = await agentId(page, "reviewer");
    await page.locator(`#team-member-${testId}`).check();
    await page.locator(`#team-member-${reviewerId}`).check();
    await expect(page.locator("#team-lead option", { hasText: "@reviewer" })).toHaveCount(1);
    await page.locator("#team-lead").selectOption(reviewerId);
    await page.locator("#save-team").click();
    await expect(page).toHaveURL(/\/teams$/);
    const row = page.locator('[id^="team-tm_"]', { hasText: `@${team}` });
    await expect(row).toContainText("@reviewer");
    await expect(row).toContainText("lead");

    // "New channel" lands with only its members ticked and the lead as owner
    await row.locator('a[id^="new-channel-team-"]').click();
    await expect(page).toHaveURL(/\/channels\/new\?team=tm_/);
    await expect(page.locator(`#member-${testId}`)).toBeChecked();
    await expect(page.locator(`#member-${reviewerId}`)).toBeChecked();
    await expect(page.locator("#channel-members input:checked")).toHaveCount(2);
    await expect(page.getByLabel("Initial owner")).toHaveValue(reviewerId);

    // in another channel, the Members panel invites the team quietly
    await backendOnlyChannel(page);
    await page.locator("#edit-members").click();
    const option = page.locator("#invite-team-select option", { hasText: `@${team}` });
    await expect(option).toContainText("2 members");
    await page.locator("#invite-team-select").selectOption((await option.getAttribute("value"))!);
    await page.locator("#invite-team").click();
    await expect(timeline(page)).toContainText(`@${team} joined: @reviewer, @test`);
    await expect(page.locator(`#member-${testId}`)).toBeVisible();
    await expect(page.locator(`#member-${reviewerId}`)).toBeVisible();
    // everyone on it is here now, so it is no longer offered (the seeded @bugfix-team still is)
    await expect(page.locator("#invite-team-select option", { hasText: `@${team}` })).toHaveCount(0);

    // /i @team with a message adds the team, then wakes both members
    await backendOnlyChannel(page);
    await send(page, `/i @${team} check the login page`);
    await expect(timeline(page)).toContainText(`@${team} joined: @reviewer, @test`);
    await expect(timeline(page)).toContainText(`@${team} check the login page`);
    await expect(page.locator(`#member-${testId}`)).toBeVisible();
    await expect(timeline(page)).toContainText("@reviewer finished");
    await expect(timeline(page)).toContainText("@test finished");

    // the composer suggests the team after @
    const input = page.locator("#composer-input");
    await input.fill(`hi @${team.slice(0, 4)}`);
    await expect(page.locator("#composer-suggestions")).toContainText(`@${team}`);
    await input.press("Escape");
    await input.fill("");
  });
});
