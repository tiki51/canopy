defmodule Canopy.Settings.Presets do
  @moduledoc """
  Named combinations of the conversation brakes (`serialize_turns`,
  `chatter_pause`, `chatter_limit`), offered by first-run setup and
  Settings → Conversation. Applying one is `Canopy.Settings.update(preset.attrs)`;
  `match/1` tells which one a settings row is on, or `:custom`.
  """

  alias Canopy.Settings.Setting

  # Autonomous leaves `chatter_limit` alone: with pausing off it does nothing,
  # and it is still there if pausing is turned back on.
  @presets [
    %{
      id: :careful,
      name: "Careful",
      summary:
        "One agent works at a time, and the channel pauses for you after 3 agent turns. " <>
          "Best while you're learning how they behave.",
      attrs: %{serialize_turns: true, chatter_pause: true, chatter_limit: 3}
    },
    %{
      id: :balanced,
      name: "Balanced",
      summary: "One agent at a time, pausing for you after 6 agent turns. The default.",
      attrs: %{serialize_turns: true, chatter_pause: true, chatter_limit: 6}
    },
    %{
      id: :autonomous,
      name: "Autonomous",
      summary:
        "Agents run side by side and keep going until the work is done or you step in. " <>
          "Fastest, and it spends the most tokens, so watch the Costs page. Agents running " <>
          "at once share the repository's working tree: their edits and test runs can collide.",
      attrs: %{serialize_turns: false, chatter_pause: false}
    }
  ]

  @doc "Every preset, as `%{id, name, summary, attrs}`, in display order."
  def all, do: @presets

  @doc "The preset with this id (atom or string), or nil."
  def get(id) when is_atom(id), do: Enum.find(@presets, &(&1.id == id))
  def get(id) when is_binary(id), do: Enum.find(@presets, &(Atom.to_string(&1.id) == id))
  def get(_id), do: nil

  @doc "The id of the preset the settings are on, or `:custom`."
  def match(%Setting{} = setting) do
    case Enum.find(@presets, &matches?(setting, &1.attrs)) do
      %{id: id} -> id
      nil -> :custom
    end
  end

  defp matches?(setting, attrs),
    do: Enum.all?(attrs, fn {field, value} -> Map.get(setting, field) == value end)
end
