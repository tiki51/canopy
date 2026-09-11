defmodule Canopy.OpenCode.Client do
  @moduledoc """
  Thin HTTP client for the OpenCode server (verified against 1.18.11).

  Returns `{:ok, decoded_body}` for 2xx responses, `{:error, {:http, status, body}}`
  for other statuses, and `{:error, {:transport, reason}}` when the request fails.

  The base URL comes from `config :canopy, :opencode, base_url:` unless overridden
  per call with `base_url: "..."`. The runtime passes the URL stored in Settings.
  """

  @behaviour Canopy.OpenCode.ClientBehaviour

  @doc "Returns the configured module implementing `Canopy.OpenCode.ClientBehaviour`."
  def impl, do: Keyword.get(config(), :client, __MODULE__)

  @doc "Base URL from config, overridable per call."
  def base_url(opts \\ []),
    do: Keyword.get(opts, :base_url) || Keyword.fetch!(config(), :base_url)

  defp config, do: Application.get_env(:canopy, :opencode, [])

  @impl true
  def health(opts \\ []), do: request(:get, "/global/health", opts)

  @impl true
  def agents(directory, opts \\ []), do: request(:get, "/agent", dir(directory, opts))

  @doc "Configured providers and their models: `%{\"providers\" => [%{\"id\", \"name\", \"models\" => %{id => ...}}], \"default\" => %{provider => model}}`."
  @impl true
  def providers(opts \\ []), do: request(:get, "/config/providers", opts)

  @impl true
  def create_session(directory, body, opts \\ []) when is_map(body),
    do: request(:post, "/session", dir(directory, opts) |> Keyword.put(:json, body))

  @impl true
  def get_session(directory, session_id, opts \\ []),
    do: request(:get, "/session/#{session_id}", dir(directory, opts))

  @impl true
  def delete_session(directory, session_id, opts \\ []),
    do: request(:delete, "/session/#{session_id}", dir(directory, opts))

  @impl true
  def children(directory, session_id, opts \\ []),
    do: request(:get, "/session/#{session_id}/children", dir(directory, opts))

  @impl true
  def session_status(directory, opts \\ []),
    do: request(:get, "/session/status", dir(directory, opts))

  @impl true
  def messages(directory, session_id, query \\ [], opts \\ []) do
    params = Keyword.take(query, [:limit, :before])
    request(:get, "/session/#{session_id}/message", dir(directory, opts, params))
  end

  @doc "Compacts a session: OpenCode replaces its history with a summary made by the given model."
  @impl true
  def summarize(directory, session_id, body, opts \\ []) when is_map(body),
    do: request(:post, "/session/#{session_id}/summarize", [json: body] ++ dir(directory, opts))

  @impl true
  def prompt_async(directory, session_id, body, opts \\ []) when is_map(body),
    do:
      request(
        :post,
        "/session/#{session_id}/prompt_async",
        dir(directory, opts) |> Keyword.put(:json, body)
      )

  @impl true
  def abort(directory, session_id, opts \\ []),
    do: request(:post, "/session/#{session_id}/abort", dir(directory, opts))

  @impl true
  def session_diff(directory, session_id, opts \\ []),
    do: request(:get, "/session/#{session_id}/diff", dir(directory, opts))

  @impl true
  def vcs_status(directory, opts \\ []), do: request(:get, "/vcs/status", dir(directory, opts))

  @impl true
  def vcs_diff(directory, mode, opts \\ []) when is_binary(mode),
    do: request(:get, "/vcs/diff", dir(directory, opts, mode: mode))

  @impl true
  def pending_permissions(directory, opts \\ []),
    do: request(:get, "/permission", dir(directory, opts))

  @impl true
  def reply_permission(directory, permission_id, reply, opts \\ [])
      when reply in [:once, :always, :reject] do
    request(
      :post,
      "/permission/#{permission_id}/reply",
      dir(directory, opts) |> Keyword.put(:json, %{reply: Atom.to_string(reply)})
    )
  end

  @impl true
  def add_mcp(directory, name, config, opts \\ []) when is_binary(name) and is_map(config),
    do:
      request(
        :post,
        "/mcp",
        dir(directory, opts) |> Keyword.put(:json, %{name: name, config: config})
      )

  @impl true
  def mcp_status(directory, opts \\ []), do: request(:get, "/mcp", dir(directory, opts))

  @doc "Disposes OpenCode's instance for a directory; the next request recreates it (and reloads plugins)."
  @impl true
  def dispose_instance(directory, opts \\ []),
    do: request(:post, "/instance/dispose", dir(directory, opts))

  @doc """
  Builds the `%Req.Request{}` used for one call. Exposed so `EventStream` can open the
  SSE connection with the same base URL and test plug.
  """
  def new(opts \\ []) do
    base =
      Req.new(
        base_url: base_url(opts),
        retry: false,
        receive_timeout: Keyword.get(opts, :receive_timeout, 30_000),
        headers: [{"accept", "application/json"}]
      )

    Req.merge(base, Keyword.get(config(), :req_options, []))
  end

  defp dir(directory, opts, extra_params \\ []) when is_binary(directory) do
    params = Keyword.merge([directory: directory], extra_params)
    Keyword.put(opts, :params, params)
  end

  defp request(method, path, opts) do
    {req_opts, call_opts} = Keyword.split(opts, [:params, :json])
    req = new(call_opts)

    case Req.request(req, [method: method, url: path] ++ req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end
end
