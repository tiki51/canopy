defmodule Canopy.ClaudeCode.Cost do
  @moduledoc """
  Where a Claude Code process's cost total starts, so each turn records its
  own cost rather than the session's.

  Claude Code keeps a running cost per session. At the end of every query it
  writes a `cost-state` line into the session's transcript (`totalCostUSD`
  and friends, seen in 2.1.283), and a resumed process restores the last one
  for its session id before doing anything, so every `result` it prints
  carries `total_cost_usd` = the session's total so far. A transcript with no
  `cost-state` line for the session (an older CLI, or nothing finished yet)
  means the process starts at zero.

  `bases/3` gives `Canopy.ClaudeCode.Events` the totals a process may have
  started from; a result's cost is its total minus the largest base not above
  it (zero always counts):

    * the transcript's last `cost-state` for the session, read just before
      the process starts (what the CLI restores);
    * the last total Canopy saw for the session (`agent_sessions.cost_total`),
      for when the previous process saved its final state after Canopy read
      the transcript but before the new process did, or when the transcript
      cannot be read.

  When the transcript is readable and holds no `cost-state` for the session,
  only zero counts: the CLI does not restore, and the last total is from a
  process whose cost has already been recorded.
  """

  alias Canopy.ClaudeCode.Transcript

  @chunk 262_144
  # how far from the end of a transcript to look for the last cost-state;
  # the CLI writes one per query, so it is normally in the last chunk
  @scan_limit 33_554_432
  @marker "\"cost-state\""

  @doc """
  The bases for a process about to start: none for a new session (`:new`);
  for a resumed one, from the transcript and the last total seen.
  """
  @spec bases(:new | :resume, {:ok, number()} | :none | :unknown, number() | nil) :: [number()]
  def bases(:new, _restored, _last_total), do: []
  def bases(:resume, {:ok, total}, last_total), do: numbers([total, last_total])
  def bases(:resume, :none, _last_total), do: []
  def bases(:resume, :unknown, last_total), do: numbers([last_total])

  @doc """
  The session's last saved total in its transcript under `config_dir`:
  `{:ok, total}`, `:none` when the transcript has no `cost-state` line for the
  session, or `:unknown` when the transcript cannot be found or read (or the
  last #{div(@scan_limit, 1_048_576)} MB hold none).
  """
  @spec restored_total(String.t() | nil, String.t(), String.t() | nil) ::
          {:ok, number()} | :none | :unknown
  def restored_total(config_dir, sid, directory \\ nil) do
    case Transcript.locate(config_dir, sid, directory) do
      {:ok, path} -> last_cost_state(path, String.downcase(sid))
      _ -> :unknown
    end
  end

  @doc false
  def last_cost_state(path, sid) do
    case :file.open(path, [:read, :raw, :binary]) do
      {:ok, fd} ->
        try do
          {:ok, size} = :file.position(fd, :eof)
          scan(fd, sid, size, "", 0)
        after
          :file.close(fd)
        end

      _ ->
        :unknown
    end
  end

  # Reads backwards a chunk at a time; `carry` is the partial first line of
  # the chunk read before, completed by the next one (the first chunk of the
  # file has no partial line, so nothing is carried to position 0).
  defp scan(_fd, _sid, 0, _carry, _scanned), do: :none

  defp scan(_fd, _sid, _pos, _carry, scanned) when scanned >= @scan_limit, do: :unknown

  defp scan(fd, sid, pos, carry, scanned) do
    start = max(pos - @chunk, 0)

    case :file.pread(fd, start, pos - start) do
      {:ok, data} ->
        [first | rest] = :binary.split(data <> carry, "\n", [:global])
        {lines, carry} = if start == 0, do: {[first | rest], ""}, else: {rest, first}

        case lines |> Enum.reverse() |> Enum.find_value(&cost_state(&1, sid)) do
          nil -> scan(fd, sid, start, carry, scanned + (pos - start))
          total -> {:ok, total}
        end

      _ ->
        :unknown
    end
  end

  defp cost_state(line, sid) do
    if :binary.match(line, @marker) != :nomatch do
      case JSON.decode(line) do
        {:ok, %{"type" => "cost-state", "sessionId" => id, "totalCostUSD" => total}}
        when is_binary(id) and is_number(total) ->
          if String.downcase(id) == sid, do: total

        _ ->
          nil
      end
    end
  end

  defp numbers(list), do: for(n <- list, is_number(n), do: n)
end
