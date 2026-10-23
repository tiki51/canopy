import { test, expect, Page, Locator } from "@playwright/test";
import { createChannel, gotoLive, send, timeline } from "./helpers";

// @here (design B, "Show the reach"): the composer offers it first and says
// who it will wake; the posted message shows who it woke. Woken fake agents
// answer "Acknowledged: …" with no mention, so a user's @here doesn't cascade;
// "tell everyone" makes the woken agent post an @here of its own
// (e2e/fake-opencode.mjs).

type Member = { name: string; working: boolean; active: boolean };

const input = (page: Page, prefix = "composer") => page.locator(`#${prefix}-input`);
const hint = (page: Page, prefix = "composer") => page.locator(`#${prefix}-here-hint`);
const popup = (page: Page) => page.locator("#composer-suggestions");
const ack = "Acknowledged: looking into it now.";

/** The composer's @here roster (data-here), as the page has it now. */
async function roster(page: Page, form = "#composer-form"): Promise<Member[]> {
  return JSON.parse((await page.locator(form).getAttribute("data-here")) || "[]");
}

const active = (members: Member[]) => members.filter(m => m.active);

/** The article for the latest message containing `text`. */
const article = (page: Page, text: string) => timeline(page).locator("article", { hasText: text }).last();

const pillOf = (scope: Locator) => scope.locator('details[id*="-here-msg_"]');

async function setChatter(page: Page, opts: { interrupt?: boolean; pause?: boolean; limit?: number }) {
  await gotoLive(page, "/settings");
  const form = page.locator("#chatter-form");
  const box = (name: string) => form.locator(`input[type=checkbox][name='setting[${name}]']`);
  if (opts.interrupt !== undefined) await (opts.interrupt ? box("interrupt_on_mention").check() : box("interrupt_on_mention").uncheck());
  if (opts.pause !== undefined) await (opts.pause ? box("chatter_pause").check() : box("chatter_pause").uncheck());
  if (opts.limit !== undefined) await form.locator("input[name='setting[chatter_limit]']").fill(String(opts.limit));
  await page.locator("#save-chatter").click();
  await expect(page.locator("#flash-info")).toBeVisible();
}

/** A channel where @backend is busy on the slow k6 run (interrupt.spec.ts). */
async function backendWorking(page: Page) {
  await send(page, "Run the checkout suite slowly.");
  const card = page.locator('section[id^="telemetry-"]').first();
  await expect(card.locator('[id$="-current"]')).toContainText("k6 run");
  return card;
}

async function openDm(page: Page, names: string[]) {
  await page.locator("#sidebar-new-dm").click();
  await expect(page.locator("#dm-picker-dialog")).toBeVisible();
  for (const name of names) await page.locator("#dm-agents label", { hasText: `@${name}` }).first().click();
  const before = page.url();
  await page.locator("#open-dm").click();
  await expect(page).not.toHaveURL(before);
  await expect(page.locator("#channel-name")).toContainText(names.map(n => `@${n}`).join(", "));
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached();
}

async function agentId(page: Page, name: string) {
  await gotoLive(page, "/agents");
  const row = page.locator('#active-agents li[id^="agent-agt_"]', { hasText: `@${name}` }).first();
  return (await row.getAttribute("id"))!.replace(/^agent-/, "");
}

