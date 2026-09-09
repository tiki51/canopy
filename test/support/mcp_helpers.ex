defmodule Canopy.MCPHelpers do
  @moduledoc """
  Test helpers for the Canopy MCP server.

  `call/3` runs a tool the way Anubis does: string-keyed arguments are
  validated through the tool's schema, the plugin stamp is added from the
  session, and the tool result is reduced to `{:ok, text}` or `{:error, text}`.
  """

  alias Anubis.Server.{Frame, Response}

  @doc """
  Calls `tool` as the agent behind `session` (an `%AgentSession{}` or a
  scenario map with a `:session`). `params` may use atom or string keys.
  """
  def call(tool, params, %{session: session}), do: call(tool, params, session)

  def call(tool, params, %Canopy.AgentSessions.AgentSession{opencode_session_id: id}) do
    params
    |> stringify()
    |> Map.put("canopy_session_id", id)
    |> then(&execute(tool, &1))
  end

  @doc "Calls `tool` with raw string-keyed arguments (no identity stamp added)."
  def execute(tool, params) do
    case tool.mcp_schema(stringify(params)) do
      {:ok, validated} ->
        {:reply, %Response{} = response, %Frame{}} = tool.execute(validated, Frame.new())
        text = Enum.map_join(response.content, "\n", & &1["text"])
        if response.isError, do: {:error, text}, else: {:ok, text}

      {:error, errors} ->
        {:invalid, errors}
    end
  end

  @doc "Builds a JSON-RPC request map."
  def rpc(id, method, params \\ %{}) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  @doc "Builds a JSON-RPC notification map."
  def notification(method, params \\ %{}) do
    %{"jsonrpc" => "2.0", "method" => method, "params" => params}
  end

  @doc "Decodes a Streamable HTTP response body, whether plain JSON or SSE-framed."
  def decode_body(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} ->
        decoded

      {:error, _} ->
        body
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data:"))
        |> Enum.map_join("", &String.trim(String.replace_prefix(&1, "data:", "")))
        |> JSON.decode!()
    end
  end

  defp stringify(params) when is_map(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end
end
