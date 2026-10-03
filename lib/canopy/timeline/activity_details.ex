defmodule Canopy.Timeline.ActivityDetails do
  @moduledoc """
  Stores and reads the per-row details of finished turns' activity cards.
  Written once, when the turn ends; read when a row of its card, or the
  activity panel, opens. Turns from before details were kept have no row,
  which `get/2` reports as `:not_recorded`.
  """

  alias Canopy.Repo
  alias Canopy.Timeline.ActivityDetail

  @doc "Stores the details of the turn recorded as timeline event `event_id`."
  @spec put(String.t(), map) :: {:ok, ActivityDetail.t()} | {:error, Ecto.Changeset.t()}
  def put(event_id, details) when is_binary(event_id) and is_map(details) do
    %ActivityDetail{event_id: event_id, details: details}
    |> Ecto.Changeset.change()
    |> Repo.insert(on_conflict: {:replace, [:details]}, conflict_target: :event_id)
  end

  @doc "Every row's details for the turn, or `:not_recorded`."
  @spec fetch(String.t()) :: map | :not_recorded
  def fetch(event_id) when is_binary(event_id) do
    case Repo.get(ActivityDetail, event_id) do
      nil -> :not_recorded
      %ActivityDetail{details: details} -> details
    end
  end

  @doc """
  One row's details: a map (empty when the row had nothing to show), or
  `:not_recorded` for a turn whose details were never kept.
  """
  @spec get(String.t(), String.t()) :: map | :not_recorded
  def get(event_id, key) when is_binary(event_id) and is_binary(key) do
    case fetch(event_id) do
      :not_recorded -> :not_recorded
      details -> Map.get(details, key, %{})
    end
  end
end
