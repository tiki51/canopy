defmodule Canopy.Codex.Models do
  @moduledoc """
  The models Codex offers (`model/list`), with the reasoning efforts each
  supports, for the agent form, Settings and the turn's effort check.

  Each call that misses the cache starts an app-server (`Canopy.Codex.Client`),
  so the list is cached per binary and config dir for ten minutes
  (`config :canopy, :codex, models_cache_ms:`; tests set 0). `refresh: true`
  bypasses the cache, and `cached/1` reads it without ever fetching (the turn
  uses it to drop an effort the model doesn't offer).
  """

  alias Canopy.Codex.{Client, Supervisor}
  alias Canopy.Engine.Codex, as: Engine

  @default_ttl_ms :timer.minutes(10)

  @type model :: %{
          id: String.t(),
          label: String.t(),
          efforts: [String.t()],
          default_effort: String.t() | nil,
          default?: boolean()
        }

  @doc """
  `{:ok, [model]}` or `{:error, reason}`. Options: `:binary`, `:config_dir`
  (default: Settings), `refresh: true`.
  """
  def list(opts \\ []) do
    with {:ok, binary, config_dir} <- target(opts) do
      key = {binary, config_dir}

      case not Keyword.get(opts, :refresh, false) && lookup(key) do
        {:ok, models} -> {:ok, models}
        _ -> fetch(binary, config_dir)
      end
    end
  end

  @doc "The cached list, never fetched: `{:ok, models}` or `:miss`."
  def cached(opts \\ []) do
    case target(opts) do
      {:ok, binary, config_dir} -> lookup({binary, config_dir}) || :miss
      _ -> :miss
    end
  end

  @doc """
  Fetches the list through a call function from an open `Client` server, and
  caches it (the readiness check warms the cache on the same server).
  """
  def fetch_with(call, binary, config_dir) do
    case page(call, nil, []) do
      {:ok, models} ->
        store({binary, config_dir}, models)
        {:ok, models}

      error ->
        error
    end
  end

  @doc "Forgets every cached list."
  def clear_cache do
    :ets.match_delete(Supervisor.cache(), {{:models, :_}, :_, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Adds an error when the model isn't in the list, or when the model (or, for
  no model, `opts[:default_model]`, else Codex's own default) doesn't offer
  the effort. Passes when the list is empty (unknown).
  """
  def validate(changeset, models, fields, opts \\ [])

  def validate(changeset, [], _fields, _opts), do: changeset

  def validate(changeset, models, {model_field, effort_field}, opts) do
    model = Ecto.Changeset.get_field(changeset, model_field)
    effort = Ecto.Changeset.get_field(changeset, effort_field)

    cond do
      is_binary(model) and model != "" and find(models, model) == nil ->
        Ecto.Changeset.add_error(changeset, model_field, "is not offered by Codex")

      is_binary(effort) and effort != "" ->
        target = present(model) || opts[:default_model]

        case find(models, target) || (target == nil && Enum.find(models, & &1.default?)) do
          %{efforts: efforts, id: id} when efforts != [] ->
            if effort in efforts,
              do: changeset,
              else:
                Ecto.Changeset.add_error(changeset, effort_field, "#{id} doesn't offer #{effort}")

          _ ->
            changeset
        end

      true ->
        changeset
    end
  end

  @doc "The efforts a model offers (Codex's default model for nil); [] when unknown."
  def efforts_for(models, model_id) do
    case find(models, model_id) || (model_id in [nil, ""] && Enum.find(models, & &1.default?)) do
      %{efforts: efforts} -> efforts
      _ -> []
    end
  end

  @doc "The model with that id, or nil."
  def find(_models, nil), do: nil
  def find(models, id), do: Enum.find(models, &(&1.id == id))

  @doc "A `model/list` entry as a model map."
  def parse(%{} = m) do
    id = m["model"] || m["id"]

    %{
      id: id,
      label: present(m["displayName"]) || id,
      efforts:
        for(
          %{"reasoningEffort" => e} <- List.wrap(m["supportedReasoningEfforts"]),
          is_binary(e),
          do: e
        ),
      default_effort: m["defaultReasoningEffort"],
      default?: m["isDefault"] == true
    }
  end

  # -- Fetching -------------------------------------------------------------------------

  defp fetch(binary, config_dir) do
    Client.with_server([binary: binary, config_dir: config_dir], fn call ->
      fetch_with(call, binary, config_dir)
    end)
  end

  defp page(call, cursor, acc) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}

    case call.("model/list", params) do
      {:ok, %{"data" => data} = result} ->
        models =
          for m <- List.wrap(data),
              is_map(m),
              m["hidden"] != true,
              (m["model"] || m["id"]) != nil,
              do: parse(m)

        case result["nextCursor"] do
          next when is_binary(next) and next != "" and next != cursor ->
            page(call, next, acc ++ models)

          _ ->
            {:ok, acc ++ models}
        end

      {:ok, _other} ->
        {:ok, acc}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp target(opts) do
    binary = Keyword.get_lazy(opts, :binary, &Engine.binary_name/0)
    config_dir = Keyword.get_lazy(opts, :config_dir, &Engine.configured_config_dir/0)

    case System.find_executable(binary) do
      nil -> {:error, "#{binary} not found on PATH"}
      path -> {:ok, path, config_dir}
    end
  end

  # -- Cache ----------------------------------------------------------------------------

  defp ttl_ms,
    do: Keyword.get(Application.get_env(:canopy, :codex, []), :models_cache_ms, @default_ttl_ms)

  defp lookup(key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(Supervisor.cache(), {:models, key}) do
      [{_, models, at}] -> if now - at < ttl_ms(), do: {:ok, models}
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp store(key, models) do
    if ttl_ms() > 0,
      do:
        :ets.insert(
          Supervisor.cache(),
          {{:models, key}, models, System.monotonic_time(:millisecond)}
        )

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil
end
