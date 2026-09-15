defmodule CanopyWeb.SettingsLive do
  @moduledoc """
  Settings: the OpenCode server URL (with a connection check), the Claude Code
  binary (with a version and login check), the local user's display name, the
  collaboration preamble every agent is given, and the MCP section (identity
  plugin source, endpoint URL, token).
  """
  use CanopyWeb, :live_view

  alias Canopy.MCP
  alias Canopy.OpenCode.Client
  alias Canopy.Runtime.Prompts
  alias Canopy.Settings

  @impl true
  def mount(_params, _session, socket) do
    setting = Settings.get()

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:setting, setting)
     |> assign(:opencode_form, to_form(Settings.change(setting), id: "opencode-form"))
     |> assign(:claude_form, to_form(Settings.change(setting), id: "claude-form"))
     |> assign(:claude_check, nil)
     |> assign(:profile_form, to_form(Settings.change(setting), id: "profile-form"))
     |> assign(:chatter_form, to_form(Settings.change(setting), id: "chatter-form"))
     |> assign(:prompt_form, prompt_form(setting))
     |> assign(:draft_url, setting.opencode_url)
     |> assign(:health, nil)
     |> assign(:token_visible, false)
     |> assign(:plugin_path, MCP.global_plugin_path())
     |> assign(:plugin_source, MCP.plugin_source())
     |> assign(:mcp_url, MCP.url())
     |> assign(:mcp_name, MCP.registration_name())
     |> assign(:files_dir, Canopy.Documents.Store.dir())
     |> assign(:files_limit, Canopy.Documents.max_bytes())
     |> assign(:files_count, Canopy.Documents.count())
     |> assign(:files_bytes, Canopy.Documents.total_bytes())}
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

  @claude_fields ["claude_binary", "claude_config_dir", "claude_max_budget_usd"]

  def handle_event("validate_claude", %{"setting" => params}, socket) do
    changeset =
      socket.assigns.setting
      |> Settings.change(Map.take(params, @claude_fields))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:claude_form, to_form(changeset, id: "claude-form"))
     |> assign(:claude_check, nil)}
  end

  def handle_event("save_claude", %{"setting" => params}, socket) do
    case Settings.update(Map.take(params, @claude_fields)) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:setting, setting)
         |> assign(:claude_form, to_form(Settings.change(setting), id: "claude-form"))
         |> put_flash(:info, "Claude Code settings saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :claude_form, to_form(changeset, id: "claude-form"))}
    end
  end

  # Runs the binary named in the form (saved or not): version and login state.
  def handle_event("check_claude", _params, socket) do
    binary = socket.assigns.claude_form[:claude_binary].value |> to_string() |> String.trim()
    config_dir = socket.assigns.claude_form[:claude_config_dir].value

    if binary == "" do
      {:noreply, assign(socket, :claude_check, {:error, "enter the binary first"})}
    else
      {:noreply,
       socket
       |> assign(:claude_check, :checking)
       |> start_async(:claude_check, fn -> Canopy.Engine.ClaudeCode.check(binary, config_dir) end)}
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

  def handle_event("validate_chatter", %{"setting" => params}, socket) do
    changeset =
      socket.assigns.setting
      |> Settings.change(Map.take(params, ["chatter_pause", "chatter_limit", "serialize_turns"]))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :chatter_form, to_form(changeset, id: "chatter-form"))}
  end

  def handle_event("save_chatter", %{"setting" => params}, socket) do
    case Settings.update(Map.take(params, ["chatter_pause", "chatter_limit", "serialize_turns"])) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:setting, setting)
         |> assign(:chatter_form, to_form(Settings.change(setting), id: "chatter-form"))
         |> put_flash(:info, chatter_saved(setting))}

      {:error, changeset} ->
        {:noreply, assign(socket, :chatter_form, to_form(changeset, id: "chatter-form"))}
    end
  end

  def handle_event("validate_prompt", %{"setting" => params}, socket) do
    changeset =
      socket.assigns.setting
      |> Settings.change(prompt_attrs(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :prompt_form, to_form(changeset, id: "prompt-form"))}
  end

  def handle_event("save_prompt", %{"setting" => params}, socket) do
    case Settings.update(prompt_attrs(params)) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:setting, setting)
         |> assign(:prompt_form, prompt_form(setting))
         |> put_flash(:info, prompt_saved(setting))}

      {:error, changeset} ->
        {:noreply, assign(socket, :prompt_form, to_form(changeset, id: "prompt-form"))}
    end
  end

  def handle_event("reset_prompt", _params, socket) do
    case Settings.update(%{"collaboration_prompt" => nil}) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:setting, setting)
         |> assign(:prompt_form, prompt_form(setting))
         |> put_flash(:info, "Collaboration prompt reset to the one Canopy ships.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not reset the prompt.")}
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

  def handle_async(:claude_check, {:ok, result}, socket),
    do: {:noreply, assign(socket, :claude_check, result)}

  def handle_async(:claude_check, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :claude_check, {:error, "check crashed: #{inspect(reason)}"})}

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
      dms={@dms}
      unread={@unread}
      schedule_counts={@schedule_counts}
      hold={@hold}
      current_path={@current_path}
      current_channel_id={@current_channel_id}
      current_repository_id={@current_repository_id}
    >
      <Layouts.page title="Settings" subtitle="Engines, your name, and the MCP bridge">
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
          id="claude-panel"
          title="Claude Code"
          description="Agents on the Claude Code engine run `claude -p` per turn on this machine, with its own login."
        >
          <.form
            for={@claude_form}
            id="claude-form"
            phx-change="validate_claude"
            phx-submit="save_claude"
            class="flex flex-col gap-3"
          >
            <div class="grid gap-3 sm:grid-cols-3">
              <.input
                field={@claude_form[:claude_binary]}
                type="text"
                label="Binary (name on PATH or a path)"
                placeholder="claude"
                autocomplete="off"
                spellcheck="false"
              />
              <.input
                field={@claude_form[:claude_config_dir]}
                type="text"
                label="Config directory (optional)"
                placeholder="~/.claude (your own login)"
                autocomplete="off"
                spellcheck="false"
              />
              <.input
                field={@claude_form[:claude_max_budget_usd]}
                type="number"
                step="0.01"
                min="0"
                label="Spend cap per turn, USD (optional)"
                placeholder="none"
              />
            </div>
            <div class="flex items-center gap-2">
              <.button type="submit" variant="primary" id="save-claude">Save</.button>
              <button type="button" id="check-claude" class="btn btn-soft" phx-click="check_claude">
                Check Claude Code
              </button>
              <.claude_check_result check={@claude_check} />
            </div>
            <p class="text-xs text-base-content/60">
              Leave the config directory empty to use your own Claude Code login and settings
              (your personal MCP servers are still kept out of agent sessions). Point it at a
              directory of its own to isolate agents; run <code class="font-mono">claude</code>
              once with <code class="font-mono">CLAUDE_CONFIG_DIR</code>
              set to log in there.
            </p>
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
          id="chatter-panel"
          title="Conversation"
          description="Agents wake each other by mentioning and by replying to the owner. This is the brake."
        >
          <.form
            for={@chatter_form}
            id="chatter-form"
            phx-change="validate_chatter"
            phx-submit="save_chatter"
            class="flex flex-col gap-3"
          >
            <.input
              field={@chatter_form[:serialize_turns]}
              type="checkbox"
              label="One agent at a time per channel (others wait their turn)"
            />
            <p class="-mt-1 text-xs text-base-content/60">
              Off, agents woken together all run at once. They get in each other's way and
              every one of them spends tokens; keep this on unless you want the swarm.
            </p>
            <.input
              field={@chatter_form[:chatter_pause]}
              type="checkbox"
              label="Pause a channel after agents have taken turns without me"
            />
            <div class={[
              "max-w-xs transition",
              !Phoenix.HTML.Form.normalize_value("checkbox", @chatter_form[:chatter_pause].value) &&
                "opacity-50"
            ]}>
              <.input
                field={@chatter_form[:chatter_limit]}
                type="number"
                min="1"
                max="1000"
                label="Turns before pausing"
              />
            </div>
            <p class="text-xs text-base-content/60">
              A paused channel holds further wakeups and shows a Continue button; your next
              message also resets it. Turn this off for long-running work you want to leave
              alone, and watch the cost.
            </p>
            <div>
              <.button type="submit" variant="primary" id="save-chatter">Save</.button>
            </div>
          </.form>
        </Layouts.panel>

        <Layouts.panel
          id="prompt-panel"
          title="Collaboration prompt"
          description="The instructions every agent is given, above its own role prompt. Canopy fills in the {{variables}} per agent."
        >
          <:actions>
            <span
              :if={customised(@setting)}
              id="prompt-customised"
              class="rounded-full bg-warning/20 px-2 py-0.5 text-[11px] font-medium text-warning-content"
            >
              customised
            </span>
            <.button
              :if={customised(@setting)}
              type="button"
              id="reset-prompt"
              phx-click="reset_prompt"
              data-canopy-confirm="Discard your collaboration prompt and go back to the one Canopy ships?"
            >
              Reset to default
            </.button>
          </:actions>
          <.form
            for={@prompt_form}
            id="prompt-form"
            phx-change="validate_prompt"
            phx-submit="save_prompt"
            class="flex flex-col gap-3"
          >
            <.input
              field={@prompt_form[:collaboration_prompt]}
              type="textarea"
              rows="18"
              label="Instructions"
              class="textarea textarea-bordered w-full font-mono text-xs leading-relaxed"
            />
            <div class="text-xs text-base-content/60">
              <p class="mb-1">Available variables:</p>
              <p class="flex flex-wrap gap-1">
                <code
                  :for={name <- Prompts.preamble_variables()}
                  class="rounded bg-base-300/60 px-1 font-mono text-[11px]"
                >{"{{#{name}}}"}</code>
              </p>
            </div>
            <p class="text-xs text-base-content/60">
              This is also where agents learn the <code class="font-mono">canopy_</code>
              tools exist. Strip that out and they lose the ability to post, delegate, or
              hand off — keep the tool list unless you mean to. Changes reach each agent on
              its next turn; sessions already running keep the text they started with.
            </p>
            <div>
              <.button type="submit" variant="primary" id="save-prompt">Save</.button>
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
                  data-canopy-confirm="Rotate the MCP token? Running OpenCode sessions lose access until Canopy re-registers the MCP server, which happens automatically the next time an agent is prompted."
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
                Canopy installs this into every registered repository at
                <code class="font-mono">.opencode/plugins/canopy.js</code>
                (kept out of git) before an agent's first turn there. To cover repositories you open with OpenCode directly, install it once at
                <code class="font-mono" id="plugin-path">{@plugin_path}</code>
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

        <Layouts.panel
          id="files-panel"
          title="Shared files"
          description="Documents attached in chats are stored once, next to the database, and served from /files/. Manage them on the Files page."
        >
          <dl class="grid grid-cols-[auto_1fr] gap-x-6 gap-y-2 text-sm">
            <dt class="text-base-content/60">Storage directory</dt>
            <dd class="min-w-0 truncate font-mono text-xs" id="files-dir" title={@files_dir}>
              {@files_dir}
            </dd>
            <dt class="text-base-content/60">Size limit per file</dt>
            <dd id="files-limit">
              {Canopy.Documents.size_label(@files_limit)}
              <span class="text-xs text-base-content/50">(CANOPY_MAX_UPLOAD_MB)</span>
            </dd>
            <dt class="text-base-content/60">Stored</dt>
            <dd id="files-stored">
              {@files_count} file(s), {Canopy.Documents.size_label(@files_bytes)} ·
              <.link navigate={~p"/files"} class="link link-primary">Files page</.link>
            </dd>
          </dl>
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

  attr :check, :any, required: true

  defp claude_check_result(assigns) do
    ~H"""
    <span id="claude-check-result" class="flex items-center gap-1.5 text-sm" role="status">
      <%= case @check do %>
        <% nil -> %>
        <% :checking -> %>
          <span class="text-base-content/60">Checking…</span>
        <% {:ok, info} -> %>
          <.icon
            name={
              if info.logged_in, do: "hero-check-circle-mini", else: "hero-exclamation-circle-mini"
            }
            class={["size-4", if(info.logged_in, do: "text-success", else: "text-warning")]}
          />
          <span class={if info.logged_in, do: "text-success", else: "text-warning"}>
            Claude Code {info.version} at <code class="font-mono">{info.path}</code>{if info.logged_in,
              do:
                " · logged in" <>
                  if(info.subscription, do: " (#{info.subscription})", else: "") <>
                  if(info.email, do: " as #{info.email}", else: ""),
              else: " · not logged in: run `claude` once to log in"}
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

  # The textarea always shows the text in force, so a fresh install can be
  # edited from the shipped wording rather than an empty box. Saving it back
  # unchanged means "still the default", so later Canopy updates keep applying.
  defp prompt_form(setting) do
    effective = customised(setting) || Prompts.default_preamble()

    Settings.change(%{setting | collaboration_prompt: effective})
    |> to_form(id: "prompt-form")
  end

  defp prompt_attrs(params) do
    text = params |> Map.get("collaboration_prompt", "") |> to_string()

    if String.trim(text) == String.trim(Prompts.default_preamble()),
      do: %{"collaboration_prompt" => nil},
      else: %{"collaboration_prompt" => text}
  end

  defp customised(%{collaboration_prompt: text}) when is_binary(text) and text != "", do: text
  defp customised(_setting), do: nil

  defp prompt_saved(setting) do
    if customised(setting),
      do: "Collaboration prompt saved. Agents get it on their next turn.",
      else: "That matches the prompt Canopy ships, so the default is back in use."
  end

  defp chatter_saved(%{chatter_pause: false}),
    do: "Pausing is off: agents may keep talking until you step in."

  defp chatter_saved(%{chatter_limit: n}),
    do: "Channels pause after #{n} agent #{if n == 1, do: "turn", else: "turns"} without you."
end
