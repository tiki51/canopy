import { test, expect } from "@playwright/test";
import { createChannel, send, timeline, uniq } from "./helpers";

// Playbooks: the library and the builder, then a run the fake OpenCode drives.
// Asked to "run the <name> playbook", the fake agent starts it as the lead and
// advances through to the step held for the user's sign-off; Approve wakes it
// to close the run. Watches stay out of e2e (no gh here); ExUnit covers them.

test.describe("playbooks", () => {
  test("build a playbook, run it in a channel, and approve its sign-off", async ({ page }) => {
    const name = uniq("e2e-check");

    // the library lists the seeded bug-fix playbook
    await page.goto("/playbooks");
    await expect(page.locator("#playbooks")).toContainText("bug-fix");
    await expect(page.locator("#playbooks")).toContainText("starter");

    // New → Start blank opens the builder with one empty step
    await page.locator("#new-playbook").click();
    await expect(page).toHaveURL(/\/playbooks\/new$/);
    await page.locator("#start-blank").click();
    await expect(page).toHaveURL(/\/playbooks\/new\/blank$/);
    await expect(page.locator("#save-playbook")).toBeDisabled();

    await page.locator("#about-title").fill(name);
    await page.locator("#about-description").fill("A three-step check for the e2e suite.");
    await expect(page.locator("#edit-name")).toHaveText(name);

    // step 1: Build, by @frontend (picking an agent adds a role named after it)
    await page.locator("#step-s1-title").fill("Build");
    await page.locator("#add-owner-s1").click();
    await page.locator("#owner-agent-frontend").click();
    await expect(page.locator("#role-chip-frontend")).toContainText("@frontend");
    await page.keyboard.press("Escape");

    // step 2: the lead plans; step 3: your sign-off
    await page.locator("#add-step").click();
    await page.locator("#preset-lead").click();
    await expect(page.locator("#step-s2-title")).toBeFocused();
    await page.locator("#step-s2-title").fill("Plan");
    await page.locator("#add-step").click();
    await page.locator("#preset-sign_off").click();
    await page.locator("#step-s3-title").fill("Sign-off");
    await expect(page.locator("#step-s3")).toContainText("waits for you");

    // Plan moves up to step 1 from the keyboard: lift, up, drop
    await page.locator("#grip-s2").focus();
    await page.keyboard.press("Space");
    await expect(page.locator("#drag-announcer")).toContainText("Moving Plan to step 2");
    await page.keyboard.press("ArrowUp");
    await expect(page.locator("#drag-announcer")).toContainText("Moving Plan to step 1");
    await page.keyboard.press("Space");
    await expect(page.locator("#builder-step-list > li").first()).toHaveAttribute("data-title", "Plan");

    // Create saves it and stays in the builder
    await expect(page.locator("#save-playbook")).toBeEnabled();
    await page.locator("#save-playbook").click();
    await expect(page).toHaveURL(/\/playbooks\/pb_[^/]+\/edit$/);
    await expect(page.locator("#save-state")).toContainText("Saved");

    // the exported file is the same Markdown with YAML the parser reads
    const id = page.url().split("/playbooks/")[1].split("/")[0];
    const file = await (await page.request.get(`/playbooks/${id}/export`)).text();
    expect(file).toContain(`name: ${name}\ndescription: A three-step check for the e2e suite.\nroles:\n  frontend: frontend\nsteps:\n`);
    expect(file).toContain(
      "  - id: plan\n    title: Plan\n    owner: coordinator\n" +
        "  - id: build\n    title: Build\n    owner: frontend\n" +
        "  - id: sign-off\n    title: Sign-off\n    owner: coordinator\n    approval: user\n---\n"
    );
    expect(file).toContain(`\n# ${name}\n`);

    // the lead starts it and advances to the gate
    await createChannel(page);
    await expect(page.locator("#playbook-chip")).toBeHidden();
    await send(page, `@backend run the ${name} playbook`);

    await expect(timeline(page)).toContainText(`@backend started the ${name} playbook · 3 steps`);
    await expect(timeline(page)).toContainText(`${name}: Plan done → Build (@frontend)`);
    await expect(timeline(page)).toContainText(`${name} is waiting for your sign-off on Sign-off`);
    await expect(timeline(page)).toContainText("Ready for your sign-off: README.md updated.");

    const chip = page.locator("#playbook-chip");
    await expect(chip).toHaveAttribute("data-status", "awaiting_approval");
    await expect(chip).toContainText(`${name} · 3/3 Sign-off`);

    // the first time this browser sees the run, Details opens on its panel by
    // itself: every step and the gate's controls
    await expect(page.locator("#details-panel #playbook-panel")).toBeVisible();
    await expect(page.locator("#playbook-roster")).toContainText("Roster");
    await expect(page.locator("#reassign-coordinator-form")).toContainText("Lead");
    await expect(page.locator("#playbook-step-plan")).toHaveAttribute("data-status", "done");
    await expect(page.locator("#playbook-step-build-result")).toContainText("Built: README.md updated.");
    await expect(page.locator("#playbook-step-sign-off")).toHaveAttribute("data-status", "awaiting_approval");

    // seen once: after a reload the panel starts collapsed, and the chip opens it in Details
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

  test("a review moved above what it sends back to is a problem with a one-click fix", async ({ page }) => {
    await page.goto("/playbooks");
    await page.locator("#playbooks li", { hasText: "bug-fix" }).locator("a[id^='edit-playbook-']").click();
    await expect(page.locator("#about-title")).toHaveValue("Bug fix");
    await expect(page.locator("li[data-title='Fix'] .rail-start")).toBeAttached();

    // Fix goes down two places, below Review
    const fix = page.locator("li[data-title='Fix'] [data-grip]");
    await fix.focus();
    await page.keyboard.press("Space");
    await page.keyboard.press("ArrowDown");
    await page.keyboard.press("ArrowDown");
    await page.keyboard.press("Space");

    await expect(page.locator("#problem-banner")).toContainText("Step 4 · Review — Sends work back to Fix, which now comes after it");
    await expect(page.locator("#save-playbook")).toBeDisabled();
    await page.locator("li[data-title='Review'] button", { hasText: "Send back to Verify instead" }).click();
    await expect(page.locator("#problem-banner")).toHaveCount(0);
    await expect(page.locator("li[data-title='Review']")).toContainText("can send back to Verify");

    // Discard puts the saved playbook back
    await page.locator("#discard-changes").click();
    await page.locator("#canopy-confirm-ok").click();
    await expect(page.locator("#save-state")).toContainText("Saved");
    await expect(page.locator("li[data-title='Review']")).toContainText("can send back to Fix");
  });

  test("start a run from the Start page, in a new channel", async ({ page }) => {
    await page.goto("/playbooks");
    await page.locator("#playbooks li", { hasText: "bug-fix" }).locator("a[id^='start-playbook-']").click();
    await expect(page.locator("#start-preview")).toContainText("What will happen");
    await expect(page.locator("#start-inputs")).toContainText("The symptom");

    const brief = `Checkout button misaligned ${uniq("e2e")}`;
    await page.locator("#start-brief").fill(brief);
    await page.locator("#start-repository").selectOption({ label: "e2e-repo" });
    await expect(page.locator("#start-channel-name")).toHaveValue(/^bug-fix-checkout-button-misaligned/);
    const channel = await page.locator("#start-channel-name").inputValue();
    const lead = page.locator("#start-coordinator");
    await lead.selectOption({ label: "@backend" });
    await expect(page.locator("#start-consequence")).toContainText("@backend is woken with your brief");

    await page.locator("#start-playbook-submit").click();
    await expect(page).toHaveURL(/\/channels\/ch_/);
    await expect(page.locator("#channel-name")).toContainText(channel.slice(0, 20));
    await expect(page.locator("#playbook-chip")).toContainText("bug-fix");
  });
});
