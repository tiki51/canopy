defmodule CanopyWeb.EngineComponents do
  @moduledoc """
  The default engine choice (`Canopy.Settings.default_engine/1`) as a row of
  radio cards, one per engine with whether it is ready here. Shared by
  first-run setup and Settings, so both pages offer the choice the same way.
  """
  use CanopyWeb, :html

  @doc """
  One card per engine (ids `<id>-<engine>`). Clicking a card sends `event`
  with `engine` set to its name; the page saves it. `readiness` maps an
  engine to `:ready`, `:not_ready`, `:checking`, or `:installed` (found, not
  checked further); an engine left out shows no state.
  """
  attr :id, :string, required: true
  attr :selected, :string, required: true, doc: "the default engine in effect"
  attr :event, :string, default: "pick_default_engine"
  attr :readiness, :map, default: %{}
  attr :not_ready, :map, default: %{}, doc: "engine => what its not-ready badge says"
  attr :titles, :map, default: %{}, doc: "engine => a hint on its not-ready badge"

  def default_engine_choice(assigns) do
    assigns = assign(assigns, :engines, Canopy.Engine.names())

    # Three across only when each card has room for its name and badge on
    # one line (about 210px); the page's sidebar and the setup modal make
    # the row narrower than the viewport, so it asks its container. Never
    # 2 + 1, which reads as if the third engine mattered less.
    ~H"""
    <div class="@container">
      <div
        id={@id}
        role="radiogroup"
        aria-label="Default engine"
        class="grid gap-3 @2xl:grid-cols-3"
      >
        <button
          :for={engine <- @engines}
          type="button"
          id={"#{@id}-#{engine}"}
          role="radio"
          aria-checked={to_string(engine == @selected)}
          data-ready={readiness_value(@readiness[engine])}
          phx-click={@event}
          phx-value-engine={engine}
          class={[
            "flex cursor-pointer items-center gap-2 rounded-xl border p-3 text-left transition focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary",
            engine == @selected && "border-transparent bg-primary/10 ring-2 ring-primary",
            engine != @selected && "border-base-300 bg-base-100 hover:border-base-content/30"
          ]}
        >
          <span class="text-sm font-semibold">{Canopy.Engine.label(engine)}</span>
          <%= case @readiness[engine] do %>
            <% :ready -> %>
              <span class="rounded-full bg-success/15 px-1.5 py-0.5 text-[11px] font-medium text-success">
                Ready
              </span>
            <% :installed -> %>
              <span class="rounded-full bg-base-300/70 px-1.5 py-0.5 text-[11px] font-medium text-base-content/70">
                Installed
              </span>
            <% :not_ready -> %>
              <span
                class="rounded-full bg-base-300/70 px-1.5 py-0.5 text-[11px] font-medium text-base-content/70"
                title={@titles[engine]}
              >
                {Map.get(@not_ready, engine, "Not ready")}
              </span>
            <% :checking -> %>
              <span class="text-[11px] text-base-content/60">Checking…</span>
            <% _ -> %>
          <% end %>
          <.icon
            :if={engine == @selected}
            name="hero-check-circle-mini"
            class="ml-auto size-4 text-primary"
          />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  The bar colour of an engine's row in a per-engine breakdown (Costs' By
  engine), so each engine reads the same wherever it is drawn.
  """
  def engine_bar_class("claude_code"), do: "bg-primary"
  def engine_bar_class("codex"), do: "bg-secondary"
  def engine_bar_class("opencode"), do: "bg-accent"
  def engine_bar_class(_engine), do: "bg-neutral"

  defp readiness_value(nil), do: nil
  defp readiness_value(state), do: Atom.to_string(state)
end
