defmodule Canopy.OpenCode.MCPConfig do
  @moduledoc """
  OpenCode's config files, scanned for the `mcp` servers they define, so the
  repository page can say which file each server came from.

  OpenCode itself is the source of truth for what it loads (`GET /config`);
  its environment can differ from Canopy's (`OPENCODE_CONFIG`, remote config),
  so this scan only attributes names to files and shows values as written
  (`{env:API_KEY}` rather than the resolved secret).

  The files, in the order OpenCode merges them (a later file wins):

    1. global: `$XDG_CONFIG_HOME/opencode/opencode.json` and `opencode.jsonc`
    2. `OPENCODE_CONFIG`, a file named in Canopy's environment
    3. project: `opencode.json[c]` in every directory from the git root down
       to the repository (searched upward, stopping at the git root)
    4. `<repo>/.opencode/opencode.json[c]`

  JSONC comments and trailing commas are accepted (`strip_jsonc/1`).
  """

  @names ["opencode.json", "opencode.jsonc"]

  @doc """
  `%{servers: %{name => %{config, kind, path}}, errors: [String.t()]}`, where
  `kind` is `:global` or `:project` and `path` the last file that defined the
  name. A name's settings are merged across files the way OpenCode merges
  them, so `{"enabled": false}` in a later file keeps the earlier command.

  Options (tests point them at fixtures): `:config_home` (default
  `$XDG_CONFIG_HOME` or `~/.config`), `:opencode_config` (default
  `$OPENCODE_CONFIG`).
  """
  def sources(repository_path, opts \\ []) do
    config_home =
      opts[:config_home] || System.get_env("XDG_CONFIG_HOME") ||
        Path.join(System.user_home!(), ".config")

    custom = Keyword.get_lazy(opts, :opencode_config, fn -> System.get_env("OPENCODE_CONFIG") end)

    files =
      Enum.map(@names, &{:global, Path.join([config_home, "opencode", &1])}) ++
        if(is_binary(custom) and custom != "", do: [{:global, custom}], else: []) ++
        for(
          dir <- project_dirs(repository_path),
          name <- @names,
          do: {:project, Path.join(dir, name)}
        ) ++
        Enum.map(@names, &{:project, Path.join([repository_path, ".opencode", &1])})

    files
    |> Enum.uniq_by(&elem(&1, 1))
    |> Enum.reduce(%{servers: %{}, errors: []}, fn {kind, path}, acc ->
      case read(path) do
        :missing ->
          acc

        {:ok, %{"mcp" => mcp}} when is_map(mcp) ->
          servers =
            Enum.reduce(mcp, acc.servers, fn
              {name, config}, servers when is_map(config) ->
                merged = Map.merge(get_in(servers, [name, :config]) || %{}, config)
                Map.put(servers, name, %{config: merged, kind: kind, path: path})

              _, servers ->
                servers
            end)

          %{acc | servers: servers}

        {:ok, _} ->
          acc

        {:error, reason} ->
          %{acc | errors: acc.errors ++ ["#{path}: #{reason}"]}
      end
    end)
  end

  # From the git root down to the repository; just the repository when no
  # git root is found above it.
  defp project_dirs(repository_path) do
    repository_path
    |> Path.expand()
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.reduce_while([], fn dir, acc ->
      acc = [dir | acc]

      cond do
        File.exists?(Path.join(dir, ".git")) -> {:halt, acc}
        Path.dirname(dir) == dir -> {:halt, [Path.expand(repository_path)]}
        true -> {:cont, acc}
      end
    end)
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} ->
        case text |> strip_jsonc() |> JSON.decode() do
          {:ok, value} -> {:ok, value}
          {:error, {:unexpected_end, _}} -> {:error, "invalid JSON: unexpected end of file"}
          {:error, _} -> {:error, "invalid JSON"}
        end

      {:error, reason} when reason in [:enoent, :enotdir] ->
        :missing

      {:error, reason} ->
        {:error, "could not read: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  JSONC to JSON: drops `//` and `/* */` comments and trailing commas before
  `}` or `]`, leaving strings alone.
  """
  def strip_jsonc(text) when is_binary(text) do
    text
    |> strip_comments([])
    |> IO.iodata_to_binary()
    |> strip_trailing_commas([])
    |> IO.iodata_to_binary()
  end

  defp strip_comments(<<>>, acc), do: Enum.reverse(acc)

  defp strip_comments(<<"\"", rest::binary>>, acc) do
    {string, rest} = take_string(rest, ["\""])
    strip_comments(rest, [string | acc])
  end

  defp strip_comments(<<"//", rest::binary>>, acc) do
    case :binary.split(rest, "\n") do
      [_comment, rest] -> strip_comments(rest, ["\n" | acc])
      [_comment] -> Enum.reverse(acc)
    end
  end

  defp strip_comments(<<"/*", rest::binary>>, acc) do
    case :binary.split(rest, "*/") do
      [_comment, rest] -> strip_comments(rest, [" " | acc])
      [_comment] -> Enum.reverse(acc)
    end
  end

  defp strip_comments(<<c::utf8, rest::binary>>, acc),
    do: strip_comments(rest, [<<c::utf8>> | acc])

  defp strip_comments(<<c, rest::binary>>, acc), do: strip_comments(rest, [<<c>> | acc])

  defp strip_trailing_commas(<<>>, acc), do: Enum.reverse(acc)

  defp strip_trailing_commas(<<"\"", rest::binary>>, acc) do
    {string, rest} = take_string(rest, ["\""])
    strip_trailing_commas(rest, [string | acc])
  end

  defp strip_trailing_commas(<<",", rest::binary>>, acc) do
    case String.trim_leading(rest) do
      <<close, _::binary>> when close in [?}, ?]] -> strip_trailing_commas(rest, acc)
      _ -> strip_trailing_commas(rest, ["," | acc])
    end
  end

  defp strip_trailing_commas(<<c::utf8, rest::binary>>, acc),
    do: strip_trailing_commas(rest, [<<c::utf8>> | acc])

  defp strip_trailing_commas(<<c, rest::binary>>, acc),
    do: strip_trailing_commas(rest, [<<c>> | acc])

  # The rest of a JSON string after its opening quote: {iodata, rest}.
  defp take_string(<<"\\", c, rest::binary>>, acc), do: take_string(rest, [<<"\\", c>> | acc])
  defp take_string(<<"\"", rest::binary>>, acc), do: {Enum.reverse(["\"" | acc]), rest}
  defp take_string(<<c, rest::binary>>, acc), do: take_string(rest, [<<c>> | acc])
  defp take_string(<<>>, acc), do: {Enum.reverse(acc), <<>>}
end
