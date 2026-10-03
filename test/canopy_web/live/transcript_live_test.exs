defmodule CanopyWeb.TranscriptLiveTest do
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Canopy.{Engine, Fixtures, Timeline}
  alias Canopy.Engine.Event
  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.Repo
  alias Canopy.Timeline.Event, as: TimelineEvent

  setup :set_mox_global
  setup :verify_on_exit!

  @dir Path.expand("../../support/claude_code_fixtures/transcripts", __DIR__)
  @basic "aaaaaaaa-0000-4000-8000-000000000001"
  @compacted "aaaaaaaa-0000-4000-8000-000000000002"
  @planted "PlantedMcpToken0123456789abcdefXYZ"

  setup do
    previous = Application.get_env(:canopy, :claude_code, [])
    Application.put_env(:canopy, :claude_code, Keyword.put(previous, :config_dir, @dir))

    on_exit(fn ->
      Application.put_env(:canopy, :claude_code, previous)
      Application.delete_env(:canopy, :transcript_page_size)
      Application.delete_env(:canopy, :transcript_refresh_ms)
    end)

    coder =
      Fixtures.agent_fixture(%{name: "coder" <> Fixtures.unique_suffix(), engine: "claude_code"})

    scenario = Fixtures.scenario(members: [coder])

    session =
      Fixtures.session_fixture(%{
        channel: scenario.channel,
        agent_id: coder.id,
        engine: "claude_code",
        engine_session_id: @basic,
        mcp_token: @planted
      })

    Map.merge(scenario, %{coder: coder, coder_session: session})
  end

  defp tpath(ctx, query \\ []),
    do: ~p"/channels/#{ctx.channel.id}/agents/#{ctx.coder.id}/transcript?#{query}"

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view)
    view
  end

  test "renders the session: prompts, the system prompt, text, tools and steps", ctx do
    view = open(ctx.conn, tpath(ctx))

    assert has_element?(view, "#transcript-summary", "Claude Code")
    assert has_element?(view, "#transcript-summary", "8 entries")
    assert has_element?(view, "#transcript-system-canopy", "System prompt (Canopy")
    assert has_element?(view, "#transcript-system-engine", "Claude Code built-in (2 sections)")
    assert has_element?(view, "#transcript-entry-b-prompt-1", "Message ID: msg_basic1")
    assert has_element?(view, "#transcript-entry-b-a1-0", "payment code")
    assert has_element?(view, "#transcript-entry-b-a2-0", "Claude Code doesn't record the text")
    assert has_element?(view, "#transcript-entry-step-msg_01A", "claude-sonnet-5")
    assert has_element?(view, "#transcript-entry-b-a4-0-toggle", "Read lib/billing/payments.ex")
    refute has_element?(view, "#transcript-load-older")
  end

  test "a tool row opens to its input and output", ctx do
    view = open(ctx.conn, tpath(ctx))
    refute has_element?(view, "#transcript-entry-b-a4-0-body")

    view |> element("#transcript-entry-b-a4-0-toggle") |> render_click()
    assert has_element?(view, "#transcript-entry-b-a4-0-body", "File does not exist.")

    view |> element("#transcript-entry-b-a4-0-toggle") |> render_click()
    refute has_element?(view, "#transcript-entry-b-a4-0-body")
  end

  test "secrets are masked and marked; the planted token never reaches the page", ctx do
    view = open(ctx.conn, tpath(ctx))
    view |> element("#transcript-entry-b-a3-0-toggle") |> render_click()

    assert has_element?(view, "#transcript-entry-b-a3-0-redacted")
    assert has_element?(view, "#transcript-entry-b-a3-0-body", "[canopy session token]")

    html = render(view)
    refute html =~ @planted
    refute html =~ "sk-ant-api03"
    refute html =~ "priya.fixture@example.com"
  end

  test "load older pages back", ctx do
    Application.put_env(:canopy, :transcript_page_size, 2)
    view = open(ctx.conn, tpath(ctx))

    assert has_element?(view, "#transcript-entry-b-prompt-2")
    refute has_element?(view, "#transcript-entry-b-a5-0")

    view |> element("#transcript-load-older") |> render_click()
    render_async(view)
    assert has_element?(view, "#transcript-entry-b-a5-0", "Root cause")
    assert has_element?(view, "#transcript-entry-b-prompt-2")
  end

  test "?turn= lands on the turn and highlights its divider", ctx do
    now = ~U[2026-10-01 10:05:02.000000Z]

    turn =
      Repo.insert!(%TimelineEvent{
        channel_id: ctx.channel.id,
        agent_id: ctx.coder.id,
        event_type: "agent_turn_completed",
        ref_id: ctx.coder_session.id,
        payload: %{
          "tools" => 0,
          "outcome" => "ok",
          "trigger" => "user",
          "duration_ms" => 2_000,
          "engine_session_id" => @basic,
          "engine_message_ids" => %{"first" => "msg_02A", "last" => "msg_02A"}
        },
        inserted_at: now,
        updated_at: now
      })

    Application.put_env(:canopy, :transcript_page_size, 1)
    view = open(ctx.conn, tpath(ctx, turn: turn.id))

    assert has_element?(view, "#transcript-turn-#{turn.id}", "woken by your message")
    assert has_element?(view, "#transcript-turn-#{turn.id} .ring-primary\\/30")
    assert has_element?(view, "#transcript-entry-b-prompt-2")
    assert has_element?(view, "#transcript-load-older")
  end

  test "the session picker switches to a reset session", ctx do
    {:ok, _} =
      Timeline.record(%{
        channel_id: ctx.channel.id,
        agent_id: ctx.coder.id,
        event_type: "session_reset",
        ref_id: "as_old",
        payload: %{
          "by" => "user",
          "engine_session_id" => @compacted,
          "engine" => "claude_code",
          "directory" => "/tmp/canopy-repo"
        }
      })

    view = open(ctx.conn, tpath(ctx))
    assert has_element?(view, "#transcript-session-picker option", "Reset")

    view
    |> form("#transcript-session-form", %{session: @compacted})
    |> render_change()

    assert_patch(view, tpath(ctx, session: @compacted))
    render_async(view)

    assert has_element?(view, "#transcript-summary", "1 compaction")
    assert has_element?(view, "#transcript-entry-c-boundary", "Context compacted")
    assert has_element?(view, "#transcript-entry-system-1", "System prompt changed")
    # engine notes are there, hidden until shown
    assert has_element?(view, "#transcript-entries.hide-note [data-kind=engine_note]")
  end

  test "a session the engine no longer has", ctx do
    {:ok, _} =
      Timeline.record(%{
        channel_id: ctx.channel.id,
        agent_id: ctx.coder.id,
        event_type: "session_reset",
        ref_id: "as_gone",
        payload: %{
          "engine_session_id" => "aaaaaaaa-0000-4000-8000-0000000000ff",
          "engine" => "claude_code"
        }
      })

    view = open(ctx.conn, tpath(ctx, session: "aaaaaaaa-0000-4000-8000-0000000000ff"))
    assert has_element?(view, "#transcript-error", "Claude Code no longer has this session")
  end

  test "an agent that never worked here", ctx do
    view =
      open(
        ctx.conn,
        ~p"/channels/#{ctx.channel.id}/agents/#{Fixtures.agent_fixture().id}/transcript"
      )

    assert has_element?(view, "#transcript-empty", "No turns yet")
  end

  describe "an OpenCode agent" do
    defp oc_messages(texts) do
      for {text, i} <- Enum.with_index(texts, 1) do
        %{
          "info" => %{"id" => "msg_#{i}", "role" => "user", "time" => %{"created" => 1_000 * i}},
          "parts" => [%{"id" => "prt_#{i}", "type" => "text", "text" => text}]
        }
      end
    end

    test "can't reach OpenCode", ctx do
      expect(OC, :messages, fn _dir, _sid, [], _opts -> {:error, {:transport, :econnrefused}} end)

      view = open(ctx.conn, ~p"/channels/#{ctx.channel.id}/agents/#{ctx.agent.id}/transcript")
      assert has_element?(view, "#transcript-error", "Can't reach OpenCode")
    end

    test "follows the current session: an engine event appends what was added", ctx do
      Application.put_env(:canopy, :transcript_refresh_ms, 0)
      sid = ctx.session.engine_session_id
      test_pid = self()

      expect(OC, :messages, fn _dir, ^sid, [], _opts -> {:ok, oc_messages(["first wake"])} end)

      expect(OC, :messages, fn _dir, ^sid, [], _opts ->
        send(test_pid, :read_again)
        {:ok, oc_messages(["first wake", "second wake"])}
      end)

      view = open(ctx.conn, ~p"/channels/#{ctx.channel.id}/agents/#{ctx.agent.id}/transcript")
      assert has_element?(view, "#transcript-entry-msg_1", "first wake")
      refute has_element?(view, "#transcript-entry-msg_2")

      Phoenix.PubSub.broadcast(
        Canopy.PubSub,
        Engine.session_topic(sid),
        {:engine_event, %Event{type: :agent_completed, session_id: sid, data: %{}}}
      )

      assert_receive :read_again, 2_000
      _ = :sys.get_state(view.pid)
      render_async(view)

      assert has_element?(view, "#transcript-entry-msg_2", "second wake")
      assert has_element?(view, "#transcript-new", "1 new entry")

      view |> element("#transcript-follow") |> render_click()
      refute has_element?(view, "#transcript-new")
      assert has_element?(view, "#transcript-follow[aria-pressed=true]")
    end
  end
end
