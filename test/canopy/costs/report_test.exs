defmodule Canopy.Costs.ReportTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Mox

  alias Canopy.Costs.Report
  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.Timeline

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    %{channel: channel, agent: agent} = scenario()
    coder = agent_fixture(%{name: "coder"})
    codex_session = session_fixture(%{channel: channel, agent_id: coder.id, engine: "codex"})
    %{channel: channel, agent: agent, coder: coder, codex_session: codex_session}
  end

  defp turn(channel, agent, ref, payload) do
    {:ok, _} =
      Timeline.record(%{
        channel_id: channel.id,
        agent_id: agent.id,
        event_type: "agent_turn_completed",
        ref_id: ref,
        payload: Map.merge(%{"outcome" => "ok", "tools" => 1, "duration_ms" => 1_000}, payload)
      })
  end

  defp codex_turn(ctx, model) do
    turn(ctx.channel, ctx.coder, ctx.codex_session.id, %{
      "engine" => "codex",
      "model" => model,
      "cost" => 0.4,
      "cost_estimated" => true,
      "trigger" => "user"
    })
  end

  test "a Codex-only period is priced from the Codex list prices, without asking OpenCode",
       ctx do
    codex_turn(ctx, "gpt-5-codex")
    me = self()

    stub(OC, :providers, fn _opts ->
      send(me, :asked_opencode)
      {:error, :down}
    end)

    text = Report.render(:week)

    assert text =~
             "- gpt-5-codex: ≈ $1.25 in / $10.00 out / $0.13 cached, per million tokens (OpenAI list price)"

    refute text =~ "unavailable"
    refute text =~ "price unknown"
    refute_received :asked_opencode

    # the estimate is marked where the money is shown
    assert text =~ "Total: $0.40 (≈ $0.40 estimated) over 1 turns"
    assert text =~ "- @coder: $0.40 (≈ $0.40 estimated) (100%)"
    assert text =~ "By engine:\n- Codex: $0.40 (≈ $0.40 estimated)"
    assert text =~ "Costliest turns:\n- ≈ $0.40 @coder"
  end

  test "a Codex model without a price of its own takes the default, and says so", ctx do
    codex_turn(ctx, "gpt-7-nova")
    stub(OC, :providers, fn _opts -> {:error, :down} end)

    assert Report.render(:week) =~
             ~r/- gpt-7-nova: ≈ \$[\d.]+ in .* \(OpenAI list price; no list price of its own, so the Codex default\)/
  end

  test "with OpenCode down, only the models left over are unavailable", ctx do
    codex_turn(ctx, "gpt-5-mini")
    turn(ctx.channel, ctx.agent, nil, %{"model" => "opencode/big", "cost" => 0.1})
    stub(OC, :providers, fn _opts -> {:error, :down} end)

    text = Report.render(:week)
    assert text =~ "Model prices:\n"
    assert text =~ "- gpt-5-mini: ≈ $0.25 in / $2.00 out / $0.025 cached"
    assert text =~ "- opencode/big: unavailable (OpenCode did not answer)"
  end

  test "with OpenCode up, the rest come from its catalogue", ctx do
    codex_turn(ctx, "gpt-5-codex")
    turn(ctx.channel, ctx.agent, nil, %{"model" => "opencode/big", "cost" => 0.1})

    stub(OC, :providers, fn _opts ->
      {:ok,
       %{
         "providers" => [
           %{
             "id" => "opencode",
             "models" => %{"big" => %{"cost" => %{"input" => 2, "output" => 8}}}
           }
         ]
       }}
    end)

    text = Report.render(:week)
    assert text =~ "- gpt-5-codex: ≈ $1.25 in"
    assert text =~ "- opencode/big: $2.00 in / $8.00 out"
  end
end
