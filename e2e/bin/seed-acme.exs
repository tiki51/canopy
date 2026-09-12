# Seeds the "Acme" workspace used for the user guide screenshots. Run against
# the Playwright database only:
#
#     CANOPY_SEED=e2e/bin/seed-acme.exs bash e2e/bin/server.sh
#
# Everything here is written through the same context modules the app uses,
# then backdated so the Costs page has two weeks of history. It never wakes an
# agent: messages go through `Canopy.Messages`, not the runtime.

import Ecto.Query

alias Canopy.{
  Agents,
  Channels,
  Delegations,
  Handoffs,
  Memory,
  Messages,
  Repo,
  Repositories,
  Schedules,
  Settings,
  Tasks,
  Timeline,
  Users
}

alias Canopy.Messages.Message
alias Canopy.Timeline.Event

root = File.cwd!()
now = DateTime.utc_now()
ago = fn minutes -> DateTime.add(now, -round(minutes * 60), :second) end

days_ago = fn days, hour ->
  now
  |> DateTime.add(-days * 86_400, :second)
  |> Map.merge(%{hour: hour, minute: :rand.uniform(59), second: :rand.uniform(59)})
end

:rand.seed(:exsss, {2026, 9, 11})

# -- The local user ---------------------------------------------------------------

{:ok, _} = Settings.update(%{user_display_name: "Priya", chatter_limit: 6})
user = Users.local()
user = user |> Ecto.Changeset.change(display_name: "Priya") |> Repo.update!()

# -- Repositories -----------------------------------------------------------------

