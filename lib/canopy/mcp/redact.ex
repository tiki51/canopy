defmodule Canopy.MCP.Redact do
  @moduledoc """
  The one place MCP configuration values are masked before anything shows
  them: header and environment values, URL credentials and query values,
  secret-looking command arguments, error strings that echo URLs, and
  Canopy's own token (a fingerprint of its last 4 characters). Engine
  transcripts go through `secrets/2`, which looks for credentials anywhere
  in free text.

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

  # -- Free text from an engine ---------------------------------------------------

  @known_label "[canopy session token]"

  # Credentials that look like one wherever they appear: a PEM private key
  # (to its end, or the end of the text when cut off), scheme credentials of
  # 16+ characters, the common provider key shapes, and SECRET_KEY_BASE.
  @secret_shapes [
    {~r/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)/s,
     "-----BEGIN PRIVATE KEY----- " <> @mask <> " -----END PRIVATE KEY-----"},
    {~r/\b(Bearer|Basic)\s+[A-Za-z0-9._~+\/=-]{16,}/, "\\1 " <> @mask},
    {~r/\bsk-ant-[A-Za-z0-9_-]{8,}/, @mask},
    {~r/\bsk-[A-Za-z0-9_-]{20,}/, @mask},
    {~r/\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})/, @mask},
    {~r/\bAKIA[0-9A-Z]{16}\b/, @mask},
    {~r/\bxox[abprs]-[A-Za-z0-9-]{10,}/, @mask},
    {~r/\bSECRET_KEY_BASE\s*=\s*\S+/, "SECRET_KEY_BASE=" <> @mask},
    # a password in a URL's userinfo
    {~r{\b([a-zA-Z][a-zA-Z0-9+.-]*://)[^\s/@:"']+:[^\s/@"']+@}, "\\1" <> @mask <> "@"},
    # image and file bytes inlined as a data URL
    {~r|data:[\w.+/-]+;base64,[A-Za-z0-9+/=]{64,}|, "[data URL]"}
  ]

  # `api_key: value`, `"password": "value"`, `GITHUB_TOKEN=value`
  @secret_pair ~r/\b([A-Za-z0-9_.-]*(?:api[_-]?key|secret|password|passwd|token)[A-Za-z0-9_.-]*)(["']?\s*[:=]\s*["']?)([^\s"',;(){}\[\]]{8,})/i

  @doc """
  Free text that may carry secrets anywhere, such as an engine transcript (a
  tool's output, a prompt, the system text). Each of `known` (Canopy's own
  tokens: the sessions' MCP tokens and the settings token) becomes
  `[canopy session token]`; credentials that look like one are masked
  (scheme credentials, provider key shapes, PEM private keys, URL passwords,
  `secret: value` pairs whose value has letters and digits or is long), and
  data URLs become `[data URL]`. Returns `{text, redacted?}`.
  """
  def secrets(text, known \\ [])

  def secrets(text, known) when is_binary(text) do
    redacted =
      known
      |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= 8))
      |> Enum.reduce(text, &String.replace(&2, &1, @known_label))
      |> then(fn text ->
        Enum.reduce(@secret_shapes, text, fn {regex, replacement}, acc ->
          Regex.replace(regex, acc, replacement)
        end)
      end)
      |> then(fn text -> Regex.replace(@secret_pair, text, &secret_pair/4) end)

    {redacted, redacted != text}
  end

  def secrets(nil, _known), do: {nil, false}

  defp secret_pair(whole, key, separator, value) do
    if secret_value?(value), do: key <> separator <> @mask, else: whole
  end

  # Code reads secrets from somewhere (`System.get_env`, `os.environ[`); a
  # real value has letters and digits, or is long and has no punctuation.
  defp secret_value?(value) do
    cond do
      reference?(value) or String.contains?(value, @mask) -> false
      Regex.match?(~r/^\d+$/, value) -> false
      Regex.match?(~r/\d/, value) and Regex.match?(~r/[A-Za-z]/, value) -> true
      true -> byte_size(value) >= 20 and not Regex.match?(~r/[.\/]/, value)
    end
  end

  defp reference?(value) when is_binary(value), do: Regex.match?(@reference, value)
end
