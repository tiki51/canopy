defmodule Canopy.Templates.Machine do
  @moduledoc """
  What this machine can run, as far as an import needs to know: whether the
  `claude` binary is on PATH (the same lookup a turn makes), OpenCode's model
  catalogue (or why it is unreachable), and the OpenCode agents it offers.
  An import checks a file against this and falls back, with a notice, where
  the file names something this machine doesn't have.

  `probe/0` asks once per import preview; tests build the struct directly.
  """

  alias Canopy.Engine.ClaudeCode
  alias Canopy.OpenCode.{Client, Providers}
  alias Canopy.Repositories

  # OpenCode's own primary agents, always available
  @builtin_opencode_agents ~w(build plan)

  defstruct claude_code: false, opencode: {:error, :unchecked}, opencode_agents: nil

  @type t :: %__MODULE__{
          claude_code: boolean(),
          opencode: {:ok, [map()]} | {:error, term()},
          opencode_agents: [String.t()] | nil
        }

  def builtin_opencode_agents, do: @builtin_opencode_agents

  @doc "Probes this machine. Only reads: nothing is started or changed."
  def probe do
    opencode = Task.async(fn -> Providers.list() end)
    agents = Task.async(&opencode_agents/0)

    %__MODULE__{
      claude_code: not is_nil(System.find_executable(ClaudeCode.binary_name())),
      opencode:
        case Task.await(opencode, :timer.seconds(15)) do
          {:ok, %{providers: providers}} -> {:ok, providers}
          {:error, reason} -> {:error, reason}
        end,
      opencode_agents: Task.await(agents, :timer.seconds(15))
    }
  end

  # Primary, visible agents of the first repository, plus the built-ins; nil
  # when OpenCode can't say (no repository, or it is away).
  defp opencode_agents do
    with [%{path: dir} | _] <- Repositories.list(),
         {:ok, list} when is_list(list) <- Client.impl().agents(dir, []) do
      list
      |> Enum.filter(fn
        %{"name" => name} = agent when is_binary(name) ->
          Map.get(agent, "mode", "primary") == "primary" and not Map.get(agent, "hidden", false)

        _ ->
          false
      end)
      |> Enum.map(& &1["name"])
      |> Enum.concat(@builtin_opencode_agents)
      |> Enum.uniq()
    else
      _ -> nil
    end
  end

  @doc "Whether OpenCode answered."
  def opencode_reachable?(%__MODULE__{opencode: {:ok, _}}), do: true
  def opencode_reachable?(_machine), do: false

  @doc """
  The engine a new agent gets when its file names none (or one this Canopy
  doesn't know): OpenCode, the schema default, unless OpenCode is away and
  Claude Code is installed.
  """
  def default_engine(%__MODULE__{} = machine) do
    if not opencode_reachable?(machine) and machine.claude_code and
         "claude_code" in Canopy.Engine.names(),
       do: "claude_code",
       else: "opencode"
  end

  @doc "Whether the engine can run here (installed, or reachable)."
  def engine_ready?(%__MODULE__{claude_code: ready}, "claude_code"), do: ready
  def engine_ready?(%__MODULE__{} = machine, "opencode"), do: opencode_reachable?(machine)
  def engine_ready?(_machine, _engine), do: false
end