test.describe("@here", () => {
  test.afterAll(async ({ browser }) => {
    const page = await browser.newPage();
    await setChatter(page, { interrupt: false, pause: false });
    await page.close();
  });

  test("E1: the autocomplete offers @here first, with the count, and inserts it", async ({ page }) => {
    await createChannel(page);
    const name = (await page.locator("#channel-name").innerText()).replace(/^#\s*/, "").trim();
    const n = active(await roster(page)).length;

    await input(page).pressSequentially("Before Thursday's release, @he");
    const first = popup(page).locator("button").first();
    await expect(first).toContainText("@here");
    await expect(first).toContainText(`everyone in #${name}`);
    await expect(first).toContainText(String(n));
    await expect(first.locator(".hero-megaphone")).toBeAttached();

    await input(page).press("Enter");
    await expect(input(page)).toHaveValue("Before Thursday's release, @here ");
    await expect(page.locator('#composer-highlight [data-kind="here"]')).toHaveText("@here");

    // the bare @ offers it first too; another letter drops it
    await input(page).fill("");
    await input(page).pressSequentially("@");
    await expect(popup(page).locator("button").first()).toContainText("@here");
    await input(page).pressSequentially("hx");
    await expect(popup(page)).not.toContainText("@here");
  });

  test("E2/E4/E5: the hint names who it wakes; the sent message shows the pill, which stays open", async ({ page }) => {
    test.setTimeout(120_000);
    // the budget off: each answer also wakes the owner (see E4b for the budget on)
    await setChatter(page, { pause: false });
    await createChannel(page);
    const members = active(await roster(page));
    const n = members.length;
    const text = "Before Thursday's release, @here please post anything still open on your side.";

    await input(page).fill(text);
    await expect(hint(page)).toContainText(`@here wakes ${n} agent${n === 1 ? "" : "s"}:`);
    for (const m of members.slice(0, n > 6 ? 5 : n)) await expect(hint(page)).toContainText(`@${m.name}`);
    if (n > 6) await expect(hint(page)).toContainText(`and ${n - 5} more`);

    // in code it wakes nobody, and the hint says nothing about it
    await input(page).fill("type `@here` to wake everyone");
    await expect(hint(page)).not.toContainText("@here wakes");

    await input(page).fill(text);
    await input(page).press("Enter");
    const post = article(page, "please post anything still open");
    await expect(post.locator("span.text-accent", { hasText: "@here" })).toBeVisible();
    const pill = pillOf(post);
    await expect(pill.locator("summary")).toContainText(`woke ${n} agent${n === 1 ? "" : "s"}`);
    await expect(pill.locator("summary")).not.toContainText("chatter budget");
    if (n > 5) await expect(pill.locator("summary")).toContainText(`+${n - 5}`);
    await expect(pill.locator("summary")).toHaveAttribute("title", members.map(m => `@${m.name}`).join(", "));

    // every member but the owner answers exactly once (each answer also wakes
    // the owner, @backend, so its answers are left out)
    const memberAcks = timeline(page).locator("article", { hasText: ack }).filter({ hasNotText: "@backend" });
    await expect(memberAcks).toHaveCount(n - 1, { timeout: 60_000 });

    // click opens; Enter and Space on the focused summary toggle it
    await pill.locator("summary").click();
    await expect(pill).toHaveAttribute("open", "");
    for (const m of members) await expect(pill.locator("ul li", { hasText: `@${m.name}` })).toBeVisible();
    await pill.locator("summary").click();
    await expect(pill).not.toHaveAttribute("open", "");
    await pill.locator("summary").focus();
    await page.keyboard.press("Enter");
    await expect(pill).toHaveAttribute("open", "");
    await page.keyboard.press("Space");
    await expect(pill).not.toHaveAttribute("open", "");

    // open, it survives a reaction's re-render of the message
    await pill.locator("summary").click();
    await post.hover();
    await post.locator('[id^="react-msg_"]').click();
    const picker = post.locator('[id^="react-picker-"][role="menu"]');
    await picker.locator('[id$="-check"]').click();
    await expect(post.locator('[id^="reaction-msg_"][id$="-check"]')).toBeVisible();
    await expect(pill).toHaveAttribute("open", "");
  });

  test("E4b: with the default budget on, a user's @here still reaches every member", async ({ page }) => {
    test.setTimeout(150_000);
    await setChatter(page, { pause: true, limit: 6 });
    await createChannel(page);
    const others = active(await roster(page)).filter(m => m.name !== "backend");
    await send(page, "@here roll call");
    const last = others[others.length - 1].name;
    // every member's own answer, even after the owner's turns spend the budget
    await expect(
      timeline(page).locator("article", { hasText: ack }).filter({ hasText: `@${last}` }),
    ).toHaveCount(1, { timeout: 90_000 });
    await expect(page.locator("#paused-bar")).toHaveCount(0);
    await setChatter(page, { pause: false });
  });

  test("E3/E14: a working agent reads @here after its turn, even with interrupt on", async ({ page }) => {
    await setChatter(page, { interrupt: true });
    await createChannel(page);
    const card = await backendWorking(page);

    await input(page).fill("@here status check");
    await expect(hint(page)).toContainText("@backend (working; reads it after its turn)");
    await input(page).press("Enter");

    // never steered: no interrupt chip, and the answer comes in a turn of its own
    const post = article(page, "@here status check");
    await expect(pillOf(post)).toBeVisible();
    await expect(post.locator('[id^="message-queued-"]', { hasText: "after the current step" })).toHaveCount(0);
    await expect(card.locator('[id^="steer-chip-"]')).toHaveCount(0);
    await setChatter(page, { interrupt: false });
  });

  test("E6: in a thread, @here says and does the whole channel", async ({ page }) => {
    test.setTimeout(120_000);
    // the budget off, so the @here wakes aren't held (E4b); each unaddressed
    // thread answer then wakes the previous replier, which the budget stops after
    await setChatter(page, { pause: false });
    await createChannel(page);
    const n = active(await roster(page)).length;
    await send(page, "the plan for today");
    await expect(timeline(page)).toContainText(ack);
    await expect(page.locator('section[id^="telemetry-"]')).toHaveCount(0);

    const root = article(page, "the plan for today");
    await root.hover();
    await root.locator('[id^="reply-"]').click();
    await expect(page.locator("#thread-panel")).toBeVisible();

    await input(page, "thread-composer").fill("@here thoughts?");
    await expect(hint(page, "thread-composer")).toContainText(`not just this thread`);
    await expect(hint(page, "thread-composer")).toContainText(`@here wakes all ${n} agent`);
    await input(page, "thread-composer").press("Enter");

    const reply = page.locator("#thread-replies article", { hasText: "@here thoughts?" });
    await expect(pillOf(reply).locator("summary")).toContainText(`woke ${n} agent`);
    // the whole channel answers in the thread, not just its owner
    const members = active(await roster(page)).map(m => m.name);
    const answers = page.locator("#thread-replies article", { hasText: "Answering in the thread" });
    for (const name of [members[0], members[members.length - 1]]) {
      await expect(answers.filter({ hasText: `@${name}` }).first()).toBeVisible({ timeout: 60_000 });
    }
    // the fake always answers, so the thread's replies would wake each other
    // for good (and fill the Threads inbox of later specs): stop the channel
    await page.locator("#stop-all").click();
    await expect(page.locator('section[id^="telemetry-"]')).toHaveCount(0, { timeout: 30_000 });
  });

  test("E7: in a DM with interrupt on, a working agent reads it after its current step", async ({ page }) => {
    await setChatter(page, { interrupt: true });
    await gotoLive(page, "/");
    await openDm(page, ["backend", "reviewer"]);
    await backendWorking(page);

    await input(page).fill("@here quick one");
    await expect(hint(page)).toContainText("@here wakes 2 agents:");
    await expect(hint(page)).toContainText("(working; reads it after its current step)");
    await expect(hint(page)).not.toContainText("after its turn)");
    await page.locator("#composer-input").fill("");
    await setChatter(page, { interrupt: false });
  });

  test("E8: an agent's @here costs one turn of the chatter budget", async ({ page }) => {
    await setChatter(page, { pause: true, limit: 20 });
    await createChannel(page);
    const n = active(await roster(page)).length;

    await send(page, "tell everyone about the notes");
    const post = article(page, "release notes draft is ready");
    await expect(post).toContainText("@backend");
    await expect(pillOf(post).locator("summary")).toContainText(
      `woke ${n - 1} agent${n - 1 === 1 ? "" : "s"} · 1 turn of chatter budget`,
    );
    await setChatter(page, { pause: false });
  });

  test("E9: with the budget spent, an agent's @here wakes wait for the user", async ({ page }) => {
    test.setTimeout(180_000);
    // limit 1: the owner's turn (woken by the user) spends it, so the @here the
    // owner posts in that turn needs a turn the budget no longer has
    await setChatter(page, { pause: true, limit: 1 });
    await createChannel(page);
    const others = active(await roster(page)).filter(m => m.name !== "backend");
    const memberAcks = timeline(page).locator("article", { hasText: ack }).filter({ hasNotText: "@backend" });

    await send(page, "tell everyone");
    const post = article(page, "the release notes draft is ready");
    await expect(post).toBeVisible();
    await expect(post.locator('details[id*="-here-"] summary')).toContainText(`woke ${others.length} agent`);
    await expect(page.locator("#paused-bar")).toBeVisible({ timeout: 20_000 });
    // held: no member answers until the user acts
    await page.waitForTimeout(4_000);
    await expect(memberAcks).toHaveCount(0);

    // Continue releases them, and the one paid turn reaches every member
    await page.locator("#continue-chatter").click();
    await expect(memberAcks).toHaveCount(others.length, { timeout: 90_000 });
    await setChatter(page, { pause: false });
  });

  test("E10: /delegate's note never wakes everyone; an /i note does", async ({ page }) => {
    await createChannel(page);

    await input(page).fill("/delegate @reviewer do it @here");
    await expect(hint(page)).not.toContainText("@here wakes");
    await expect(page.locator('#composer-highlight [data-kind="here"]')).toHaveCount(0);

    await input(page).fill("/i @reviewer hi @here");
    await expect(hint(page)).toContainText("@here wakes");
    await expect(page.locator('#composer-highlight [data-kind="here"]')).toHaveCount(1);
    await input(page).fill("");
  });

  test("E11: an agent's @here with no one else around says it woke nobody", async ({ page }) => {
    await gotoLive(page, "/");
    await openDm(page, ["backend"]);
    await send(page, "tell everyone");
    const post = article(page, "release notes draft is ready");
    await expect(post.locator('[id*="-here-msg_"]')).toHaveText("@here woke nobody: no other agents in this DM.");
    await expect(pillOf(post)).toHaveCount(0);
  });

  test("E12: here is a reserved name for agents and teams", async ({ page }) => {
    await gotoLive(page, "/agents/new");
    await page.getByLabel("Name (slug, used as @name)").fill("here");
    await page.getByLabel("Display name").fill("Here");
    await page.getByLabel("Role (one line)").fill("Should not save");
    await page.locator("#save-agent").click();
    await expect(page.locator("#agent-form")).toContainText("is reserved for @here; pick another name");
    await expect(page).toHaveURL(/\/agents\/new/);

    await gotoLive(page, "/teams/new");
    await page.locator("#team-form input[name='team[name]']").fill("here");
    await page.locator("#save-team").click();
    await expect(page.locator("#team-form")).toContainText("is reserved for @here; pick another name");
  });

  test("E13: the hint follows the roster while the draft is open", async ({ page, context }) => {
    await createChannel(page);
    const victim = active(await roster(page)).find(m => m.name !== "backend")!.name;
    await input(page).fill("@here roll call");
    await expect(hint(page)).not.toContainText(`@${victim} is off`);

    const other = await context.newPage();
    const id = await agentId(other, victim);
    await gotoLive(other, `/agents/${id}`);
    await other.locator("#agent-menu-toggle").click();
    await other.locator(`#deactivate-agent-${id}`).click();
    await other.locator("#canopy-confirm-ok").click();
    await expect(other.locator("#agent-about")).toContainText("deactivated");

    try {
      await expect(hint(page)).toContainText(`@${victim} is off and won't be woken.`);
      await expect(input(page)).toHaveValue("@here roll call");
    } finally {
      await other.locator(`#reactivate-agent-${id}`).click();
      await expect(other.locator("#agent-about")).not.toContainText("deactivated");
      await other.close();
    }
    await expect(hint(page)).not.toContainText(`@${victim} is off`);
  });
});
