defmodule Canopy.Templates.Import.Plan do
  @moduledoc """
  An import preview (`Canopy.Templates.Import.plan/2`): the items it would
  write, the bundle's manifest when there is one, notices about the source
  as a whole (ignored files), and `errors` when the source can't be read at
  all. `sources` and `machine` are kept so the preview can be worked out
  again, as it is when anything changed before the import was applied.
  """

  defstruct items: [], manifest: nil, notices: [], errors: [], sources: [], machine: nil

  @type t :: %__MODULE__{}

  alias Canopy.Templates.Import.Item

  @doc "Items the import would write."
  def writing(%__MODULE__{items: items}), do: Enum.filter(items, &Item.writes?/1)

  @doc """
  Whether the import can run: something to write, and no written item with
  errors (an invalid item must be skipped).
  """
  def ready?(%__MODULE__{errors: []} = plan) do
    case writing(plan) do
      [] -> false
      items -> Enum.all?(items, &(&1.errors == []))
    end
  end

  def ready?(_plan), do: false
end
