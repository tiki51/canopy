defmodule Canopy.MCP.Redact do
  @moduledoc """
  The one place MCP configuration values are masked before anything shows
  them: header and environment values, URL credentials and query values,
  secret-looking command arguments, error strings that echo URLs, and
  Canopy's own token (a fingerprint of its last 4 characters).

  A value that is only a reference to a secret kept elsewhere (`{env:API_KEY}`,
  `${GITHUB_TOKEN}`, `{file:~/.secret}`) is shown as is: it says where the
  secret comes from without revealing it.
  """

  @mask "••••"

  # flag names and KEY=value keys whose value is a secret
  @secret_name ~r/(token|key|secret|password|passwd|auth|credential)/i
  @reference ~r/^(\{env:[^}]+\}|\{file:[^}]+\}|\$\{[^}]+\}|\$[A-Za-z_][A-Za-z0-9_]*)$/
  @scheme ~r/^(Bearer|Basic|Token|Bot)\s+(.+)$/i
  @url_in_text ~r{[a-zA-Z][a-zA-Z0-9+.-]*://[^\s"'<>]+}
  @scheme_in_text ~r/\b(Bearer|Basic)\s+[^\s"',;)\]]+/i
  @opaque_arg ~r/^[A-Za-z0-9+\/_=.-]{32,}$/

  @doc "The mask that replaces a secret."
  def mask, do: @mask

  @doc """
  Canopy's token as a fingerprint: the mask and its last 4 characters. Used
  wherever the settings token is shown masked.
  """
  def token(token) when is_binary(token) and byte_size(token) > 4,
    do: @mask <> String.slice(token, -4, 4)

  def token(token) when is_binary(token), do: @mask
  def token(_), do: nil

  @doc """
  A header or environment value: a reference is kept, a scheme word is kept
  (`Bearer ••••`), anything else is masked.
  """
  def value(value) when is_binary(value) do
    cond do
      reference?(value) ->
        value

      match = Regex.run(@scheme, value) ->
        [_, scheme, rest] = match
        if reference?(String.trim(rest)), do: value, else: scheme <> " " <> @mask

      true ->
        @mask
    end
  end

  def value(_), do: @mask

  @doc """
  A map of headers or environment variables: `{masked_map, sorted_keys}`, the
  keys being the names of the values that were redacted.
  """
  def map(map) when is_map(map) do
    masked = Map.new(map, fn {k, v} -> {to_string(k), value(v)} end)
    {masked, masked |> Map.keys() |> Enum.sort()}
  end

  def map(_), do: {%{}, []}

  @doc """
  A URL without its userinfo and with every query value masked
  (`https://host/mcp?api_key=••••`). Text that is not a URL goes through `text/1`.
  """
  def url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when is_binary(scheme) and is_binary(host) and host != "" ->
        %{uri | userinfo: nil, query: query(uri.query), fragment: nil}
        |> URI.to_string()

      _ ->
        text(url)
    end
  end

  def url(_), do: nil

  defp query(nil), do: nil

  defp query(query) do
    query
    |> String.split("&")
    |> Enum.map_join("&", fn pair ->
      case String.split(pair, "=", parts: 2) do
        [key, ""] -> key <> "="
        [key, value] -> key <> "=" <> if(reference?(URI.decode(value)), do: value, else: @mask)
        [key] -> key
      end
    end)
  end

  @doc """
  A command line, as one string: the value after a secret-looking flag
  (`--token x`, `--api-key=x`), `KEY=value` pairs with a secret-looking key,
  and long opaque arguments (32+ characters of base64 or hex) are masked;
  URLs go through `url/1`.
  """
  def command(args) when is_list(args) do
    args
    |> Enum.map(&to_string/1)
    |> Enum.map_reduce(false, fn
      arg, true -> {mask_unless_reference(arg), false}
      arg, false -> argument(arg)
    end)
    |> elem(0)
    |> Enum.join(" ")
  end

  def command(arg) when is_binary(arg), do: command([arg])
  def command(_), do: ""

  # {redacted, mask_next?}
  defp argument("-" <> _ = arg) do
    case String.split(arg, "=", parts: 2) do
      [flag, value] ->
        if secret_flag?(flag),
          do: {flag <> "=" <> mask_unless_reference(value), false},
          else: {arg, false}

      [flag] ->
        {flag, secret_flag?(flag)}
    end
  end

  defp argument(arg) do
    cond do
      String.contains?(arg, "://") ->
        {url(arg), false}

      Regex.match?(@scheme_in_text, arg) ->
        {text(arg), false}

      match = Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s, arg) ->
        [_, key, value] = match

        if Regex.match?(@secret_name, key),
          do: {key <> "=" <> mask_unless_reference(value), false},
          else: {arg, false}

      opaque?(arg) ->
        {@mask, false}

      true ->
        {arg, false}
    end
  end

  defp secret_flag?(flag),
    do: Regex.match?(~r/^--?[A-Za-z0-9_-]+$/, flag) and Regex.match?(@secret_name, flag)

  defp mask_unless_reference(value), do: if(reference?(value), do: value, else: @mask)

  # Paths are long too, but are not secrets.
  defp opaque?(arg) do
    Regex.match?(@opaque_arg, arg) and not String.starts_with?(arg, ["/", ".", "~"]) and
      Regex.match?(~r/[0-9]/, arg) and Regex.match?(~r/[A-Za-z]/, arg)
  end

  @doc """
  Free text, such as an error from OpenCode: every URL in it goes through
  `url/1` and `Bearer`/`Basic` credentials are masked.
  """
  def text(text) when is_binary(text) do
    text
    |> then(&Regex.replace(@url_in_text, &1, fn url -> url_only(url) end))
    |> then(&Regex.replace(@scheme_in_text, &1, fn _, scheme -> scheme <> " " <> @mask end))
  end

  def text(nil), do: nil
  def text(other), do: text(inspect(other))

  # A URL found inside text; never recurse into text/1.
  defp url_only(url) do
    case URI.parse(url) do
      %URI{host: host} = uri when is_binary(host) ->
        URI.to_string(%{uri | userinfo: nil, query: query(uri.query), fragment: nil})

      _ ->
        @mask
    end
  end

  defp reference?(value) when is_binary(value), do: Regex.match?(@reference, value)
end
