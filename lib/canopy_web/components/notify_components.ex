defmodule CanopyWeb.NotifyComponents do
  @moduledoc """
  The desktop notifications controls, shared by Settings → Notifications and
  first-run setup.

  Notifications belong to the browser: permission is granted per browser and
  origin, and the preferences live in its localStorage (`assets/js/notify.js`,
  reached through `window.canopyNotifier`). So the controls hold no server
  state: a colocated hook reads and writes the tab's notifier and shows one
  state, `data-state` on `#notify-prefs`: `unsupported` (no Notification API,
  or not a secure origin, as at a LAN address under `CANOPY_BIND`), `off`,
  `on`, or `blocked` (the browser said no). Other tabs follow a change.

  The notifier also marks `<html data-notify="…">` with the same state, so a
  page can say whether notifications are on from CSS alone
  (`current_notify/1`).
  """
  use CanopyWeb, :html

  @doc """
  The master switch (off until the user turns it on; turning it on is the
  click that asks the browser), what happened, and with `kinds` the
  per-kind toggles and a test button, disabled while the switch is off.
  """
  attr :kinds, :boolean, default: true, doc: "show the per-kind toggles and the test button"

  def notify_prefs(assigns) do
    ~H"""
    <div
      id="notify-prefs"
      phx-hook=".NotifyPrefs"
      phx-update="ignore"
      data-state="off"
      class="flex flex-col gap-4"
    >
      <p
        id="notify-unsupported"
        hidden
        class="rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-sm text-base-content/70"
      >
        This browser can't show notifications here. They need Canopy opened at
        <span class="font-mono">http://127.0.0.1</span>
        or <span class="font-mono">http://localhost</span>
        (not a network address) in a browser that supports them.
      </p>

      <div id="notify-main" class="flex flex-col gap-4">
        <label
          for="notify-enabled"
          class="flex cursor-pointer items-center justify-between gap-4 rounded-lg border border-base-300 bg-base-100 px-3 py-2.5"
        >
          <span class="min-w-0">
            <span class="block text-sm font-semibold">Desktop notifications</span>
            <span class="block text-xs text-base-content/60">
              When an agent is waiting on you, mentions you, or finishes while you look elsewhere.
            </span>
          </span>
          <span class="flex shrink-0 items-center gap-2">
            <span id="notify-enabled-label" class="text-xs font-medium text-base-content/70">
              Off
            </span>
            <input id="notify-enabled" type="checkbox" role="switch" class="toggle toggle-primary" />
          </span>
        </label>

        <p
          id="notify-granted"
          hidden
          role="status"
          class="flex items-center gap-1.5 text-xs text-success"
        >
          <.icon name="hero-check-circle-mini" class="size-4" />
          On. The browser allows notifications from Canopy.
        </p>

        <p
          id="notify-blocked"
          hidden
          role="status"
          class="rounded-lg border border-warning/40 bg-warning/10 px-3 py-2 text-xs text-base-content/80"
        >
          Notifications are blocked for this site. Allow them in the browser's site settings
          (the icon left of the address), and on macOS check System Settings → Notifications →
          your browser. Then turn the switch on again.
        </p>

        <fieldset
          :if={@kinds}
          id="notify-kinds"
          disabled
          class="flex flex-col gap-2 disabled:opacity-60"
        >
          <legend class="mb-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
            Notify me when
          </legend>
          <.notify_kind id="notify-needs_you" pref="needs_you" label="An agent needs you">
            a question or permission card, or a playbook step waiting for your sign-off
          </.notify_kind>
          <.notify_kind id="notify-mention" pref="mention" label="An agent mentions you">
            with @ and your name, or writes to you in a direct message
          </.notify_kind>
          <.notify_kind id="notify-work" pref="work" label="Work finished">
            while Canopy is in the background: a channel went quiet, paused, or completed its task
          </.notify_kind>
          <.notify_kind id="notify-sound" pref="sound" label="Play a sound">
            the system's notification sound; off by default
          </.notify_kind>
        </fieldset>

        <div :if={@kinds} class="flex flex-wrap items-center gap-3">
          <button id="notify-test" type="button" class="btn btn-soft btn-sm" disabled>
            <.icon name="hero-bell-alert" class="size-4" /> Send a test notification
          </button>
          <p class="text-xs text-base-content/60">
            Kept in this browser only, and followed by its other tabs. Turning them off here (or
            from the command palette) doesn't revoke the browser's permission.
          </p>
        </div>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".NotifyPrefs">
      export default {
        mounted() {
          this.notifier = window.canopyNotifier
          if (!this.notifier) return
          this.switch = this.el.querySelector("#notify-enabled")
          this.kinds = [...this.el.querySelectorAll("[data-notify-pref]")]

          // asked straight from the click: the browser shows its prompt only then
          this.switch.addEventListener("change", () => {
            this.notifier.setEnabled(this.switch.checked).then(() => this.render())
          })
          this.kinds.forEach((box) => box.addEventListener("change", () => {
            this.notifier.setPrefs({[box.dataset.notifyPref]: box.checked})
          }))
          const test = this.el.querySelector("#notify-test")
          if (test) test.addEventListener("click", () => this.notifier.test())

          this.unsubscribe = this.notifier.subscribe(() => this.render())
          this.render()
        },
        // phx-update="ignore" keeps the children but still patches the
        // container's data-* attributes, so any re-render of the page puts the
        // server's data-state="off" back: say it again.
        updated() {
          if (this.notifier) this.render()
        },
        destroyed() {
          if (this.unsubscribe) this.unsubscribe()
        },
        render() {
          const $ = (id) => this.el.querySelector("#" + id)
          const show = (id, visible) => { const el = $(id); if (el) el.hidden = !visible }
          const status = this.notifier.status()
          const prefs = this.notifier.prefs()
          const on = status === "on"
          this.el.dataset.state = status
          show("notify-unsupported", status === "unsupported")
          show("notify-main", status !== "unsupported")
          show("notify-blocked", status === "blocked")
          show("notify-granted", on)
          this.switch.checked = on
          $("notify-enabled-label").textContent = on ? "On" : "Off"
          if ($("notify-kinds")) $("notify-kinds").disabled = !on
          if ($("notify-test")) $("notify-test").disabled = !on
          this.kinds.forEach((box) => { box.checked = prefs[box.dataset.notifyPref] === true })
        }
      }
    </script>
    """
  end

  attr :id, :string, required: true
  attr :pref, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  defp notify_kind(assigns) do
    ~H"""
    <label for={@id} class="flex cursor-pointer items-start gap-2.5">
      <input id={@id} type="checkbox" data-notify-pref={@pref} class="checkbox checkbox-sm mt-0.5" />
      <span class="min-w-0">
        <span class="block text-sm">{@label}</span>
        <span class="block text-xs text-base-content/60">{render_slot(@inner_block)}</span>
      </span>
    </label>
    """
  end

  @doc """
  Whether desktop notifications are on in this browser, as text: every state
  is rendered and CSS shows the one `<html data-notify>` names.
  """
  attr :id, :string, required: true

  def current_notify(assigns) do
    ~H"""
    <span id={@id} phx-no-format><span class="hidden font-semibold [[data-notify=on]_&]:inline">on</span><span class="hidden font-semibold [[data-notify=off]_&]:inline">off</span><span class="hidden font-semibold [[data-notify=blocked]_&]:inline">blocked by the browser</span><span class="hidden font-semibold [[data-notify=unsupported]_&]:inline">not available in this browser</span></span>
    """
  end
end
