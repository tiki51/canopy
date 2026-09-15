defmodule Canopy.Engine.OpenCode do
  @moduledoc """
  `Canopy.Engine` adapter for an OpenCode server (`opencode serve`).

  One server multiplexes every repository through `?directory=`; sessions live
  on the server, so "resuming" one is just naming it. Events arrive through the
  per-repository SSE stream (`Canopy.OpenCode.EventStream`) and are normalized
  by `Canopy.OpenCode.Events`. The MCP registration and the identity plugin are
  re-checked before the first prompt after every (re)connect.

  Adapter state per channel: `client_opts` (the server URL from settings),
  `start_stream?`, and the `mcp_registered?` memo.
  """

  @behaviour Canopy.Engine

  alias Canopy.{Documents, Settings}
  alias Canopy.Engine.Event
  alias Canopy.OpenCode
  alias Canopy.OpenCode.Client

  @impl true
  def name, do: "opencode"

  @impl true
  def attach(ctx, opts) do
    state = %{
      client_opts: [base_url: Keyword.get(opts, :base_url) || Settings.get().opencode_url],
      start_stream?: Keyword.get(opts, :start_stream, stream_default()),
      mcp_registered?: false
    }

    if state.start_stream?, do: ensure_stream(ctx, state)
    state
  end

  # A reconnect usually means OpenCode restarted, and its MCP registrations are
  # process-local; a rotated token makes the registration it holds stale.
  @impl true
  def invalidate(state, _reason), do: %{state | mcp_registered?: false}

  @impl true
  def prepare(ctx, state), do: ensure_mcp(ctx, state)

  @impl true
  def create_session(ctx, state, agent, opts) do
    body = %{title: Keyword.get(opts, :title), agent: agent.opencode_agent || "build"}

    # A child of an OpenCode session is created under it; a parent on another
    # engine has no OpenCode id, so the child is a root session there and the
    # delegation link lives in Canopy alone.
    body =
      case Keyword.get(opts, :parent) do
        %{engine: "opencode", engine_session_id: parent_id} -> Map.put(body, :parentID, parent_id)
        _ -> body
      end

    case client().create_session(ctx.repository.path, body, state.client_opts) do
      {:ok, %{"id" => id}} -> {:ok, %{engine_session_id: id}}
      {:ok, other} -> {:error, {:unexpected, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def subscribe(session), do: Canopy.Engine.subscribe_session(session.engine_session_id)

  @impl true
  def send_prompt(ctx, state, session, agent, %{text: text, system: system} = prompt) do
    # Documents the plan marks as parts ride along; the rest were materialised
    # under the repository and the prompt names their paths.
    parts =
      Enum.flat_map(Map.get(prompt, :attachments, []), fn
        {document, :part} -> List.wrap(Documents.prompt_part(document))
        {_document, :path} -> []
      end)

    body = %{
      parts: [%{type: "text", text: text} | parts],
      agent: agent.opencode_agent || "build",
      system: system,
      tools: %{"canopy_*" => true}
    }

    body =
      case {agent.model_provider, agent.model_id} do
        {p, m} when is_binary(p) and is_binary(m) ->
          Map.put(body, :model, %{providerID: p, modelID: m})

        _ ->
          body
      end

    case client().prompt_async(
           ctx.repository.path,
           session.engine_session_id,
           body,
           state.client_opts
         ) do
      {:ok, _} -> {:ok, %{attachments: length(parts)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def abort(ctx, state, session),
    do: client().abort(ctx.repository.path, session.engine_session_id, state.client_opts)

  # OpenCode summarizes the session with a model: the agent's own, else the
  # server's default for the first provider.
  @impl true
  def compact(ctx, state, session, agent) do
    case compaction_model(agent) do
      {provider, model} ->
        case client().summarize(
               ctx.repository.path,
               session.engine_session_id,
               %{providerID: provider, modelID: model},
               state.client_opts
             ) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:error, :no_model}
    end
  end

  @impl true
  def reply_permission(ctx, state, request, reply) do
    case client().reply_permission(
           ctx.repository.path,
           request.opencode_permission_id,
           reply,
           state.client_opts
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def reply_question(ctx, state, request, outcome) do
    dir = ctx.repository.path

    result =
      case outcome do
        {:answered, answers} ->
          client().reply_question(dir, request.opencode_question_id, answers, state.client_opts)

        :rejected ->
          client().reject_question(dir, request.opencode_question_id, state.client_opts)
      end

    case result do
      {:ok, _} -> :ok
      # OpenCode no longer holds this question: it restarted, or the session
      # died still carrying it.
      {:error, {:http, status, _}} when status in [400, 404] -> {:error, :gone}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def reconcile(ctx, state) do
    dir = ctx.repository.path

    # The status map lists non-idle sessions only; a session whose model call
    # keeps failing shows as `retry` with the provider's message and the attempt.
    {busy, retrying} =
      case client().session_status(dir, state.client_opts) do
        {:ok, statuses} when is_map(statuses) ->
          active = Enum.reject(statuses, fn {_, st} -> st["type"] == "idle" end)

          retrying =
            for {sid, %{"type" => "retry"} = st} <- active,
                do: %{session_id: sid, message: st["message"], attempt: st["attempt"]}

          {Enum.map(active, &elem(&1, 0)), retrying}

        _ ->
          {:unknown, :unknown}
      end

    %{
      busy: busy,
      retrying: retrying,
      permissions:
        prompts(client().pending_permissions(dir, state.client_opts), :approval_required),
      questions: prompts(client().pending_questions(dir, state.client_opts), :question_required)
    }
  end

  # A 400/404 means this OpenCode build does not serve the endpoint, which is
  # the same as nothing pending. Any other failure leaves the answer unknown.
  defp prompts({:ok, requests}, type) when is_list(requests) do
    Enum.map(requests, fn req ->
      %Event{
        type: type,
        session_id: req["sessionID"],
        data: %{request: req},
        raw_type: "reconcile"
      }
    end)
  end

  defp prompts({:error, {:http, status, _}}, _type) when status in [400, 404], do: []
  defp prompts(_, _type), do: :unknown

  # "provider/model" as configured on the agent; OpenCode's default otherwise.
  @impl true
  def model_label(%{model_provider: p, model_id: m}) when is_binary(p) and is_binary(m),
    do: p <> "/" <> m

  def model_label(_agent), do: "opencode default"

  @impl true
  def context_cap, do: Canopy.Runtime.ChannelServer.context_cap()

  # -- Streams and MCP ----------------------------------------------------------

  defp ensure_stream(ctx, state) do
    OpenCode.Supervisor.start_stream(ctx.repository.id, ctx.repository.path,
      base_url: state.client_opts[:base_url]
    )
  end

  defp ensure_mcp(_ctx, %{mcp_registered?: true} = state), do: state

  # A registration OpenCode still reports as connected is reused only if this
  # Canopy process made it: an older one carries the tool list from before
  # Canopy last restarted. Otherwise it is (re)posted, which is idempotent.
  defp ensure_mcp(ctx, state) do
    dir = ctx.repository.path
    name = Canopy.MCP.registration_name()
    repository_id = ctx.repository.id

    # The identity plugin must be in this repository; a fresh install only
    # takes effect once OpenCode recreates its instance for the directory.
    case Canopy.MCP.ensure_project_plugin(dir) do
      {:ok, :installed} -> client().dispose_instance(dir, state.client_opts)
      _ -> :ok
    end

    connected? =
      match?(
        {:ok, %{^name => %{"status" => "connected"}}},
        client().mcp_status(dir, state.client_opts)
      )

    registered? =
      (connected? and Canopy.MCP.registered_this_boot?(repository_id)) or
        match?(
          {:ok, _},
          client().add_mcp(dir, name, Canopy.MCP.registration_config(:current), state.client_opts)
        )

    if registered?, do: Canopy.MCP.mark_registered(repository_id)
    %{state | mcp_registered?: registered?}
  end

  defp compaction_model(%{model_provider: p, model_id: m}) when is_binary(p) and is_binary(m),
    do: {p, m}

  defp compaction_model(_agent) do
    case client().providers([]) do
      {:ok, %{"default" => defaults}} when map_size(defaults) > 0 ->
        defaults |> Enum.min_by(fn {p, _} -> p end)

      _ ->
        nil
    end
  end

  defp client, do: Client.impl()

  defp stream_default,
    do: Keyword.get(Application.get_env(:canopy, :opencode, []), :start_streams, true)
end
