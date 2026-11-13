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

  def call(tool, params, %Canopy.AgentSessions.AgentSession{engine_session_id: id}) do
    result =
      params
      |> stringify()
      |> Map.put("canopy_session_id", id)
      |> then(&execute(tool, &1))

    # a posting tool starts the channel's server, which wakes whoever the
    # post is for: let it, while the test's stubs are still in place
    Canopy.RuntimeHelpers.settle()
    stop_channels_on_exit()
    result
  end

  @doc """
  Calls `tool` as a session-authenticated connection would (a Claude Code
  process): the identity rides in the frame assigns, no stamp in the params.
  """
  def call_as_session(tool, params, %Canopy.AgentSessions.AgentSession{} = session) do
    execute(tool, params, %{
      canopy_session: %{engine: session.engine, engine_session_id: session.engine_session_id}
    })
  end

  # Posting tools start channel servers. Registered from the test (or a setup
  # step), so it runs before the setup's own on_exit callbacks: the servers
  # stop before a repository fixture removes their directory. Once per test.
  # Not from call_as_session/3, which tests also run from other processes.
  defp stop_channels_on_exit do
    ExUnit.Callbacks.on_exit(
      {__MODULE__, :stop_channels},
      &Canopy.PlaybookHelpers.stop_channels/0
    )
  end

  @doc "Calls `tool` with raw string-keyed arguments (no identity stamp added) and optional frame assigns."
  def execute(tool, params, assigns \\ %{}) do
    case tool.mcp_schema(stringify(params)) do
      {:ok, validated} ->
        {:reply, %Response{} = response, %Frame{}} = tool.execute(validated, Frame.new(assigns))
        text = Enum.map_join(response.content, "\n", & &1["text"])
        if response.isError, do: {:error, text}, else: {:ok, text}

      {:error, errors} ->
        {:invalid, errors}
    end
  end

  @doc """
  A setup step stubbing the OpenCode client for the channel servers that
  posting tools start: sessions are created and prompts accepted, and
  nothing is sent anywhere. Use it after `:set_mox_global`; stubs set later
  in the test win.
  """
  def stub_runtime(_ctx) do
    oc = Canopy.OpenCode.ClientMock

    Mox.stub(oc, :mcp_status, fn _dir, _opts ->
      {:ok, %{"canopy" => %{"status" => "connected"}}}
    end)

    Mox.stub(oc, :add_mcp, fn _dir, _name, _config, _opts -> {:ok, %{}} end)
    Mox.stub(oc, :dispose_instance, fn _dir, _opts -> {:ok, true} end)

    Mox.stub(oc, :create_session, fn _dir, _body, _opts ->
      {:ok, %{"id" => "ses_" <> Canopy.Fixtures.unique_suffix()}}
    end)

    Mox.stub(oc, :prompt_async, fn _dir, _sid, _body, _opts -> {:ok, ""} end)
    :ok
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
