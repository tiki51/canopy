defmodule Canopy.MCP.Inventory do
  @moduledoc """
  Which MCP servers agents get in a repository, per engine, for the
  repository page.

  Each adapter that implements the optional `Canopy.Engine.mcp_inventory/2`
  answers for its own engine (config files, live status, Canopy's own
  registration) with a `Canopy.MCP.Inventory.Engine`; this module adds the
  engine-neutral facts: which engines the repository's agents use and
  Canopy's token fingerprint. Everything returned is already redacted
  (`Canopy.MCP.Redact`): it can go straight into an assign.

  Nothing is cached: every call re-reads the files and asks the engines.
  """

  import Ecto.Query, warn: false

  alias Canopy.Agents.Agent
  alias Canopy.Channels.{Channel, ChannelAgent}
  alias Canopy.MCP.{Inventory, Redact}
  alias Canopy.Repo
  alias Canopy.Repositories.Repository

  @type t :: %{token: String.t() | nil, engines: [Inventory.Engine.t()]}

  @doc """
  The inventory of a repository. `opts` go to every adapter, over
  `config :canopy, :mcp_inventory` (tests point both at fixture paths:
  `home:`, `config_dir:`, `config_home:`, …, so the real home is never read).
  """
  @spec for_repository(Repository.t(), keyword()) :: t()
  def for_repository(%Repository{} = repository, opts \\ []) do
    opts = Keyword.merge(Application.get_env(:canopy, :mcp_inventory, []), opts)
    used = engines_in_use(repository.id)

    engines =
      Canopy.Engine.engines()
      |> Enum.filter(fn {_name, mod} ->
        Code.ensure_loaded?(mod) and function_exported?(mod, :mcp_inventory, 2)
      end)
      |> Enum.map(fn {name, mod} ->
        %{engine_inventory(name, mod, repository, opts) | in_use?: name in used}
      end)
      |> Enum.sort_by(&{not &1.in_use?, &1.engine})

    %{token: Redact.token(Canopy.Settings.mcp_token()), engines: engines}
  end

  # An adapter that crashes reports its error, not a broken page.
  defp engine_inventory(name, mod, repository, opts) do
    case mod.mcp_inventory(repository, opts) do
      {:ok, %Inventory.Engine{} = engine} ->
        engine

      {:error, reason} ->
        %Inventory.Engine{engine: name, reachable?: false, error: Redact.text(reason)}
    end
  rescue
    e ->
      %Inventory.Engine{
        engine: name,
        reachable?: false,
        error: Redact.text(Exception.message(e))
      }
  end

  @doc "The engines the members of the repository's channels run on (their own, or the default)."
  def engines_in_use(repository_id) do
    default = Canopy.Settings.default_engine()

    Repo.all(
      from a in Agent,
        join: m in ChannelAgent,
        on: m.agent_id == a.id,
        join: c in Channel,
        on: c.id == m.channel_id,
        where: c.repository_id == ^repository_id,
        distinct: true,
        select: a.engine
    )
    |> Enum.map(&(&1 || default))
    |> Enum.uniq()
  end
end
