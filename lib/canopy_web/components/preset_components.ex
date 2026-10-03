defmodule CanopyWeb.PresetComponents do
  @moduledoc """
  The conversation presets (`Canopy.Settings.Presets`) as a row of radio
  cards, shared by first-run setup and Settings → Conversation so both pages
  describe the brakes the same way.
  """
  use CanopyWeb, :html

  alias Canopy.Settings.Presets

  @doc """
  One card per preset (ids `<id>-<preset>`), plus a Custom card when
  `custom` is set. Clicking a card sends `event` with `preset` set to its id;
  the page decides whether that selects or saves.
  """
  attr :id, :string, required: true
  attr :selected, :atom, required: true, doc: "a preset id, or `:custom`"
  attr :event, :string, required: true
  attr :custom, :boolean, default: false, doc: "offer a Custom card that reveals the controls"

  def preset_cards(assigns) do
    assigns =
      assign(
        assigns,
        :cards,
        Presets.all() ++
          if(assigns.custom,
            do: [
              %{
                id: :custom,
                name: "Custom",
                summary: "Set the two controls yourself."
              }
            ],
            else: []
          )
      )

    ~H"""
    <div
      id={@id}
      role="radiogroup"
      aria-label="How much agents do on their own"
      class={["grid gap-3", if(@custom, do: "sm:grid-cols-2", else: "sm:grid-cols-3")]}
    >
      <button
        :for={card <- @cards}
        type="button"
        id={"#{@id}-#{card.id}"}
        role="radio"
        aria-checked={to_string(card.id == @selected)}
        phx-click={@event}
        phx-value-preset={card.id}
        class={[
          "flex cursor-pointer flex-col gap-1 rounded-xl border p-3 text-left transition focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary",
          card.id == @selected && "border-transparent bg-primary/10 ring-2 ring-primary",
          card.id != @selected && "border-base-300 bg-base-100 hover:border-base-content/30"
        ]}
      >
        <span class="flex items-center gap-2">
          <span class="text-sm font-semibold">{card.name}</span>
          <span
            :if={card.id == :balanced}
            class="rounded-full bg-base-300/70 px-1.5 py-0.5 text-[11px] font-medium text-base-content/70"
          >
            Recommended
          </span>
          <.icon
            :if={card.id == @selected}
            name="hero-check-circle-mini"
            class="ml-auto size-4 text-primary"
          />
        </span>
        <span class="text-xs text-base-content/70">{card.summary}</span>
      </button>
    </div>
    """
  end
end
