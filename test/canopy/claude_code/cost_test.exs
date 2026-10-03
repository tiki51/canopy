defmodule Canopy.ClaudeCode.CostTest do
  use ExUnit.Case, async: true

  alias Canopy.ClaudeCode.{Cost, Events, Transcript}
  alias Canopy.Engine.Event

  @sid "0e8e9d04-2be4-4079-8284-1102c6d02bf4"
  @other "5d20c6d5-6789-4d32-a5fc-d7f78e538c48"

  setup do
    dir =
      Path.join([
        File.cwd!(),
        "_build",
        "test",
        "tmp",
        "cost-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp line(map), do: JSON.encode!(map) <> "\n"

  defp cost_state(sid, total),
    do: line(%{type: "cost-state", sessionId: sid, totalCostUSD: total})

  defp user(sid), do: line(%{type: "user", sessionId: sid, message: %{content: "hi"}})

  defp transcript!(dir, body, repo \\ "/work/repo") do
    folder = Path.join([dir, "projects", Transcript.encode(repo)])
    File.mkdir_p!(folder)
    path = Path.join(folder, @sid <> ".jsonl")
    File.write!(path, body)
    path
  end

  describe "bases/3" do
    test "a new session starts at zero" do
      assert Cost.bases(:new, {:ok, 1.0}, 2.0) == []
    end

    test "a resumed one: the transcript's total and the last seen" do
      assert Cost.bases(:resume, {:ok, 1.0}, 0.9) == [1.0, 0.9]
      assert Cost.bases(:resume, {:ok, 1.0}, nil) == [1.0]
    end

    test "no saved total in the transcript: the CLI does not restore, zero only" do
      assert Cost.bases(:resume, :none, 0.9) == []
    end

    test "no readable transcript: the last total seen" do
      assert Cost.bases(:resume, :unknown, 0.9) == [0.9]
      assert Cost.bases(:resume, :unknown, nil) == []
    end
  end

  describe "restored_total/3" do
    test "the session's last cost-state wins; another session's is ignored", ctx do
      transcript!(
        ctx.dir,
        user(@sid) <>
          cost_state(@sid, 0.3) <> cost_state(@sid, 0.7405) <> cost_state(@other, 9.0)
      )

      assert Cost.restored_total(ctx.dir, @sid, "/work/repo") == {:ok, 0.7405}
    end

    test "a transcript without one: :none; no transcript: :unknown", ctx do
      transcript!(ctx.dir, user(@sid) <> line(%{type: "assistant", sessionId: @sid}))
      assert Cost.restored_total(ctx.dir, @sid, "/work/repo") == :none
      assert Cost.restored_total(ctx.dir, Ecto.UUID.generate(), "/work/repo") == :unknown
    end

    test "a half-written last line is skipped", ctx do
      transcript!(
        ctx.dir,
        user(@sid) <> cost_state(@sid, 0.5) <> ~s({"type":"cost-state","sessionId":"#{@sid}","tot)
      )

      assert Cost.restored_total(ctx.dir, @sid, "/work/repo") == {:ok, 0.5}
    end

    test "found far from the end, and across a chunk boundary", ctx do
      # long tool output after the last cost-state: several chunks back
      filler = line(%{type: "user", sessionId: @sid, content: String.duplicate("x", 700_000)})
      path = transcript!(ctx.dir, user(@sid) <> cost_state(@sid, 1.25) <> filler <> filler)
      assert Cost.last_cost_state(path, @sid) == {:ok, 1.25}

      # the cost-state line straddles the boundary of the last 256 KiB chunk
      # (the chunk starts 40 bytes before the end of the cost-state line)
      prefix = ~s({"type":"user","sessionId":"#{@sid}","content":")
      suffix = ~s("}\n)
      pad = 262_144 - 40 - byte_size(prefix) - byte_size(suffix)
      tail = prefix <> String.duplicate("y", pad) <> suffix
      assert byte_size(tail) == 262_144 - 40
      path = transcript!(ctx.dir, user(@sid) <> cost_state(@sid, 2.5) <> tail)
      assert Cost.last_cost_state(path, @sid) == {:ok, 2.5}
    end
  end

  describe "the turn's cost from cumulative results" do
    defp result(total),
      do: %{
        "type" => "result",
        "subtype" => "success",
        "is_error" => false,
        "total_cost_usd" => total,
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      }

    defp costs(acc, totals) do
      {events, _acc} =
        Enum.flat_map_reduce(totals, acc, fn total, acc ->
          Events.normalize(result(total), acc)
        end)

      for %Event{type: :turn_usage, data: %{cost: cost}} <- events, do: Float.round(cost, 6)
    end

    test "two turns of one session, then a reset" do
      # the session's first process
      assert costs(Events.new(nil), [0.358]) == [0.358]
      # resumed from the transcript's $0.358: the second turn cost $0.382
      assert costs(Events.new(nil, cost_bases: [0.358, 0.358]), [0.740]) == [0.382]
      # after a reset the new session's first process starts at zero
      assert costs(Events.new(nil), [0.02]) == [0.02]
    end

    test "several results in one process (a steered turn) are cumulative too" do
      assert costs(Events.new(nil, cost_bases: [1.0]), [1.1, 1.25, 1.3]) == [0.1, 0.15, 0.05]
    end

    test "a stale branch: the largest base not above the total" do
      # a compaction that started before the previous process saved its
      # final total restores the older one and adds nothing
      assert costs(Events.new(nil, cost_bases: [1.7083, 3.1587]), [1.7083]) == [0.0]
      # a process that started over counts from zero
      assert costs(Events.new(nil, cost_bases: [0.4011]), [0.1327]) == [0.1327]
    end
  end
end