make_repo = fn name, files ->
  path = Path.join([root, "tmp", name])
  File.rm_rf!(path)
  File.mkdir_p!(path)

  for {rel, body} <- files do
    full = Path.join(path, rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, body)
  end

  git = fn args ->
    {_, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
  end

  git.(["init", "-q", "-b", "main"])
  git.(["add", "-A"])

  git.([
    "-c",
    "user.email=dev@acme.example",
    "-c",
    "user.name=Acme Dev",
    "commit",
    "-q",
    "-m",
    "Initial import"
  ])

  path
end

payments_py = """
import logging
from acme.billing import gateway, invoices

log = logging.getLogger(__name__)


def enqueue_charge(invoice_id: str) -> None:
    invoice = invoices.get(invoice_id)
    if invoice.status == "paid":
        return
    gateway.charge(invoice.customer_id, invoice.amount_cents)
    invoices.mark_paid(invoice_id)
    log.info("charged %s", invoice_id)
"""

retry_worker_py = """
from acme.billing import payments, queue


def run_once() -> int:
    handled = 0
    for job in queue.pop_failed(limit=100):
        payments.enqueue_charge(job.invoice_id)
        handled += 1
    return handled
"""

webhooks_py = """
from acme.billing import payments


def on_payment_failed(event: dict) -> None:
    payments.enqueue_charge(event["invoice_id"])
"""

test_payments_py = """
from acme.billing import payments


def test_paid_invoice_is_skipped(paid_invoice):
    payments.enqueue_charge(paid_invoice.id)
    assert paid_invoice.charges == 1
"""

billing_path =
  make_repo.("acme-billing", [
    {"README.md", "# acme-billing\n\nInvoice, retry and webhook workers for Acme.\n"},
    {"acme/billing/payments.py", payments_py},
    {"acme/billing/retry_worker.py", retry_worker_py},
    {"acme/billing/webhooks.py", webhooks_py},
    {"tests/test_payments.py", test_payments_py}
  ])

storefront_path =
  make_repo.("acme-storefront", [
    {"README.md",
     "# acme-storefront\n\nThe Acme web shop: Next.js front end and checkout API.\n"},
    {"src/checkout/session.ts",
     "export async function createSession(cart: Cart) {\n  const totals = await priceCart(cart)\n  return sessions.create({ cart, totals })\n}\n"}
  ])

if old = Repositories.get_by_path(Path.join([root, "tmp", "e2e-repo"])), do: Repo.delete!(old)

{:ok, billing} = Repositories.create(%{name: "acme-billing", path: billing_path})
{:ok, storefront} = Repositories.create(%{name: "acme-storefront", path: storefront_path})

# Leave the fix in the working tree so the Changes modal has something to show.
File.write!(
  Path.join(billing_path, "acme/billing/payments.py"),
  String.replace(
    payments_py,
    "    gateway.charge(invoice.customer_id, invoice.amount_cents)\n",
    "    if not invoices.claim_charge(invoice_id):\n        log.info(\"charge for %s already in flight\", invoice_id)\n        return\n    gateway.charge(invoice.customer_id, invoice.amount_cents)\n"
  )
)

File.write!(
  Path.join(billing_path, "tests/test_payments.py"),
  test_payments_py <>
    "\n\ndef test_concurrent_retries_charge_once(open_invoice):\n    payments.enqueue_charge(open_invoice.id)\n    payments.enqueue_charge(open_invoice.id)\n    assert open_invoice.charges == 1\n"
)

# -- Agents -----------------------------------------------------------------------

set_model = fn name, model_id ->
  agent = Agents.get_by_name(name)
  {:ok, agent} = Agents.update(agent, %{model_provider: "opencode", model_id: model_id})
  agent
end

backend = set_model.("backend", "claude-haiku-4-5")
reviewer = set_model.("reviewer", "gpt-5-nano")
researcher = set_model.("researcher", "gpt-5-nano")
test_agent = set_model.("test", "gpt-5-nano")

{:ok, finops} =
  Agents.create(%{
    name: "finops",
    display_name: "FinOps",
    role: "Watches model spend and recommends savings",
    color: "#0891b2",
    model_provider: "opencode",
    model_id: "gpt-5-nano",
    system_prompt: """
    You are @finops. You read the spend report, compare agents, channels and
    models, and recommend concrete changes that lower the bill without slowing
    the team down. Rank recommendations by expected savings and say what each
    one costs in quality or speed. You never change settings yourself.
    """
  })

{:ok, docs} =
  Agents.create(%{
    name: "docs",
    display_name: "Docs",
    role: "Keeps the developer documentation current",
    color: "#9333ea",
    system_prompt: "You are @docs. You update READMEs and guides after changes land."
  })

{:ok, _} = Agents.deactivate(docs)

{:ok, _} = Canopy.Costs.Auditor.assign(finops.id)

{:ok, _} =
  Memory.put(backend.id, """
  - Priya prefers small PRs: one behaviour change per PR, tests in the same change.
  - acme-billing runs on Postgres 16; the retry worker deploys with `make deploy-worker`.
  - Charges must be idempotent per invoice: use `invoices.claim_charge` before `gateway.charge`.
  """)

{:ok, _} =
  Memory.put(researcher.id, """
  - In acme-billing every path to the payment gateway goes through `payments.enqueue_charge`.
  - Priya wants file and line references in findings.
  """)

# -- Helpers -----------------------------------------------------------------------

model_of = fn agent -> "opencode/#{agent.model_id}" end

price = fn
  "claude-haiku-4-5" -> {1.0, 5.0, 0.1}
  _ -> {0.05, 0.4, 0.005}
end

cost_of = fn agent, tokens ->
  {input, output, cache} = price.(agent.model_id)

  Float.round(
    tokens["input"] / 1.0e6 * input + tokens["output"] / 1.0e6 * output +
      tokens["cache_read"] / 1.0e6 * cache + tokens["reasoning"] / 1.0e6 * output,
    4
  )
end

tokens_for = fn steps, context ->
  total_prompt = steps * context
  cache_read = round(total_prompt * 0.78)

  %{
    "input" => total_prompt - cache_read,
    "output" => steps * (180 + :rand.uniform(260)),
    "reasoning" => steps * :rand.uniform(120),
    "cache_read" => cache_read,
    "cache_write" => round(context * 0.15)
  }
end

stamp = fn channel_id, t ->
  Repo.update_all(
    from(e in Event, where: e.channel_id == ^channel_id and e.inserted_at > ^t),
    set: [inserted_at: t, updated_at: t]
  )

  Repo.update_all(
    from(m in Message, where: m.channel_id == ^channel_id and m.inserted_at > ^t),
    set: [inserted_at: t, updated_at: t]
  )
end

tool = fn label, detail ->
  %{"kind" => "tool", "status" => "ok", "label" => label, "detail" => detail}
end

file = fn path ->
  %{"kind" => "file", "status" => "ok", "label" => Path.basename(path), "detail" => path}
end

with_keys = fn entries ->
  entries |> Enum.with_index() |> Enum.map(fn {e, i} -> Map.put(e, "key", "k#{i}") end)
end

# A finished agent turn: the "started working" line, then the summary line
# with the same payload the runtime writes.
turn = fn channel, agent, opts ->
  {:ok, _} =
    Timeline.record(%{
      channel_id: channel.id,
      agent_id: agent.id,
      event_type: "agent_started",
      payload: %{}
    })

  steps = Map.get(opts, :steps, 2)
  context = Map.get(opts, :context, 12_000)
  tokens = Map.get(opts, :tokens, tokens_for.(steps, context))
  activity = with_keys.(Map.get(opts, :activity, []))

  {:ok, event} =
    Timeline.record(%{
      channel_id: channel.id,
      agent_id: agent.id,
      event_type: "agent_turn_completed",
      payload: %{
        "tools" => Map.get(opts, :tools, length(activity)),
        "files" => Map.get(opts, :files, []),
        "cost" => Map.get(opts, :cost, cost_of.(agent, tokens)),
        "duration_ms" => Map.get(opts, :duration_ms, 20_000 + :rand.uniform(40_000)),
        "outcome" => Map.get(opts, :outcome, "ok"),
        "model" => model_of.(agent),
        "delegation_id" => nil,
        "activity" => activity,
        "passed" => Map.get(opts, :passed, false),
        "note" => Map.get(opts, :note),
        "trigger" => Map.get(opts, :trigger, "user"),
        "steps" => steps,
        "context" => context,
        "tokens" => tokens,
        "final_text" => Map.get(opts, :final_text)
      }
    })

  event
end

# -- A billing hold, released in the guide ----------------------------------------------
#
# Engaged before any schedule exists, so releasing it later pauses and resumes
# nothing and the channel timelines stay clean.

:ok = Canopy.Hold.engage("OpenCode reported: insufficient balance for opencode/claude-haiku-4-5")

# -- Channels -----------------------------------------------------------------------

{:ok, retries} =
  Channels.create(%{
    repository_id: billing.id,
    name: "payment-retries",
    topic: "Invoices are occasionally charged twice",
    owner_agent_id: backend.id,
    agent_ids: [researcher.id, reviewer.id, test_agent.id],
    task_title: "Stop duplicate charges from the retry paths"
  })

{:ok, pdf_export} =
  Channels.create(%{
    repository_id: billing.id,
    name: "invoice-pdf-export",
    topic: "Export invoices as PDF from the admin",
    owner_agent_id: backend.id,
    agent_ids: [test_agent.id, reviewer.id]
  })

{:ok, tax_rates} =
  Channels.create(%{
    repository_id: billing.id,
    name: "q3-tax-rates",
    topic: "Update EU VAT rates for Q3",
    owner_agent_id: researcher.id,
    agent_ids: [backend.id]
  })

{:ok, latency} =
  Channels.create(%{
    repository_id: storefront.id,
    name: "checkout-latency",
    topic: "p95 checkout time doubled since Tuesday",
    owner_agent_id: researcher.id,
    agent_ids: [backend.id, test_agent.id]
  })

{:ok, brand_logo} =
  Channels.create(%{
    repository_id: storefront.id,
    name: "brand-logo",
    topic: "New logo for the storefront header and login page",
    owner_agent_id: researcher.id,
    agent_ids: [reviewer.id]
  })

{:ok, reviewer_dm} = Channels.ensure_dm(billing.id, reviewer)
{:ok, finops_dm} = Channels.ensure_dm(billing.id, finops)

# -- Two weeks of history for the Costs page ------------------------------------------

history = [
  {latency, researcher, "user"},
  {latency, backend, "agent"},
  {pdf_export, backend, "user"},
  {pdf_export, test_agent, "delegation"},
  {pdf_export, reviewer, "handoff"},
  {tax_rates, researcher, "user"},
  {tax_rates, researcher, "scheduled"},
  {retries, backend, "user"},
  {retries, researcher, "agent"},
  {reviewer_dm, reviewer, "user"}
]

for day <- 14..1//-1, _ <- 1..(2 + :rand.uniform(5)) do
  {channel, agent, trigger} = Enum.random(history)
  steps = 1 + :rand.uniform(4)
  context = 6_000 + :rand.uniform(30_000)
  roll = :rand.uniform(20)

  opts =
    cond do
      roll == 1 -> %{outcome: "error", steps: 1, context: context}
      roll in 2..3 -> %{passed: true, note: "nothing to add", steps: 1, context: 4_000}
      true -> %{steps: steps, context: context}
    end

  tools = if opts[:passed], do: 1, else: steps + :rand.uniform(3)
  turn.(channel, agent, Map.merge(opts, %{trigger: trigger, tools: tools}))
  stamp.(channel.id, days_ago.(day, 8 + :rand.uniform(9)))
end

{:ok, _} =
  Timeline.record(%{
    channel_id: latency.id,
    agent_id: researcher.id,
    event_type: "session_compacted",
    payload: %{"context" => 41_200, "cap" => 40_000}
  })

stamp.(latency.id, days_ago.(3, 15))

# -- #q3-tax-rates: done and archived ------------------------------------------------

{:ok, _} =
  Messages.post_user_message(
    tax_rates.id,
    user.id,
    "The Q3 VAT table landed in `rates/eu-2026-q3.csv`. Please check it against the Commission's list and post anything that differs."
  )

stamp.(tax_rates.id, days_ago.(6, 10))

turn.(tax_rates, researcher, %{
  trigger: "user",
  steps: 3,
  context: 14_000,
  activity: [
    tool.("read", "rates/eu-2026-q3.csv"),
    tool.("webfetch", "taxation-customs.ec.europa.eu"),
    tool.("canopy_message_send", nil)
  ]
})

{:ok, _} =
  Messages.post_agent_message(
    tax_rates.id,
    researcher.id,
    "Checked all 27 rows. One difference: **Estonia** moves from 22% to **24%** on 1 July; the CSV still says 22%. Everything else matches."
  )

stamp.(tax_rates.id, days_ago.(6, 10))
{:ok, _} = Messages.post_user_message(tax_rates.id, user.id, "Fixed, thanks. Closing this one.")
{:ok, _} = Channels.archive(tax_rates)
stamp.(tax_rates.id, days_ago.(5, 9))

# -- #checkout-latency ---------------------------------------------------------------

{:ok, _} =
  Messages.post_user_message(
    latency.id,
    user.id,
    "p95 for `POST /checkout/session` went from 380ms to 810ms on Tuesday. Nothing obvious in the deploy log. Can you find what changed?"
  )

stamp.(latency.id, days_ago.(2, 11))

turn.(latency, researcher, %{
  trigger: "user",
  steps: 4,
  context: 27_000,
  activity: [
    tool.("bash", "git log --since=2026-09-08 --stat"),
    tool.("read", "src/checkout/session.ts"),
    tool.("grep", "priceCart"),
    tool.("canopy_message_send", nil)
  ]
})

{:ok, latency_post} =
  Messages.post_agent_message(
    latency.id,
    researcher.id,
    """
    Tuesday's deploy added a second `priceCart` call inside `createSession` (`src/checkout/session.ts:12`), so every session now prices the cart twice, and the pricing service is the slow part.

    - Before: 1 call, ~350ms
    - After: 2 calls in sequence, ~750ms

    Suggest caching the first result on the request. @backend, want me to open a channel for the fix?
    """
  )

stamp.(latency.id, days_ago.(2, 11))

turn.(latency, backend, %{
  trigger: "agent",
  steps: 1,
  context: 9_000,
  activity: [tool.("canopy_thread_reply", nil)]
})

{:ok, _} =
  Messages.thread_reply(
    latency_post.id,
    {:agent, backend.id},
    "Yes, but let's wait for Priya to confirm the cache scope first. Per-request is safe; per-cart needs invalidation."
  )

stamp.(latency.id, days_ago.(2, 11))

{:ok, _} =
  Schedules.create(%{
    channel_id: latency.id,
    agent_id: researcher.id,
    created_by_agent_id: researcher.id,
    instruction:
      "Post the p95 checkout latency for the last 24 hours and flag any change over 20%",
    when: "0 8 * * *"
  })

stamp.(latency.id, days_ago.(2, 11))

# -- #brand-logo: asking for feedback on an image ----------------------------------------

{:ok, logo} =
  Canopy.Documents.create(%{
    filename: "canopy-logo.png",
    mime: "image/png",
    source: {:path, Path.expand("../fixtures/canopy-logo.png", __DIR__)},
    user_id: user.id,
    origin_channel_id: brand_logo.id,
    caption: "Logo proposal from marketing, 800 px master"
  })

{:ok, _} =
  Messages.post_user_message(
    brand_logo.id,
    user.id,
    "Marketing sent over the new logo. It goes in the storefront header at 32px and on the login page at full size. @researcher, does it hold up at header size, and is there anything you'd change before it ships?",
    attachments: [logo.id]
  )

stamp.(brand_logo.id, days_ago.(1, 16))

turn.(brand_logo, researcher, %{
  trigger: "user",
  steps: 3,
  context: 14_500,
  duration_ms: 39_000,
  activity: [
    tool.("read", "src/components/Header.tsx"),
    tool.("grep", "logo"),
    tool.("canopy_message_send", nil)
  ],
  final_text: "Posted feedback on the logo with two changes before it ships."
})

{:ok, _} =
  Messages.post_agent_message(
    brand_logo.id,
    researcher.id,
    """
    Looked at the mark against the header (`src/components/Header.tsx:18`, 32px on the navy bar).

    **Works well**
    - The toucan reads as one shape: dark wing, cream face, green beak. Silhouette survives at 32px.
    - Navy background matches the header's `#0b1a33`, so the mark can sit flat with no box.

    **Change before it ships**
    1. **Drop the wordmark at header size.** "Canopy" at 32px is 9px tall and the *y* descender clips the nav underline. Use the bird alone in the header; wordmark only on the login page.
    2. **The pale blue moon disappears on the header.** It is `#a8c4f5` on navy at about 3.2:1; at 32px it is a 4px dot. Either drop it from the small mark or brighten it to the cream of the face.

    **Nice to have**
    - Export an SVG; the PNG has soft edges on the beak at 2x.
    - The two leaves at the bottom right merge at small sizes; one leaf reads cleaner.

    Want me to cut the header-size variant and open a PR against the header component?
    """
  )

stamp.(brand_logo.id, days_ago.(1, 16))

# -- #invoice-pdf-export: over its spend limit ------------------------------------------

{:ok, _} =
  Messages.post_user_message(
    pdf_export.id,
    user.id,
    "Add an *Export PDF* button to the invoice page in the admin. Use the existing HTML template; no new dependencies."
  )

stamp.(pdf_export.id, days_ago.(1, 14))

turn.(pdf_export, backend, %{
  trigger: "user",
  steps: 9,
  context: 34_000,
  activity: [
    tool.("read", "admin/invoices/views.py"),
    tool.("grep", "render_invoice_html"),
    tool.("edit", "admin/invoices/views.py"),
    tool.("bash", "pytest tests/admin -q"),
    tool.("canopy_message_send", nil)
  ],
  files: ["admin/invoices/views.py"]
})

{:ok, _} =
  Messages.post_agent_message(
    pdf_export.id,
    backend.id,
    "First pass is in: `export_pdf` view renders the existing template through `weasyprint`, which is already a dependency of the statements job. 3 new tests pass. @test, could you cover the multi-page case?"
  )

stamp.(pdf_export.id, days_ago.(1, 14))

# A limit just under what the channel has spent, so the guide can show a
# channel that reached it.
pdf_spent = Canopy.Costs.channel_total(pdf_export.id)
pdf_limit = max(Float.round(pdf_spent * 0.85, 2), 0.05)
{:ok, pdf_export} = Channels.set_spend_limit(pdf_export, pdf_limit)
stamp.(pdf_export.id, days_ago.(1, 15))

{:ok, _} =
  Timeline.record(%{
    channel_id: pdf_export.id,
    event_type: "spend_limit_reached",
    ref_id: pdf_export.id,
    payload: %{"limit" => pdf_limit, "spent" => pdf_spent}
  })

stamp.(pdf_export.id, days_ago.(1, 15))

# -- #payment-retries: today's conversation --------------------------------------------

{:ok, retries} = Channels.set_spend_limit(retries, 5.0)
stamp.(retries.id, ago.(126))

# Priya attaches the admin screenshot from the support ticket; the runtime
# would send it to @backend as an image part.
{:ok, ticket_shot} =
  Canopy.Documents.create(%{
    filename: "support-ticket-4821.png",
    mime: "image/png",
    source: {:path, Path.expand("../fixtures/retry-log.png", __DIR__)},
    user_id: user.id,
    origin_channel_id: retries.id,
    caption: "Retry log for inv_88213 from the billing admin"
  })

{:ok, _} =
  Messages.post_user_message(
    retries.id,
    user.id,
    "Support has three reports this week of an invoice charged twice, always after a failed webhook. Here is the retry log from ticket #4821. Read `payments.py` and `retry_worker.py` and post a root-cause summary. Don't change any files yet.",
    attachments: [ticket_shot.id]
  )

stamp.(retries.id, ago.(124))

turn.(retries, backend, %{
  trigger: "user",
  steps: 3,
  context: 18_400,
  duration_ms: 48_300,
  activity: [
    tool.("read", "acme/billing/payments.py"),
    tool.("read", "acme/billing/retry_worker.py"),
    tool.("grep", "enqueue_charge"),
    tool.("canopy_message_send", nil)
  ],
  final_text: "Posted the root cause and asked @researcher to confirm the caller list."
})

{:ok, _} =
  Messages.post_agent_message(
    retries.id,
    backend.id,
    """
    **Root cause.** Two independent retry paths can both call `enqueue_charge` for the same invoice, and the only guard is `invoice.status == "paid"`, which is set *after* the gateway call returns:

    1. `retry_worker.py:7` pops failed jobs every minute and re-enqueues them.
    2. `webhooks.py:5` re-enqueues on every `payment_failed` event, including the retried attempt's own failure event.

    When the gateway is slow, both run inside the same window:

    ```python
    if invoice.status == "paid":   # both callers see "open"
        return
    gateway.charge(...)            # charged twice
    invoices.mark_paid(invoice_id)
    ```

    Before I propose a fix I want the full list of callers. Delegating that to @researcher.
    """
  )

stamp.(retries.id, ago.(122))

{:ok, delegation} =
  Delegations.create(%{
    channel_id: retries.id,
    task_id: retries.task.id,
    from_agent_id: backend.id,
    to_agent_id: researcher.id,
    description: "List every code path that can call enqueue_charge, with file and line."
  })

stamp.(retries.id, ago.(121))

turn.(retries, researcher, %{
  trigger: "delegation",
  steps: 2,
  context: 11_200,
  duration_ms: 31_000,
  activity: [
    tool.("grep", "enqueue_charge"),
    tool.("read", "acme/admin/replay.py"),
    tool.("canopy_task_update", nil)
  ]
})

# The researcher shares its full write-up as a file rather than a long post.
{:ok, callers_doc} =
  Canopy.Documents.create(%{
    filename: "enqueue-charge-callers.md",
    source:
      {:binary,
       """
       # Callers of `enqueue_charge`

       Every code path that can enqueue a charge for an invoice, with the guard it relies on.

       | # | Call site | Trigger | Guard before the call |
       |---|---|---|---|
       | 1 | `acme/billing/retry_worker.py:7` | cron, every minute | none (re-enqueues every failed job) |
       | 2 | `acme/billing/webhooks.py:5` | `payment_failed` webhook | none (fires for the retry's own failure too) |
       | 3 | `acme/admin/replay.py:17` | support's manual replay tool | operator confirmation only |

       ## Notes

       - 1 and 2 overlap whenever the gateway is slow: the worker pops the job while the
         failure webhook for the same attempt is still in flight.
       - 3 is rare but has the same race with 1; a replay during the worker's minute can
         double-charge in the same way.
       - `invoices.mark_paid` runs after `gateway.charge` returns, so every caller sees
         `status == "open"` until the first charge completes.

       Recommendation: one idempotency key per invoice attempt, checked before the gateway
       call, and a `charging` status set before the call rather than after.
       """},
    agent_id: researcher.id,
    origin_channel_id: retries.id,
    caption: "Full caller list with the guard each path relies on"
  })

{:ok, _} =
  Messages.post_agent_message(
    retries.id,
    researcher.id,
    "Full caller list attached; the short version is in the task result.",
    attachments: [callers_doc.id]
  )

{:ok, _} =
  Delegations.complete(
    delegation,
    "Three callers: retry_worker.py:7, webhooks.py:5, and admin/replay.py:17 (the manual replay tool support uses)."
  )

stamp.(retries.id, ago.(118))

turn.(retries, backend, %{
  trigger: "delegation",
  steps: 2,
  context: 21_900,
  duration_ms: 26_400,
  activity: [tool.("canopy_message_send", nil), tool.("canopy_task_update", nil)],
  final_text: "Plan posted; task moved to working."
})

{:ok, plan} =
  Messages.post_agent_message(
    retries.id,
    backend.id,
    """
    Three callers confirmed, so fixing the callers one by one is fragile. **Proposal:** make `enqueue_charge` itself idempotent.

    - Add `invoices.claim_charge(invoice_id)`: an `UPDATE … WHERE charge_claimed_at IS NULL` that returns whether this caller won.
    - Call it before `gateway.charge`; losers log and return.
    - Release the claim if the gateway raises, so a real failure can still be retried.

    One migration, ~20 lines in `payments.py`, one new test. @reviewer, does the claim approach look right to you before I start?
    """
  )

stamp.(retries.id, ago.(116))
{:ok, _} = Tasks.update(retries.task, %{status: "working"}, agent_id: backend.id)
stamp.(retries.id, ago.(116))

turn.(retries, reviewer, %{
  trigger: "agent",
  steps: 2,
  context: 13_600,
  duration_ms: 22_000,
  activity: [tool.("read", "acme/billing/payments.py"), tool.("canopy_thread_reply", nil)]
})

{:ok, _} =
  Messages.thread_reply(
    plan.id,
    {:agent, reviewer.id},
    "Looks right. Two asks: key the claim on `invoice_id` only (not attempt id), and make the release path a `finally` so a timeout does not leave the claim stuck."
  )

stamp.(retries.id, ago.(113))

{:ok, _} =
  Schedules.create(%{
    channel_id: retries.id,
    agent_id: backend.id,
    created_by_agent_id: backend.id,
    instruction: "Check the failed-charge queue depth and post here if it is above 50",
    when: "0 9 * * 1-5"
  })

stamp.(retries.id, ago.(112))

{:ok, _} =
  Messages.post_user_message(
    retries.id,
    user.id,
    "Go ahead with the claim approach, including @reviewer's two notes. Keep the PR small."
  )

stamp.(retries.id, ago.(64))

turn.(retries, backend, %{
  trigger: "user",
  steps: 5,
  context: 26_800,
  duration_ms: 142_000,
  files: ["acme/billing/payments.py", "acme/billing/invoices.py", "tests/test_payments.py"],
  activity: [
    tool.("read", "acme/billing/invoices.py"),
    tool.("edit", "acme/billing/invoices.py"),
    file.("acme/billing/invoices.py"),
    tool.("edit", "acme/billing/payments.py"),
    file.("acme/billing/payments.py"),
    tool.("edit", "tests/test_payments.py"),
    file.("tests/test_payments.py"),
    tool.("bash", "pytest tests/test_payments.py -q"),
    tool.("canopy_message_send", nil),
    tool.("canopy_handoff_task", nil)
  ],
  final_text: "Fix and test in the working tree; handed to @reviewer."
})

{:ok, _} =
  Messages.post_agent_message(
    retries.id,
    backend.id,
    """
    Done, in the working tree:

    - `invoices.claim_charge` with the `UPDATE … RETURNING` guard, keyed on `invoice_id`.
    - `enqueue_charge` claims first, releases in a `finally` when the gateway raises.
    - New test `test_concurrent_retries_charge_once`.

    ```text
    $ pytest tests/test_payments.py -q
    15 passed in 2.1s
    ```

    Handing this to @reviewer for a second pair of eyes before we open the PR.
    """
  )

stamp.(retries.id, ago.(61))

{:ok, handoff} =
  Handoffs.request(%{
    channel_id: retries.id,
    task_id: retries.task.id,
    from_agent_id: backend.id,
    to_agent_id: reviewer.id,
    summary: "Idempotent enqueue_charge via invoices.claim_charge; 15 tests pass.",
    reason: "needs a second pair of eyes before the PR",
    suggested_next_step:
      "Review the diff, then ask @test for a load test if the claim query looks hot."
  })

stamp.(retries.id, ago.(61))
{:ok, _} = Handoffs.accept(handoff)
stamp.(retries.id, ago.(58))

turn.(retries, reviewer, %{
  trigger: "handoff",
  steps: 3,
  context: 19_300,
  duration_ms: 54_000,
  activity: [
    tool.("canopy_handoff_get", nil),
    tool.("bash", "git diff"),
    tool.("read", "tests/test_payments.py"),
    tool.("canopy_message_send", nil)
  ]
})

{:ok, _} =
  Messages.post_agent_message(
    retries.id,
    reviewer.id,
    """
    Reviewed the diff. Approving with two small notes, neither blocking:

    1. `claim_charge` should also skip invoices in `void` status, not just `paid`.
    2. The new test uses a real thread pool; a fake gateway with a latch would be faster and deterministic.

    Ready for a PR once Priya is happy.
    """
  )

stamp.(retries.id, ago.(53))

{:ok, _} =
  Messages.post_user_message(retries.id, user.id, "Great work all. I'll open the PR from here.")

stamp.(retries.id, ago.(12))

turn.(retries, reviewer, %{
  trigger: "user",
  steps: 1,
  context: 20_100,
  duration_ms: 6_000,
  passed: true,
  note: "nothing to add",
  activity: [tool.("canopy_pass", nil)]
})

stamp.(retries.id, ago.(11))

# -- DM with @reviewer ---------------------------------------------------------------

{:ok, _} =
  Messages.post_user_message(
    reviewer_dm.id,
    user.id,
    "Can you draft a short review checklist for changes under `acme/billing/`? I'd like to pin it in the repo."
  )

stamp.(reviewer_dm.id, days_ago.(1, 9))

turn.(reviewer_dm, reviewer, %{
  trigger: "user",
  steps: 2,
  context: 8_900,
  activity: [tool.("glob", "acme/billing/**"), tool.("canopy_message_send", nil)]
})

{:ok, _} =
  Messages.post_agent_message(
    reviewer_dm.id,
    reviewer.id,
    """
    Draft checklist for `acme/billing/`:

    - [ ] Every gateway call is idempotent per invoice
    - [ ] Money is in integer cents, never floats
    - [ ] New retry paths are listed in `docs/retries.md`
    - [ ] Migrations are reversible and run in under a minute on prod-size tables
    - [ ] Tests cover the failure path, not only the happy path

    Want me to save this as `docs/REVIEW.md` in a new channel?
    """
  )

stamp.(reviewer_dm.id, days_ago.(1, 9))

# -- DM with @finops: an audit -------------------------------------------------------

{:ok, _} =
  Messages.post_user_message(
    finops_dm.id,
    user.id,
    Canopy.Costs.Auditor.prompt(finops, "scheduled tasks and the haiku model on @backend")
  )

stamp.(finops_dm.id, ago.(35))

turn.(finops_dm, finops, %{
  trigger: "user",
  steps: 2,
  context: 9_800,
  duration_ms: 38_000,
  activity: [tool.("canopy_costs_report", "period: week"), tool.("canopy_message_send", nil)]
})

{:ok, _} =
  Messages.post_agent_message(
    finops_dm.id,
    finops.id,
    """
    I read this week's report. Ranked by expected savings:

    1. **Move @backend's routine turns to gpt-5-nano** (about 55% of the week). Haiku is 20x the price per token; keep it for edits in `#payment-retries` and let nano handle acknowledgements and status posts. Expected saving: roughly a third of the weekly total.
    2. **Widen the daily latency schedule in `#checkout-latency`** from every day to weekdays. It fires with 27k tokens of context each time and has flagged nothing in a week. Saving: small, but it is pure waste.
    3. **Leave the `#invoice-pdf-export` limit where it is** until the multi-page case is scoped; it hit the limit after one long turn, which suggests the task needs splitting rather than more budget.

    No change to the chatter limit: 6 turns has not been reached this week. Tell me which of these you want and I will draft the exact settings.
    """
  )

stamp.(finops_dm.id, ago.(33))

IO.puts(
  "seeded the Acme workspace: #{length(Channels.list())} channels, #{length(Agents.list())} agents"
)
