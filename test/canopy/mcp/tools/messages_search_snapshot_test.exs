defmodule Canopy.MCP.Tools.MessagesSearchSnapshotTest do
  # canopy_messages_search moved from messages_fts onto the shared search
  # index. This output was captured from the messages_fts implementation, on
  # the same messages and queries, before the move: ranking, snippets, counts
  # and wording must stay exactly as they were.
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Canopy.MCPHelpers

  alias Canopy.Messages
  alias Canopy.MCP.Tools.MessagesSearch

  @bodies [
    "Duplicate invoices come from two independent retry paths in PaymentWorker",
    "Should the uniqueness guarantee live in the database layer? I think the retry worker should not care.",
    "The retry retry retry loop in `enqueue_charge` runs three times before giving up on the charge",
    "Lunch is at noon; nothing to do with payments.",
    "Café au lait: the naïve retry of lib/billing/worker.ex handle_info/2 drops the idempotency key",
    "A very long message about retries. " <>
      String.duplicate("filler words keep going here ", 20) <>
      "and finally the retry key is mentioned at the end"
  ]

  @queries [
    "retry",
    ~s("retry paths"),
    "retr*",
    "enqueue_charge",
    "worker",
    "database AND OR NOT",
    "payment*",
    "handle_info/2",
    "lib/billing/worker.ex",
    "cafe",
    "nothing-here",
    "retry key"
  ]

  @expected ~S"""
  === "retry"
  4 match(es) in #{channel} for "retry":
  [{m3}] @{agent} (just now): The **retry** **retry** **retry** loop in `enqueue_charge` runs three times before giving up on the...
  [{m1}] @{agent} (just now): Duplicate invoices come from two independent **retry** paths in PaymentWorker
  [{m2}] @{agent} (just now): Should the uniqueness guarantee live in the database layer? I think the **retry** worker should not...
  [{m5}] @{agent} (just now): ...the naïve **retry** of lib/billing/worker.ex handle_info/2 drops the idempotency key
  === "\"retry paths\""
  1 match(es) in #{channel} for "\"retry paths\"":
  [{m1}] @{agent} (just now): Duplicate invoices come from two independent **retry paths** in PaymentWorker
  === "retr*"
  4 match(es) in #{channel} for "retr*":
  [{m3}] @{agent} (just now): The **retry** **retry** **retry** loop in `enqueue_charge` runs three times before giving up on the...
  [{m1}] @{agent} (just now): Duplicate invoices come from two independent **retry** paths in PaymentWorker
  [{m2}] @{agent} (just now): Should the uniqueness guarantee live in the database layer? I think the **retry** worker should not...
  [{m5}] @{agent} (just now): ...the naïve **retry** of lib/billing/worker.ex handle_info/2 drops the idempotency key
  === "enqueue_charge"
  1 match(es) in #{channel} for "enqueue_charge":
  [{m3}] @{agent} (just now): The retry retry retry loop in `**enqueue_charge**` runs three times before giving up on the...
  === "worker"
  2 match(es) in #{channel} for "worker":
  [{m2}] @{agent} (just now): Should the uniqueness guarantee live in the database layer? I think the retry **worker** should not...
  [{m5}] @{agent} (just now): ...the naïve retry of lib/billing/**worker**.ex handle_info/2 drops the idempotency key
  === "database AND OR NOT"
  No messages in #{channel} match "database AND OR NOT".
  === "payment*"
  2 match(es) in #{channel} for "payment*":
  [{m4}] @{agent} (just now): Lunch is at noon; nothing to do with **payments**.
  [{m1}] @{agent} (just now): Duplicate invoices come from two independent retry paths in **PaymentWorker**
  === "handle_info/2"
  1 match(es) in #{channel} for "handle_info/2":
  [{m5}] @{agent} (just now): ...the naïve retry of lib/billing/worker.ex **handle_info/2** drops the idempotency key
  === "lib/billing/worker.ex"
  1 match(es) in #{channel} for "lib/billing/worker.ex":
  [{m5}] @{agent} (just now): ...the naïve retry of **lib/billing/worker.ex** handle_info/2 drops the idempotency key
  === "cafe"
  1 match(es) in #{channel} for "cafe":
  [{m5}] @{agent} (just now): **Café** au lait: the naïve retry of lib/billing/worker.ex handle_info/2 drops the...
  === "nothing-here"
  No messages in #{channel} match "nothing-here".
  === "retry key"
  2 match(es) in #{channel} for "retry key":
  [{m5}] @{agent} (just now): ...the naïve **retry** of lib/billing/worker.ex handle_info/2 drops the idempotency **key**
  [{m6}] @{agent} (just now): ...here filler words keep going here and finally the **retry** **key** is mentioned at the end
  """

  test "the output is the same as on the old message index" do
    ctx = scenario()
    other = channel_fixture()

    ids =
      for body <- @bodies do
        {:ok, message} = Messages.post_agent_message(ctx.channel.id, ctx.agent.id, body)
        message.id
      end

    # a match in another channel stays out
    {:ok, _} =
      Messages.post_agent_message(other.id, other.owner_agent_id, "retry paths elsewhere")

    # a finished turn shares the index without joining the results
    {:ok, _} =
      Canopy.Timeline.record(%{
        channel_id: ctx.channel.id,
        agent_id: ctx.agent.id,
        event_type: "agent_turn_completed",
        ref_id: ctx.session.id,
        payload: %{"files" => ["lib/billing/worker.ex"], "final_text" => "retry worker fixed"}
      })

    output =
      Enum.map_join(@queries, "\n", fn query ->
        {:ok, text} = call(MessagesSearch, %{query: query, limit: 4}, ctx)

        text =
          ids
          |> Enum.with_index(1)
          |> Enum.reduce(text, fn {id, i}, text -> String.replace(text, id, "{m#{i}}") end)
          |> String.replace(ctx.channel.name, "{channel}")
          |> String.replace(ctx.agent.name, "{agent}")

        "=== #{inspect(query)}\n#{text}"
      end)

    assert output == String.trim_trailing(@expected)
  end
end
