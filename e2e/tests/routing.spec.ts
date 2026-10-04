import { test, expect, Page } from "@playwright/test";
import { createChannel, send, timeline, uniq } from "./helpers";

// Model routing (experimental, off by default). The spec turns it on for an
// agent of its own, so no seeded agent changes; the agent is deactivated at
// the end. The fake agent (e2e/fake-opencode.mjs) escalates a light turn whose
// scheduled instruction is an "escalating check".

const fake = `http://127.0.0.1:${process.env.FAKE_OPENCODE_PORT || 4396}`;

type FakeSession = { title: string; models?: (string | null)[] };

async function modelsOf(page: Page, title: string): Promise<(string | null)[]> {
  const res = await page.request.get(`${fake}/__fake/sessions`);
  return ((await res.json()) as FakeSession[]).find((s) => s.title === title)?.models || [];
}

test.describe("model routing", () => {
  test("off by default and labelled experimental on the agent form", async ({ page }) => {
    await page.goto("/agents");
    await page.locator("#active-agents").getByText("@backend", { exact: true }).click({ force: true }); // the row's overlay link takes it
    await expect(page).toHaveURL(/\/agents\/agt_/);
    await expect(page.locator("#agent-routing")).toContainText("off");
    await page.locator('[id^="edit-agent-"]').click();
    await expect(page.locator("#agent-routing-fields")).toContainText("experimental");
    await expect(page.locator("#routing-experimental-note")).toContainText("Experimental: not yet checked against the real engines.");
    await expect(page.locator("#agent-routing-enabled")).not.toBeChecked();
  });

  test("a scheduled wake runs light; an escalation runs it again on the main model", async ({ page }) => {
    const name = uniq("router").replace(/[^a-z0-9-]/g, "");
    let id: string | undefined;

    try {
      // an agent of its own, on a main model, with routing on and a light model
      await page.goto("/agents/new");
      await page.getByLabel("Name (slug, used as @name)").fill(name);
      await page.getByLabel("Role (one line)").fill("Routes cheap wakes");
      await page.locator("#agent-form select[name='agent[model_provider]']").selectOption("opencode");
      await page.locator("#agent-form select[name='agent[model_id]']").selectOption("claude-sonnet-5");
      await page.locator("#agent-routing-enabled").check();
      await page.locator("#opencode-light-provider").selectOption("opencode");
      await page.locator("#opencode-light-model").selectOption("claude-haiku-4-5");
      await page.locator("#save-agent").click();
      await expect(page).toHaveURL(/\/agents\/agt_/);
      id = new URL(page.url()).pathname.split("/").pop();
      await expect(page.locator("#agent-routing")).toContainText("on · light opencode/claude-haiku-4-5");

      const channel = uniq("routed");
      await createChannel(page, channel);
      await send(page, `@${name} please schedule an escalating check for a few seconds from now.`);
      await expect(timeline(page)).toContainText(/scheduled: once · Run the escalating check/);

      // the schedule fires: the light turn escalates, the main turn answers
      await expect(timeline(page)).toContainText(`@${name} escalated to its main model`, { timeout: 20_000 });
      await expect(timeline(page).locator('[id$="-light"]').first()).toContainText("light model");
      await expect(timeline(page)).toContainText("Ran the scheduled check: all green.", { timeout: 20_000 });
      await expect(timeline(page)).not.toContainText("Escalating.");

      // the mention ran on main, the schedule light, its re-run main again
      expect(await modelsOf(page, `#${channel} · @${name}`)).toEqual([
        "opencode/claude-sonnet-5",
        "opencode/claude-haiku-4-5",
        "opencode/claude-sonnet-5",
      ]);

      // the Costs page counts the routed agent and its light turn
      await page.goto("/costs?period=today");
      await expect(page.locator("#routing-agents")).toContainText("1");
      await expect(page.locator("#routing-escalated")).toContainText("100%");
    } finally {
      // leave the agents as they were: routing off, the spec's agent out of the way
      if (id) {
        await page.goto(`/agents/${id}/edit`);
        await page.locator("#agent-routing-enabled").uncheck();
        await page.locator("#save-agent").click();
        await expect(page).toHaveURL(new RegExp(`/agents/${id}$`));
        await page.locator("#agent-menu-toggle").click();
        await page.locator(`#deactivate-agent-${id}`).click();
        await expect(page.locator("#canopy-confirm")).toBeVisible();
        await page.locator("#canopy-confirm-ok").click();
        await expect(page.locator(`#reactivate-agent-${id}`)).toBeVisible();
      }
    }
  });
});
