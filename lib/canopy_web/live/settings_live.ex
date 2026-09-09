defmodule CanopyWeb.SettingsLive do
  @moduledoc """
  Settings: the OpenCode server URL (with a connection check), the local user's
  display name, and the MCP section (identity plugin source, endpoint URL, token).
  """
  use CanopyWeb, :live_view

  alias Canopy.MCP
  alias Canopy.OpenCode.Client
  alias Canopy.Settings

  @plugin_path "~/.config/opencode/plugins/canopy.js"

  @impl true
  def mount(_params, _session, socket) do
    setting = Settings.get()

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:setting, setting)
     |> assign(:opencode_form, to_form(Settings.change(setting), id: "opencode-form"))
     |> assign(:profile_form, to_form(Settings.change(setting), id: "profile-form"))
     |> assign(:draft_url, setting.opencode_url)
     |> assign(:health, nil)
     |> assign(:token_visible, false)
     |> assign(:plugin_path, @plugin_path)
     |> assign(:plugin_source, MCP.plugin_source())
     |> assign(:mcp_url, MCP.url())
     |> assign(:mcp_name, MCP.registration_name())}
  end

  @impl true
  def handle_event("validate_opencode", %{"setting" => params}, socket) do
    changeset =
      socket.assigns.setting
      |> Settings.change(Map.take(params, ["opencode_url"]))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:opencode_form, to_form(changeset, id: "opencode-form"))
     |> assign(:draft_url, String.trim(params["opencode_url"] || ""))
     |> assign(:health, nil)}
  end

  def handle_event("save_opencode", %{"setting" => params}, socket) do
    case Settings.update(Map.take(params, ["opencode_url"])) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:setting, setting)
         |> assign(:draft_url, setting.opencode_url)
         |> assign(:opencode_form, to_form(Settings.change(setting), id: "opencode-form"))
         |> put_flash(:info, "OpenCode server URL saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :opencode_form, to_form(changeset, id: "opencode-form"))}
    end
  end

  def handle_event("check_connection", _params, socket) do
    url = socket.assigns.draft_url

    if url == "" do
      {:noreply, assign(socket, :health, {:error, "enter a server URL first"})}
    else
      {:noreply,
       socket
       |> assign(:health, :checking)
       |> start_async(:health, fn -> Client.impl().health(base_url: url) end)}
    end
  end

  def handle_event("validate_profile", %{"setting" => params}, socket) do
    changeset =
      socket.assigns.setting
      |> Settings.change(Map.take(params, ["user_display_name"]))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :profile_form, to_form(changeset, id: "profile-form"))}
  end

  def handle_event("save_profile", %{"setting" => params}, socket) do
    case Settings.update(Map.take(params, ["user_display_name"])) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:setting, setting)
         |> assign(:profile_form, to_form(Settings.change(setting), id: "profile-form"))
         |> put_flash(:info, "Display name saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :profile_form, to_form(changeset, id: "profile-form"))}
    end
  end

  def handle_event("toggle_token", _params, socket) do
    {:noreply, update(socket, :token_visible, &(!&1))}
  end

  def handle_event("rotate_token", _params, socket) do
    case Settings.rotate_mcp_token() do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:setting, setting)
         |> put_flash(
           :info,
           "MCP token rotated. OpenCode is re-registered automatically the next time an agent is prompted."
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not rotate the MCP token.")}
    end
  end

  @impl true
  def handle_async(:health, {:ok, result}, socket) do
    {:noreply, assign(socket, :health, normalize_health(result))}
  end

  def handle_async(:health, {:exit, reason}, socket) do
    {:noreply, assign(socket, :health, {:error, "check crashed: #{inspect(reason)}"})}
  end

  defp normalize_health({:ok, %{} = body}) do
    healthy = Map.get(body, "healthy", true)
    version = Map.get(body, "version")

    if healthy,
      do: {:ok, version},
      else: {:error, "server reports unhealthy" <> if(version, do: " (#{version})", else: "")}
  end

  defp normalize_health({:ok, _other}), do: {:ok, nil}
  defp normalize_health({:error, reason}), do: {:error, describe_error(reason)}

  defp describe_error({:transport, %{reason: :econnrefused}}),
    do: "connection refused. Is `opencode serve` running?"

  defp describe_error({:transport, %{reason: :nxdomain}}), do: "host not found"
  defp describe_error({:transport, %{reason: :timeout}}), do: "timed out"

  defp describe_error({:transport, %{reason: reason}}),
    do: "connection failed (#{inspect(reason)})"

  defp describe_error({:transport, reason}), do: "connection failed (#{inspect(reason)})"
  defp describe_error({:http, status, _body}), do: "server answered HTTP #{status}"
  defp describe_error(reason) when is_binary(reason), do: reason
  defp describe_error(reason), do: inspect(reason)

  defp mask_token(token) when is_binary(token) do
    String.slice(token, 0, 4) <> String.duplicate("•", 20) <> String.slice(token, -4, 4)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      repositories={@repositories}
      agents={@agents}
      current_path={@current_path}
      current_channel_id={@current_channel_id}
    >
      <Layouts.page title="Settings" subtitle="OpenCode connection, your name, and the MCP bridge">
        <Layouts.panel
          id="opencode-panel"
          title="OpenCode server"
          description="Canopy talks to one `opencode serve` instance and passes each repository as the directory."
        >
          <.form
            for={@opencode_form}
            id="opencode-form"
            phx-change="validate_opencode"
            phx-submit="save_opencode"
            class="flex flex-col gap-3"
          >
            <.input
              field={@opencode_form[:opencode_url]}
              type="url"
              label="Server URL"
              placeholder="http://127.0.0.1:4096"
              autocomplete="off"
            />
            <div class="flex items-center gap-2">
              <.button type="submit" variant="primary" id="save-opencode">Save</.button>
              <button
                type="button"
                id="check-connection"
                class="btn btn-soft"
                phx-click="check_connection"
                disabled={@health == :checking}
              >
                <.icon
                  :if={@health == :checking}
                  name="hero-arrow-path"
                  class="size-4 motion-safe:animate-spin"
                />
                <.icon :if={@health != :checking} name="hero-signal" class="size-4" />
                Check connection
              </button>
              <.health_result health={@health} />
            </div>
          </.form>
        </Layouts.panel>

        <Layouts.panel
          id="profile-panel"
          title="You"
          description="How your messages are attributed in channels."
        >
          <.form
            for={@profile_form}
            id="profile-form"
            phx-change="validate_profile"
            phx-submit="save_profile"
            class="flex flex-col gap-3"
          >
            <.input
              field={@profile_form[:user_display_name]}
              type="text"
              label="Display name"
              autocomplete="off"
            />
            <div>
              <.button type="submit" variant="primary" id="save-profile">Save</.button>
            </div>
          </.form>
        </Layouts.panel>

        <Layouts.panel
          id="mcp-panel"
          title="MCP bridge"
          description="Agents reach Canopy through an MCP server that Canopy registers with OpenCode on demand."
        >
          <div class="flex flex-col gap-5">
            <div class="alert alert-soft alert-info text-xs" id="mcp-transport-note">
              <.icon name="hero-information-circle" class="size-4 shrink-0" />
              <span>
                The MCP endpoint is served only while Canopy runs under
                <code class="font-mono">mix phx.server</code>
                (or with <code class="font-mono">PHX_SERVER=true</code>).
              </span>
            </div>

            <div>
              <div class="mb-1 text-xs font-semibold uppercase tracking-wide text-base-content/60">
                Endpoint URL
              </div>
              <div class="flex items-center gap-2">
                <code
                  id="mcp-url"
                  class="flex-1 truncate rounded-md border border-base-300 bg-base-200 px-3 py-1.5 font-mono text-sm"
                >
                  {@mcp_url}
                </code>
                <.copy_button id="copy-mcp-url" target="#mcp-url" />
              </div>
              <p class="mt-1 text-xs text-base-content/60">
                Registered with OpenCode under the name <code class="font-mono">{@mcp_name}</code>, so tools appear as <code class="font-mono">{@mcp_name}_*</code>.
              </p>
            </div>

            <div>
              <div class="mb-1 text-xs font-semibold uppercase tracking-wide text-base-content/60">
                Bearer token
              </div>
              <div class="flex items-center gap-2">
                <code
                  id="mcp-token"
                  class="flex-1 truncate rounded-md border border-base-300 bg-base-200 px-3 py-1.5 font-mono text-sm"
                  data-token={@setting.mcp_token}
                >
                  {if @token_visible, do: @setting.mcp_token, else: mask_token(@setting.mcp_token)}
                </code>
                <button
                  type="button"
                  id="toggle-token"
                  class="btn btn-soft btn-sm"
                  phx-click="toggle_token"
                  title={if @token_visible, do: "Hide token", else: "Reveal token"}
                >
                  <.icon
                    name={if @token_visible, do: "hero-eye-slash", else: "hero-eye"}
                    class="size-4"
                  />
                </button>
                <button
                  type="button"
                  id="rotate-token"
                  class="btn btn-soft btn-warning btn-sm"
                  phx-click="rotate_token"
                  data-confirm="Rotate the MCP token? Running OpenCode sessions lose access until Canopy re-registers the MCP server, which happens automatically the next time an agent is prompted."
                >
                  <.icon name="hero-arrow-path-rounded-square" class="size-4" /> Rotate token
                </button>
              </div>
              <p class="mt-1 flex items-center gap-1 text-xs text-warning">
                <.icon name="hero-exclamation-triangle-mini" class="size-3.5" />
                Rotating invalidates the current registration. OpenCode must be re-registered;
                the runtime does this automatically when it next prompts an agent.
              </p>
            </div>

            <div>
              <div class="mb-1 flex items-center justify-between">
                <div class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                  Identity plugin
                </div>
                <.copy_button id="copy-plugin" target="#plugin-source" label="Copy plugin" />
              </div>
              <p class="mb-2 text-xs text-base-content/60">
                Install once at <code class="font-mono" id="plugin-path">{@plugin_path}</code>
                and restart <code class="font-mono">opencode serve</code>. It stamps the real
                OpenCode session id into every Canopy tool call so agents cannot impersonate each other.
              </p>
              <pre
                id="plugin-source"
                class="max-h-72 overflow-auto rounded-md border border-base-300 bg-base-200 p-3 font-mono text-xs leading-relaxed"
              >{@plugin_source}</pre>
            </div>
          </div>
        </Layouts.panel>
      </Layouts.page>
    </Layouts.app>
    """
  end

  attr :health, :any, required: true

  defp health_result(assigns) do
    ~H"""
    <span id="health-result" class="flex items-center gap-1.5 text-sm" role="status">
      <%= case @health do %>
        <% nil -> %>
        <% :checking -> %>
          <span class="text-base-content/60">Checking…</span>
        <% {:ok, version} -> %>
          <.icon name="hero-check-circle-mini" class="size-4 text-success" />
          <span class="text-success">
            Connected{if version, do: " · OpenCode #{version}", else: ""}
          </span>
        <% {:error, reason} -> %>
          <.icon name="hero-x-circle-mini" class="size-4 text-error" />
          <span class="text-error">{reason}</span>
      <% end %>
    </span>
    """
  end

  attr :id, :string, required: true
  attr :target, :string, required: true, doc: "CSS selector of the element whose text is copied"
  attr :label, :string, default: "Copy"

  defp copy_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      class="btn btn-soft btn-sm"
      phx-hook=".CopyText"
      data-copy-target={@target}
      title={@label}
    >
      <.icon name="hero-clipboard-document" class="size-4" />
      <span data-copy-label>{@label}</span>
    </button>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyText">
      export default {
        mounted() {
          this.el.addEventListener("click", () => {
            const target = document.querySelector(this.el.dataset.copyTarget)
            if (!target) return
            const text = target.dataset.token || target.textContent.trim()
            const label = this.el.querySelector("[data-copy-label]")
            const original = label ? label.textContent : null
            navigator.clipboard.writeText(text).then(() => {
              if (label) {
                label.textContent = "Copied"
                setTimeout(() => { label.textContent = original }, 1500)
              }
            })
          })
        }
      }
    </script>
    """
  end
end
