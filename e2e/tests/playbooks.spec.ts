import { test, expect } from "@playwright/test";
import { createChannel, send, timeline, uniq } from "./helpers";

// Playbooks: the library and editor, then a run the fake OpenCode drives. Asked
// to "run the <name> playbook", the fake agent starts it as the coordinator and
// advances through to the step held for the user's sign-off; Approve wakes it
// to close the run. Watches stay out of e2e (no gh here); ExUnit covers them.

const playbookText = (name: string) => `---
name: ${name}
description: A three-step check for the e2e suite.
roles:
  dev: frontend
stall_after: off
steps:
  - id: plan
    title: Plan
    owner: coordinator
  - id: build
    title: Build
    owner: dev
  - id: sign-off
    title: Sign-off
    owner: coordinator
    approval: user
---

Ground rules for the e2e run.

## plan

Plan it.

## build

Build it.

## sign-off

Ask the user.
`;

test.describe("playbooks", () => {
  test("write a playbook, run it in a channel, and approve its sign-off", async ({ page }) => {
    const name = uniq("e2e-check");

    // the library lists the seeded bug-fix playbook
    await page.goto("/playbooks");
    await expect(page.locator("#playbooks")).toContainText("bug-fix");
    await expect(page.locator("#playbooks")).toContainText("starter");

    // the editor checks the text as you type and previews the steps
    await page.locator("#new-playbook").click();
    await expect(page).toHaveURL(/\/playbooks\/new$/);
    await page.locator("#playbook-body").fill("---\nname: Bad_Name\n---\n");
    await expect(page.locator("#playbook-errors")).toContainText("description is missing");
    await page.locator("#playbook-body").fill(playbookText(name));
    await expect(page.locator("#playbook-errors")).toHaveCount(0);
    await expect(page.locator("#preview-step-sign-off")).toContainText("your sign-off");
    await page.locator("#save-playbook").click();
    await expect(page).toHaveURL(/\/playbooks$/);
    await expect(page.locator("#playbooks")).toContainText(name);

    // the coordinator starts it and advances to the gate
    await createChannel(page);
    await expect(page.locator("#edit-playbook")).toBeVisible();
    await send(page, `@backend run the ${name} playbook`);

    await expect(timeline(page)).toContainText(`@backend started the ${name} playbook · 3 steps`);
    await expect(timeline(page)).toContainText(`${name}: Plan done → Build (@frontend)`);
    await expect(timeline(page)).toContainText(`${name} is waiting for your sign-off on Sign-off`);
    await expect(timeline(page)).toContainText("Ready for your sign-off: README.md updated.");

    const chip = page.locator("#playbook-chip");
    await expect(chip).toHaveAttribute("data-status", "awaiting_approval");
    await expect(chip).toContainText(`${name} · 3/3 Sign-off`);

    // the first time this browser sees the run, its panel opens by itself:
    // every step and the gate's controls
    await expect(page.locator("#playbook-panel")).toBeVisible();
    await expect(page.locator("#playbook-roster")).toContainText("Roster");
    await expect(page.locator("#reassign-coordinator-form")).toContainText("Coordinator");
    await expect(page.locator("#playbook-step-plan")).toHaveAttribute("data-status", "done");
    await expect(page.locator("#playbook-step-build-result")).toContainText("Built: README.md updated.");
    await expect(page.locator("#playbook-step-sign-off")).toHaveAttribute("data-status", "awaiting_approval");

    // seen once: after a reload the panel starts collapsed, and the chip toggles it
    await page.reload();
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
    await expect(chip).toBeVisible();
    await expect(page.locator("#playbook-panel")).toBeHidden();
    await chip.click();
    await expect(page.locator("#playbook-panel")).toBeVisible();

    // Approve completes the run and wakes the coordinator
    await page.locator("#approve-playbook-step").click();
    await expect(timeline(page)).toContainText(`approved Sign-off of ${name}`);
    await expect(timeline(page)).toContainText(`the ${name} playbook is complete`);
    await expect(timeline(page)).toContainText("Signed off; closing the run.");
    await expect(chip).toBeHidden();
    await expect(page.locator("#playbook-panel")).toContainText("No playbook is running here");
  });
});
