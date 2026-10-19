defmodule CanopyWeb.TranscriptCodexTest do
  @moduledoc "The transcript page follows a Codex session renamed to its thread id."
  use CanopyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Canopy.{AgentSessions, Engine, Fixtures}

  setup do
    coder = Fixtures.agent_fixture(%{name: "coder" <> Fixtures.unique_suffix(), engine: "codex"})
    scenario = Fixtures.scenario(members: [coder])
    placeholder = Ecto.UUID.generate()

    session =
      Fixtures.session_fixture(%{
        channel: scenario.channel,
        agent_id: coder.id,
        engine: "codex",
        engine_session_id: placeholder
      })

    Map.merge(scenario, %{coder: coder, session: session, placeholder: placeholder})
  end

  test "a page opened before the first turn follows the session to its thread id", ctx do
    {:ok, view, _html} =
      live(ctx.conn, ~p"/channels/#{ctx.channel.id}/agents/#{ctx.coder.id}/transcript")

    render_async(view, 2_000)
    assert followed(view) == ctx.placeholder

    thread = Ecto.UUID.generate()
    {:ok, _} = AgentSessions.put_engine_session_id(ctx.session.id, thread)

    Phoenix.PubSub.broadcast(
      Canopy.PubSub,
      Engine.session_topic(ctx.placeholder),
      {:engine_session_renamed, ctx.placeholder, thread, nil}
    )

    render_async(view, 2_000)
    assert followed(view) == thread
  end

  defp followed(view), do: :sys.get_state(view.pid).socket.assigns.followed
end
