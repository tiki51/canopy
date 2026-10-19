defmodule Canopy.Codex.RPC do
  @moduledoc """
  The JSON-RPC line codec `codex app-server` speaks on stdio: one JSON object
  per line. Canopy's requests carry `"jsonrpc": "2.0"`; Codex's own messages
  omit it, so decoding never requires it. Pure.
  """

  @doc "A request line (with its newline)."
  def request(id, method, params \\ nil),
    do: line(put_params(%{"jsonrpc" => "2.0", "id" => id, "method" => method}, params))

  @doc "A notification line (no id)."
  def notification(method, params \\ nil),
    do: line(put_params(%{"jsonrpc" => "2.0", "method" => method}, params))

  @doc "A response to one of Codex's server requests."
  def response(id, result), do: line(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

  @doc "An error response to one of Codex's server requests."
  def error(id, code, message),
    do:
      line(%{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}})

  @doc """
  Classifies one line from Codex:

    * `{:response, id, result}`
    * `{:error, id, %{"code" => c, "message" => m}}`
    * `{:request, id, method, params}` (a server request: Codex waits for an answer)
    * `{:notification, method, params}`
    * `:invalid` (not JSON, or no shape we know)
  """
  def decode(line) when is_binary(line) do
    case JSON.decode(line) do
      {:ok, %{} = msg} -> classify(msg)
      _ -> :invalid
    end
  end

  defp classify(%{"method" => method, "id" => id} = msg) when is_binary(method),
    do: {:request, id, method, params(msg)}

  defp classify(%{"method" => method} = msg) when is_binary(method),
    do: {:notification, method, params(msg)}

  defp classify(%{"id" => id, "error" => error}) when is_map(error), do: {:error, id, error}
  defp classify(%{"id" => id, "result" => result}), do: {:response, id, result}
  defp classify(_msg), do: :invalid

  defp params(%{"params" => params}) when is_map(params), do: params
  defp params(_msg), do: %{}

  defp put_params(map, nil), do: map
  defp put_params(map, params), do: Map.put(map, "params", params)

  defp line(map), do: JSON.encode!(map) <> "\n"
end
