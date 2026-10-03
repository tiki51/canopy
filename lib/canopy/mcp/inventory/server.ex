defmodule Canopy.MCP.Inventory.Server do
  @moduledoc """
  One MCP server as the repository page shows it, already redacted: `target`
  is the URL or command line with secrets masked, `secrets` names the header
  and environment keys whose values were masked, and `error` went through
  `Canopy.MCP.Redact.text/1`.

  `source.kind` says where it was configured: `:canopy` (Canopy's own server),
  `:project` (a file in the repository), `:local` and `:user` (Claude Code's
  `~/.claude.json`), `:global` (OpenCode's global config), `:managed` (an
  organisation's managed config), or `:server` (OpenCode reports it but no
  file Canopy scanned defines it). `note` explains anything unusual about the
  row, such as why a configured server is not loaded.
  """

  @type status ::
          :connected | :failed | :disabled | :needs_auth | :needs_client_registration | :unknown

  @type t :: %__MODULE__{
          name: String.t(),
          transport: :stdio | :http | :sse | :local | :remote | nil,
          target: String.t() | nil,
          secrets: [String.t()],
          source: %{kind: atom(), path: String.t() | nil},
          enabled?: boolean(),
          status: status(),
          error: String.t() | nil,
          observed_at: DateTime.t() | nil,
          tool_count: non_neg_integer() | nil,
          note: String.t() | nil
        }

  defstruct [
    :name,
    :transport,
    :target,
    :error,
    :observed_at,
    :tool_count,
    :note,
    secrets: [],
    source: %{kind: :server, path: nil},
    enabled?: true,
    status: :unknown
  ]

  @doc "An engine's status word as a status atom; anything unknown is `:unknown`."
  def status("connected"), do: :connected
  def status("failed"), do: :failed
  def status("disabled"), do: :disabled
  def status(s) when s in ["needs_auth", "needs-auth"], do: :needs_auth
  def status("needs_client_registration"), do: :needs_client_registration
  def status(_), do: :unknown
end
