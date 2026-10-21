defmodule Canopy.Fallback do
  @moduledoc """
  An agent's fallback model: where its turns go while its engine is paused
  at a usage or billing limit (`Canopy.EnginePauses`).

  A fallback is one encoded string, so a plain select can carry it:
  `"claude_code:sonnet"`, `"codex:gpt-5-codex"`, or for OpenCode
  `"opencode:<provider>/<model>"`. Split on the first `:`, then (OpenCode)
  on the first `/`; the model id may hold more of either.

  Settings keeps one default per engine (`claude_fallback`, `codex_fallback`,
  `opencode_fallback`; nil is no fallback). An agent's own `fallback` is nil
  (follow Settings), `"none"` (wait for the reset) or an encoded value.
  """

  alias Canopy.{Agents, Engine, EnginePauses, Settings}

  @type target :: %{engine: String.t(), provider: String.t() | nil, model: String.t()}

  @settings_fields %{
    "claude_code" => :claude_fallback,
    "codex" => :codex_fallback,
    "opencode" => :opencode_fallback
  }

  @doc "The Settings field holding `engine`'s default fallback, or nil."
  def settings_field(engine), do: Map.get(@settings_fields, engine)

  @doc """
  Decodes a fallback value: a target, `:none` for `"none"`, or nil for
  nil, blank or anything malformed.
  """
  @spec parse(term()) :: target | :none | nil
  def parse("none"), do: :none

  def parse(value) when is_binary(value) do
    with [engine, rest] <- String.split(String.trim(value), ":", parts: 2),
         true <- engine != "" and rest != "" do
      parse_model(engine, rest)
    else
      _ -> nil
    end
  end

  def parse(_), do: nil

  defp parse_model("opencode", rest) do
    case String.split(rest, "/", parts: 2) do
      [provider, model] when provider != "" and model != "" ->
        %{engine: "opencode", provider: provider, model: model}

      _ ->
        nil
    end
  end

  defp parse_model(engine, model), do: %{engine: engine, provider: nil, model: model}

  @doc "Encodes a target back to its string."
  def encode(%{engine: "opencode", provider: provider, model: model}),
    do: "opencode:#{provider}/#{model}"

  def encode(%{engine: engine, model: model}), do: "#{engine}:#{model}"

  @doc """
  Why a fallback value can't be saved, or nil: the format, an engine
  Canopy doesn't run, or an OpenCode value with no provider. `"none"` is
  valid only where `allow_none` is true (an agent's own value).
  """
  def error(value, allow_none \\ false)
  def error(nil, _), do: nil
  def error("none", true), do: nil

  def error(value, _allow_none) when is_binary(value) do
    case parse(value) do
      %{engine: engine} ->
        if engine in Engine.names(), do: nil, else: "names an engine Canopy doesn't run"

      _ ->
        if String.starts_with?(value, "opencode:"),
          do: "must name an OpenCode provider and model (opencode:provider/model)",
          else: "must be an engine and a model (engine:model)"
    end
  end

  def error(_, _), do: "is invalid"

  @doc "The Settings default fallback for `engine`, or nil."
  @spec default_for(String.t(), map() | nil) :: target | nil
  def default_for(engine, setting \\ nil) do
    case settings_field(engine) do
      nil ->
        nil

      field ->
        case parse(Map.get(setting || Settings.get(), field)) do
          %{} = target -> target
          _ -> nil
        end
    end
  end

  @doc """
  The agent's fallback: its own value, else its effective engine's default
  from Settings. `"none"` is nil (wait for the reset).
  """
  @spec resolve(map(), map() | nil) :: target | nil
  def resolve(agent, setting \\ nil) do
    setting = setting || Settings.get()

    case parse(Map.get(agent, :fallback)) do
      :none -> nil
      %{} = target -> target
      nil -> default_for(Agents.effective_engine(agent, setting), setting)
    end
  end

  @doc ~S|How people read a target: "Codex › gpt-5-codex", "OpenCode › anthropic/claude-sonnet-4".|
  def label(%{engine: "opencode", provider: provider, model: model}),
    do: "#{Engine.label("opencode")} › #{provider}/#{model}"

  def label(%{engine: engine, model: model}), do: "#{Engine.label(engine)} › #{model}"

  @doc """
  The target's model id as timeline payloads carry it: bare, or OpenCode's
  `provider/model`.
  """
  def model_ref(%{engine: "opencode", provider: provider, model: model}),
    do: "#{provider}/#{model}"

  def model_ref(%{model: model}), do: model

  @doc """
  The marker a message written on a fallback session carries
  (`messages.fallback`): `%{"engine", "model", "from_engine"}`, or nil for
  a primary session. The model is the agent's fallback as it resolves now,
  when it is still on the session's engine.
  """
  def marker(%{fallback_of: from} = session) when is_binary(from) do
    model =
      case session |> Map.get(:agent_id) |> agent() |> then(&(&1 && resolve(&1))) do
        %{engine: engine} = target when engine == session.engine -> model_ref(target)
        _ -> nil
      end

    %{"engine" => session.engine, "model" => model, "from_engine" => from}
  end

  def marker(_session), do: nil

  @doc "The marker for a turn on `target` standing in for `from_engine`."
  def marker_for(%{engine: engine} = target, from_engine),
    do: %{"engine" => engine, "model" => model_ref(target), "from_engine" => from_engine}

  defp agent(id) when is_binary(id), do: Agents.get(id)
  defp agent(_id), do: nil

  @doc """
  Whether a target shares `engine`'s limit. A pause covers the whole engine,
  so such a target is never usable while that engine is paused.
  """
  def same_plan?(engine, %{engine: target_engine}), do: target_engine == engine
  def same_plan?(_engine, _target), do: false

  @doc """
  Where the agent's next turn goes:

    * `{:primary, engine}`: its engine isn't paused;
    * `{:fallback, target}`: it is, and the fallback's engine is neither
      paused nor missing (`Canopy.Engine.available?/1`);
    * `{:wait, pause}`: it is, and there's no usable fallback.
  """
  @spec route(map()) :: {:primary, String.t()} | {:fallback, target} | {:wait, map()}
  def route(agent) do
    setting = Settings.get()
    engine = Agents.effective_engine(agent, setting)

    case EnginePauses.get(engine) do
      nil ->
        {:primary, engine}

      pause ->
        case usable(engine, resolve(agent, setting)) do
          nil -> {:wait, pause}
          target -> {:fallback, target}
        end
    end
  end

  @doc """
  The agent's fallback when it is unusable right now, else nil: the label
  `engine_paused.fallback_unavailable` carries.
  """
  def unavailable_label(agent) do
    setting = Settings.get()
    engine = Agents.effective_engine(agent, setting)

    case resolve(agent, setting) do
      nil -> nil
      target -> if usable(engine, target), do: nil, else: label(target)
    end
  end

  defp usable(_engine, nil), do: nil

  defp usable(engine, target) do
    if not same_plan?(engine, target) and not EnginePauses.paused?(target.engine) and
         target.engine in Engine.names() and Engine.available?(target.engine),
       do: target,
       else: nil
  end
end
