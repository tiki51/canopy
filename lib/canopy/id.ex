defmodule Canopy.ID do
  @moduledoc """
  Prefixed, time-ordered identifiers (`"msg_01J..."`).

  The part after the prefix is a ULID: a 48-bit millisecond timestamp followed by
  80 random bits, encoded as 26 Crockford base32 characters. Ids therefore sort
  lexicographically by creation time, which is what the timeline cursor relies on.

  Within one process, ids generated in the same millisecond are made strictly
  increasing by incrementing the random part, so consecutive calls always sort in
  call order. Across processes the order within a millisecond is random, as in
  the ULID specification.
  """

  @alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  @ulid_regex ~r/^[0-7][0-9A-HJKMNP-TV-Z]{25}$/
  @prefix_regex ~r/^[a-z][a-z0-9]*$/
  @max_random Integer.pow(2, 80) - 1

  @doc """
  Generates a new id with the given prefix, for example `generate("msg")`.
  """
  @spec generate(String.t()) :: String.t()
  def generate(prefix) when is_binary(prefix) do
    unless Regex.match?(@prefix_regex, prefix) do
      raise ArgumentError, "invalid id prefix: #{inspect(prefix)}"
    end

    {timestamp, random} = next(System.system_time(:millisecond))
    prefix <> "_" <> encode(<<0::2, timestamp::48, random::80>>)
  end

  @doc """
  Returns the prefix of a valid id (`"msg_01J..."` -> `"msg"`), or `nil`.
  """
  @spec prefix(term()) :: String.t() | nil
  def prefix(id) when is_binary(id) do
    case String.split(id, "_", parts: 2) do
      [prefix, ulid] ->
        if Regex.match?(@prefix_regex, prefix) and Regex.match?(@ulid_regex, ulid),
          do: prefix,
          else: nil

      _ ->
        nil
    end
  end

  def prefix(_), do: nil

  @doc """
  Returns true when `id` is a well-formed id carrying `prefix`.
  """
  @spec valid?(term(), String.t()) :: boolean()
  def valid?(id, prefix) when is_binary(id) and is_binary(prefix) do
    prefix(id) == prefix
  end

  def valid?(_, _), do: false

  @doc """
  Extracts the creation time encoded in a valid id.
  """
  @spec timestamp(String.t()) :: {:ok, DateTime.t()} | :error
  def timestamp(id) when is_binary(id) do
    with prefix when is_binary(prefix) <- prefix(id),
         ulid = binary_part(id, byte_size(prefix) + 1, 26),
         <<_::2, millis::48, _::80>> <- decode(ulid) do
      DateTime.from_unix(millis, :millisecond)
    else
      _ -> :error
    end
  end

  # Monotonic-within-process ULID state, keyed in the process dictionary.
  defp next(now) do
    key = {__MODULE__, :last}

    value =
      case Process.get(key) do
        {last_ts, last_random} when last_ts >= now and last_random < @max_random ->
          {last_ts, last_random + 1}

        {last_ts, _} when last_ts >= now ->
          {last_ts + 1, random()}

        _ ->
          {now, random()}
      end

    Process.put(key, value)
    value
  end

  defp random do
    <<r::80>> = :crypto.strong_rand_bytes(10)
    r
  end

  defp encode(bits) do
    for <<c::5 <- bits>>, into: "", do: <<Enum.at(@alphabet, c)>>
  end

  defp decode(ulid) do
    for <<ch <- ulid>>, into: <<>> do
      case Enum.find_index(@alphabet, &(&1 == ch)) do
        nil -> <<0::5>>
        index -> <<index::5>>
      end
    end
  end
end
