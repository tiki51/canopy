defmodule Canopy.MCP.Inventory.Engine do
  @moduledoc """
  What one engine gives agents in a repository: the MCP servers it loads
  (`servers`), the ones configured somewhere it does not load (`ignored`, each
  with its reason in `note`), whether Canopy could ask the engine at all
  (`reachable?`, with the redacted `error`), and `notes` for the page.

  `canopy` carries engine facts about Canopy's own server: for OpenCode,
  `registered_this_boot?`, the repository's identity `plugin` file
  (`:current | :outdated | :missing`) and whether the `global_plugin?` copy
  exists. `in_use?` is filled in by `Canopy.MCP.Inventory`: some member of a
  channel in the repository runs on this engine.
  """

  alias Canopy.MCP.Inventory.Server

  @type t :: %__MODULE__{
          engine: String.t(),
          reachable?: boolean(),
          error: String.t() | nil,
          in_use?: boolean(),
          servers: [Server.t()],
          ignored: [Server.t()],
          notes: [String.t()],
          canopy: map()
        }

  defstruct [
    :engine,
    :error,
    reachable?: true,
    in_use?: false,
    servers: [],
    ignored: [],
    notes: [],
    canopy: %{}
  ]
end
