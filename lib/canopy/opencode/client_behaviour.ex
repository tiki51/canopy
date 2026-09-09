defmodule Canopy.OpenCode.ClientBehaviour do
  @moduledoc """
  Contract for talking to an OpenCode server.

  `Canopy.OpenCode.Client` is the real implementation. Tests swap in a Mox
  double (`Canopy.OpenCode.ClientMock`) through `config :canopy, :opencode, client: ...`.

  Every call is scoped to a `directory` (the absolute repository path) because one
  OpenCode server multiplexes many projects through the `?directory=` query parameter.
  """

  @type directory :: String.t()
  @type session_id :: String.t()
  @type result :: {:ok, term()} | {:error, term()}
  @type opts :: keyword()

  @callback health(opts) :: result
  @callback agents(directory, opts) :: result
  @callback create_session(directory, map(), opts) :: result
  @callback get_session(directory, session_id, opts) :: result
  @callback delete_session(directory, session_id, opts) :: result
  @callback children(directory, session_id, opts) :: result
  @callback session_status(directory, opts) :: result
  @callback messages(directory, session_id, keyword(), opts) :: result
  @callback prompt_async(directory, session_id, map(), opts) :: result
  @callback abort(directory, session_id, opts) :: result
  @callback session_diff(directory, session_id, opts) :: result
  @callback vcs_status(directory, opts) :: result
  @callback vcs_diff(directory, String.t(), opts) :: result
  @callback pending_permissions(directory, opts) :: result
  @callback reply_permission(directory, String.t(), :once | :always | :reject, opts) :: result
  @callback add_mcp(directory, String.t(), map(), opts) :: result
  @callback mcp_status(directory, opts) :: result
end
