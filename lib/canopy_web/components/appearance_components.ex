defmodule CanopyWeb.AppearanceComponents do
  @moduledoc """
  The light/dark mode and colour palette picker, shared by Settings →
  Appearance and first-run setup.

  Mode and palette live in this browser's localStorage and are applied by the
  `<head>` script in root.html.heex, so the picker holds no server state: its
  buttons dispatch `phx:set-theme` / `phx:set-palette`, and the selected mode
  and palette are styled from the attributes on `<html>`, like the rail's toggle.
  """
  use CanopyWeb, :html

  # The CSS lives in app.css and the ids are repeated in the <head> script of
  # root.html.heex. `selected`, `check` and `current` spell the classes out per
  # id so Tailwind sees them.
  @palettes [
    %{
      id: "blue-hour",
      name: "Blue Hour Jungle",
      description: "Night navy, jungle green, sky-blue links.",
      default: true,
      selected:
        "[[data-palette=blue-hour]_&]:border-transparent [[data-palette=blue-hour]_&]:ring-2 [[data-palette=blue-hour]_&]:ring-primary",
      check: "[[data-palette=blue-hour]_&]:block",
      current: "[[data-palette=blue-hour]_&]:inline"
    },
    %{
      id: "moss",
      name: "Moss & Paper",
      description: "Warm paper and olive, moss green, clay links.",
      default: false,
      selected:
        "[[data-palette=moss]_&]:border-transparent [[data-palette=moss]_&]:ring-2 [[data-palette=moss]_&]:ring-primary",
      check: "[[data-palette=moss]_&]:block",
      current: "[[data-palette=moss]_&]:inline"
    },
    %{
      id: "graphite",
      name: "Graphite",
      description: "Neutral greys with a single indigo accent.",
      default: false,
      selected:
        "[[data-palette=graphite]_&]:border-transparent [[data-palette=graphite]_&]:ring-2 [[data-palette=graphite]_&]:ring-primary",
      check: "[[data-palette=graphite]_&]:block",
      current: "[[data-palette=graphite]_&]:inline"
    },
    %{
      id: "ember",
      name: "Ember",
      description: "Cream and roast brown, orange actions, teal links.",
      default: false,
      selected:
        "[[data-palette=ember]_&]:border-transparent [[data-palette=ember]_&]:ring-2 [[data-palette=ember]_&]:ring-primary",
      check: "[[data-palette=ember]_&]:block",
      current: "[[data-palette=ember]_&]:inline"
    }
  ]

  @doc "The palettes offered, as `%{id, name, description, default, ...}`."
  def palettes, do: @palettes

  @doc "The mode buttons and palette cards (ids `appearance-mode-*` and `palette-<id>`)."
  def appearance_picker(assigns) do
    assigns = assign(assigns, palettes: @palettes)

    ~H"""
    <div class="flex flex-col gap-5">
      <div>
        <div
          id="appearance-mode-label"
          class="mb-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60"
        >
          Mode
        </div>
        <div class="join" role="group" aria-labelledby="appearance-mode-label">
          <button
            type="button"
            id="appearance-mode-system"
            class="btn btn-sm join-item border-base-300 [[data-theme-source=system]_&]:bg-primary/15 [[data-theme-source=system]_&]:text-primary [[data-theme-source=system]_&]:border-primary/40"
            phx-click={JS.dispatch("phx:set-theme")}
            data-phx-theme="system"
          >
            <.icon name="hero-computer-desktop-micro" class="size-4" /> System
          </button>
          <button
            type="button"
            id="appearance-mode-light"
            class="btn btn-sm join-item border-base-300 [[data-theme=light][data-theme-source=user]_&]:bg-primary/15 [[data-theme=light][data-theme-source=user]_&]:text-primary [[data-theme=light][data-theme-source=user]_&]:border-primary/40"
            phx-click={JS.dispatch("phx:set-theme")}
            data-phx-theme="light"
          >
            <.icon name="hero-sun-micro" class="size-4" /> Light
          </button>
          <button
            type="button"
            id="appearance-mode-dark"
            class="btn btn-sm join-item border-base-300 [[data-theme=dark][data-theme-source=user]_&]:bg-primary/15 [[data-theme=dark][data-theme-source=user]_&]:text-primary [[data-theme=dark][data-theme-source=user]_&]:border-primary/40"
            phx-click={JS.dispatch("phx:set-theme")}
            data-phx-theme="dark"
          >
            <.icon name="hero-moon-micro" class="size-4" /> Dark
          </button>
        </div>
      </div>

      <div>
        <div
          id="appearance-palette-label"
          class="mb-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60"
        >
          Palette
        </div>
        <div
          id="appearance-palettes"
          class="grid gap-3 sm:grid-cols-2"
          role="radiogroup"
          aria-labelledby="appearance-palette-label"
          phx-update="ignore"
          phx-hook=".PaletteRadios"
        >
          <button
            :for={palette <- @palettes}
            type="button"
            id={"palette-#{palette.id}"}
            role="radio"
            aria-checked="false"
            data-phx-palette={palette.id}
            phx-click={JS.dispatch("phx:set-palette")}
            class={[
              "group relative flex cursor-pointer flex-col gap-2 rounded-xl border border-base-300 bg-base-200 p-3 text-left transition hover:border-base-content/30 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary",
              palette.selected
            ]}
          >
            <div
              class="flex h-20 overflow-hidden rounded-lg border border-base-300"
              aria-hidden="true"
            >
              <.palette_preview palette={palette.id} mode="light" />
              <.palette_preview palette={palette.id} mode="dark" />
            </div>
            <div class="flex items-center gap-2">
              <span class="text-sm font-semibold">{palette.name}</span>
              <span
                :if={palette.default}
                class="rounded-full bg-base-300/70 px-1.5 py-0.5 text-[11px] font-medium text-base-content/70"
              >
                Default
              </span>
              <.icon
                name="hero-check-circle-mini"
                class={["ml-auto hidden size-4 text-primary", palette.check]}
              />
            </div>
            <p class="text-xs text-base-content/60">{palette.description}</p>
          </button>
        </div>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".PaletteRadios">
          export default {
            mounted() {
              const current = document.documentElement.dataset.palette
              const radios = [...this.el.querySelectorAll("[role=radio]")]
              radios.forEach((el) => el.setAttribute("aria-checked", String(el.dataset.phxPalette === current)))
              // Arrow keys move between cards, as in a native radio group.
              this.el.addEventListener("keydown", (e) => {
                const step = {ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1}[e.key]
                if (!step) return
                e.preventDefault()
                const next = radios[(radios.indexOf(document.activeElement) + step + radios.length) % radios.length]
                next.focus()
                next.click()
              })
            }
          }
        </script>
      </div>
    </div>
    """
  end

  @doc """
  The palette and mode in force in this browser, as text ("Moss & Paper,
  dark"). Every name is rendered and CSS shows the one matching `<html>`, so
  it needs no server state either.
  """
  attr :id, :string, required: true

  def current_appearance(assigns) do
    assigns = assign(assigns, palettes: @palettes)

    ~H"""
    <%!-- One line, so no stray space shows before the punctuation that follows. --%>
    <span id={@id} phx-no-format><span :for={palette <- @palettes} data-palette-name={palette.id} class={["hidden font-semibold", palette.current]}>{palette.name}</span>, <span class="hidden font-semibold [[data-theme-source=system]_&]:inline">following the system</span><span class="hidden font-semibold [[data-theme=light][data-theme-source=user]_&]:inline">light</span><span class="hidden font-semibold [[data-theme=dark][data-theme-source=user]_&]:inline">dark</span></span>
    """
  end

  attr :palette, :string, required: true
  attr :mode, :string, required: true

  # A miniature of the app painted in one palette and mode, whatever the page uses.
  defp palette_preview(assigns) do
    ~H"""
    <div data-theme={@mode} data-palette={@palette} class="flex flex-1 bg-base-100">
      <div class="w-2 border-r border-base-300/60 bg-neutral"></div>
      <div class="flex w-8 flex-col gap-1 border-r border-base-300 bg-base-200 p-1">
        <div class="h-1 rounded-full bg-base-content/30"></div>
        <div class="h-1.5 rounded bg-primary/40"></div>
        <div class="h-1 rounded-full bg-base-content/30"></div>
        <div class="h-1 rounded-full bg-base-content/30"></div>
      </div>
      <div class="flex flex-1 flex-col gap-1 bg-base-100 p-1.5">
        <div class="h-1 w-3/4 rounded-full bg-base-content/70"></div>
        <div class="h-1 w-1/2 rounded-full bg-base-content/30"></div>
        <div class="h-1 w-1/3 rounded-full bg-secondary"></div>
        <div class="mt-auto h-2 w-5 self-end rounded-sm bg-primary"></div>
      </div>
    </div>
    """
  end
end
