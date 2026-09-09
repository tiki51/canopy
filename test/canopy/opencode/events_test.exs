defmodule Canopy.OpenCode.EventsTest do
  use ExUnit.Case, async: true

  alias Canopy.OpenCode.{Event, Events}
  alias Canopy.OpenCodeFixtures, as: Fixtures

  defp normalize_all(name), do: name |> Fixtures.events() |> Enum.flat_map(&Events.normalize/1)

  test "bootstrap noise and heartbeats normalize to nothing" do
    assert normalize_all("noise") == []
  end

  test "a read/bash/apply_patch turn yields the telemetry the UI needs" do
    events = normalize_all("turn_read_bash_patch")
    session = "ses_f7afbd250ffeYpTVGJ30g9OyRZ"

    started = for %Event{type: :tool_started, data: d} <- events, do: {d.tool, d.status}
    assert {"read", :pending} in started
    assert {"read", :running} in started
    assert {"bash", :running} in started
    assert {"apply_patch", :running} in started

    completed = for %Event{type: :tool_completed, data: d} <- events, do: d
    assert Enum.map(completed, & &1.tool) == ["read", "bash", "apply_patch"]
    assert Enum.all?(completed, &(&1.status == :ok))
    bash = Enum.find(completed, &(&1.tool == "bash"))
    assert bash.title == "ls -la"
    assert bash.input["command"] == "ls -la"
    assert bash.output =~ "README.md"

    assert [%Event{data: %{text: first}}, %Event{data: %{text: last}}] =
             Enum.filter(events, &(&1.type == :text_done))

    assert first =~ "Step 1"
    assert last =~ "PINEAPPLE"

    steps = for %Event{type: :step_completed, data: d} <- events, do: d
    assert length(steps) == 3
    assert Enum.map(steps, & &1.reason) == ["tool-calls", "tool-calls", "stop"]
    assert Enum.all?(steps, &is_number(&1.cost))

    assert [%Event{data: %{message_id: _, files: [_ | _]}}] =
             Enum.filter(events, &(&1.type == :patch))

    assert Enum.any?(
             events,
             &(&1.type == :file_changed and String.ends_with?(&1.data.path, "notes.txt"))
           )

    usage = for %Event{type: :turn_usage, data: d} <- events, do: d
    assert length(usage) >= 3
    assert Enum.all?(usage, &(is_number(&1.cost) and is_map(&1.tokens)))

    statuses =
      for %Event{type: :agent_status, session_id: ^session, data: d} <- events, do: d.status

    assert :busy in statuses
    assert List.last(statuses) == :idle
    assert Enum.any?(events, &(&1.type == :agent_completed and &1.session_id == session))

    assert Enum.all?(events, &(&1.raw_type != nil))

    refute Enum.any?(events, &(&1.type == :text_delta)),
           "deltas are attributed by the stream, not the normalizer"
  end

  test "text deltas surface as part_delta with part ids" do
    events = normalize_all("turn_read_bash_patch")
    deltas = Enum.filter(events, &(&1.type == :part_delta))
    assert deltas != []
    assert Enum.all?(deltas, &(is_binary(&1.data.part_id) and is_binary(&1.data.delta)))
  end

  test "permission round trip carries the diff and the reply" do
    events = normalize_all("permission_round_trip")

    assert [%Event{type: :approval_required, session_id: sid, data: %{request: req}}] =
             Enum.filter(events, &(&1.type == :approval_required))

    assert sid == "ses_f7af24eabffe51Eb1ntcmlt6My"
    assert req["id"] =~ ~r/^per_/
    assert req["permission"] == "edit"
    assert req["patterns"] == ["notes.txt"]
    assert req["metadata"]["diff"] =~ "+perm: test"
    assert %{"messageID" => _, "callID" => _} = req["tool"]

    assert [%Event{type: :approval_resolved, data: %{request_id: rid, reply: "once"}}] =
             Enum.filter(events, &(&1.type == :approval_resolved))

    assert rid == req["id"]

    idx_ask = Enum.find_index(events, &(&1.type == :approval_required))

    idx_done =
      Enum.find_index(events, &(&1.type == :tool_completed and &1.data.tool == "apply_patch"))

    assert idx_ask < idx_done
  end

  test "child session events keep their own session id" do
    events = normalize_all("child_session")
    assert events != []
    assert Enum.all?(events, &(&1.session_id == "ses_f7af786f6ffem06e6Zk6GVLAyF"))
    assert Enum.any?(events, &(&1.type == :agent_completed))
  end

  test "unknown or malformed input is ignored" do
    assert Events.normalize(%{"type" => "something.new", "properties" => %{}}) == []
    assert Events.normalize(%{"nope" => true}) == []
    assert Events.normalize("junk") == []
  end

  test "session_id/1 finds the id wherever OpenCode puts it" do
    assert Events.session_id(%{"properties" => %{"sessionID" => "ses_a"}}) == "ses_a"
    assert Events.session_id(%{"properties" => %{"part" => %{"sessionID" => "ses_b"}}}) == "ses_b"
    assert Events.session_id(%{"properties" => %{"info" => %{"sessionID" => "ses_c"}}}) == "ses_c"

    assert Events.session_id(%{
             "properties" => %{"info" => %{"id" => "ses_d", "projectID" => "p"}}
           }) == "ses_d"

    assert Events.session_id(%{"properties" => %{}}) == nil
  end
end
