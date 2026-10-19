defmodule CanopyWeb.CodexCostsLiveTest do
  @moduledoc """
  Estimated (Codex) costs in the UI: `≈` on the Costs page, the By engine
  panel, the channel meter and the turn line, only where an estimate is in
  the figure.
  """
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Canopy.{Fixtures, Runtime, Timeline}
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global

  defp turn(ctx, payload) do
    {:ok, event} =
      Timeline.record(%{
        channel_id: ctx.channel.id,
        agent_id: ctx.agent.id,
        event_type: "agent_turn_completed",
        payload: Map.merge(%{"outcome" => "ok", "tools" => 1, "duration_ms" => 1_000}, payload)
      })

    event
  end

  defp codex_turn(ctx, cost) do
    turn(ctx, %{
      "cost" => cost,
      "cost_estimated" => true,
      "engine" => "codex",
      "model" => "gpt-5-codex",
      "tokens" => %{"input" => 17_200, "output" => 0, "cache_read" => 31_000}
    })
  end

  defp claude_turn(ctx, cost),
    do: turn(ctx, %{"cost" => cost, "engine" => "claude_code", "model" => "sonnet"})

  describe "the Costs page" do
    test "the subtitle says what ≈ means" do
      {:ok, view, _html} = live(build_conn(), ~p"/costs")

      assert render(view) =~
               "What agents spend. Claude Code and OpenCode report their costs; ≈ marks Codex costs estimated from tokens."
    end

    test "By engine is drawn with no turns, with the breakdowns' empty line" do
      {:ok, view, _html} = live(build_conn(), ~p"/costs")

      assert has_element?(view, "#by-engine", "Nothing in this period.")
      refute has_element?(view, "#by-engine-estimate-note")
    end

    test "rows in engine order, Codex's bar teal, ≈ only on estimated figures, and the footnote" do
      ctx = Fixtures.scenario()
      claude_turn(ctx, 0.65)
      codex_turn(ctx, 0.38)

      {:ok, view, html} = live(build_conn(), ~p"/costs")

      [claude, codex] =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#by-engine li")
        |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))

      assert {claude, codex} == {"by-engine-claude_code", "by-engine-codex"}
      assert has_element?(view, "#by-engine-codex", "≈$0.38")
      assert has_element?(view, "#by-engine-codex .bg-secondary")
      assert has_element?(view, "#by-engine-claude_code .bg-primary")
      assert has_element?(view, "#by-engine-claude_code", "$0.65")
      refute has_element?(view, "#by-engine-claude_code", "≈")
      assert has_element?(view, "#by-engine-estimate-note", "On a ChatGPT plan you pay the plan")

      assert has_element?(view, "#cost-all", "≈$1.03")

      assert has_element?(
               view,
               ~s(#cost-all [title="$0.65 reported · ≈$0.38 estimated from Codex tokens at OpenAI's API list prices"])
             )

      assert has_element?(view, "#by-agent-#{ctx.agent.id}", "≈$1.03")
    end

    test "the no-reply and error hints mark their estimates" do
      ctx = Fixtures.scenario()

      turn(ctx, %{"cost" => 0.1, "cost_estimated" => true, "engine" => "codex", "passed" => true})

      turn(ctx, %{
        "cost" => 0.2,
        "cost_estimated" => true,
        "engine" => "codex",
        "outcome" => "error"
      })

      turn(ctx, %{"cost" => 0.05, "engine" => "claude_code", "outcome" => "error"})

      {:ok, view, _html} = live(build_conn(), ~p"/costs")

      assert has_element?(view, "#eff-passed", "≈$0.10 for no reply")
      assert has_element?(view, "#eff-errors", "≈$0.25")
    end

    test "without estimates there is no ≈ anywhere" do
      ctx = Fixtures.scenario()
      claude_turn(ctx, 0.65)

      {:ok, view, _html} = live(build_conn(), ~p"/costs")

      assert has_element?(view, "#cost-all", "$0.65")
      refute render(view) =~ "≈$"
      refute has_element?(view, "#by-engine-estimate-note")
    end
  end

  describe "the channel" do
    setup do
      ctx = Fixtures.scenario()

      stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)

      stub(OC, :messages, fn _dir, _sid, _query, _opts -> {:ok, []} end)
      on_exit(fn -> Runtime.stop_channel(ctx.channel.id) end)
      ctx
    end

    test "the turn line gives the tokens and ≈ for an estimated turn, and is unchanged otherwise",
         ctx do
      codex = codex_turn(ctx, 0.3812)
      claude = claude_turn(ctx, 0.25)

      {:ok, view, _html} = live(ctx.conn, ~p"/channels/#{ctx.channel.id}")
      html = render(view)

      assert html =~ "48.2k tokens (31.0k cached)"
      assert html =~ "≈$0.3812"
      assert html =~ "$0.2500"
      refute html =~ "≈$0.2500"
      assert codex.id != claude.id
    end

    test "the spend meter marks an estimate and gives the split", ctx do
      claude_turn(ctx, 0.65)
      codex_turn(ctx, 0.38)

      {:ok, view, _html} = live(ctx.conn, ~p"/channels/#{ctx.channel.id}")

      assert has_element?(view, "#edit-budget", "≈$1.03")

      assert has_element?(
               view,
               ~s(#edit-budget[title="$0.65 reported · ≈$0.38 estimated from Codex tokens at OpenAI's API list prices"])
             )
    end
  end
end
