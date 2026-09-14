defmodule Canopy.ClaudeCode.Command do
  @moduledoc """
  Builds the command line for one `claude -p` turn, and the stream-json line
  that carries the prompt.

  The process is spawned through `/bin/sh -c 'exec "$0" "$@" 2>>stderr'` so
  stderr goes to a file and never touches the JSON on stdout. The prompt is
  not an argument: it is written to stdin as one stream-json `user` message,
  which starts the turn without an EOF (an Erlang port cannot half-close
  stdin). Every flag lives here and nowhere else.
  """

  @type t :: %{
          executable: String.t(),
          args: [String.t()],
          env: [{charlist(), charlist() | false}],
          cwd: String.t()
        }

  @base ~w(-p --output-format stream-json --input-format stream-json --verbose --include-partial-messages)

  @doc """
  Options:

    * `:binary` (required) — the `claude` executable
    * `:cwd` (required) — the repository path
    * `:stderr_file` (required) — where stderr is appended
    * `:session` (required) — `{:new, id}` (`--session-id`) or `{:resume, id}` (`--resume`)
    * `:model`, `:effort`, `:permission_mode`, `:max_budget_usd`, `:max_turns`
    * `:system_file` — `--append-system-prompt-file`
    * `:mcp_config_file`, `:permission_prompt_tool`
    * `:allowed_tools`, `:disallowed_tools` — lists of tool patterns
    * `:config_dir` — `CLAUDE_CONFIG_DIR`
    * `:mcp_tool_timeout_ms` — `MCP_TOOL_TIMEOUT`, how long an MCP tool call may block
    * `:extra_env` — `[{"KEY", "value"}]`, appended last (tests point the fake binary at a script)
  """
  @spec build(keyword()) :: t()
  def build(opts) do
    binary = Keyword.fetch!(opts, :binary)
    stderr = Keyword.fetch!(opts, :stderr_file)

    session =
      case Keyword.fetch!(opts, :session) do
        {:new, id} -> ["--session-id", id]
        {:resume, id} -> ["--resume", id]
      end

    args =
      @base ++
        session ++
        flag("--model", opts[:model]) ++
        flag("--effort", opts[:effort]) ++
        flag("--append-system-prompt-file", opts[:system_file]) ++
        ["--strict-mcp-config"] ++
        flag("--mcp-config", opts[:mcp_config_file]) ++
        flag("--permission-prompt-tool", opts[:permission_prompt_tool]) ++
        flag("--permission-mode", opts[:permission_mode]) ++
        list_flag("--allowedTools", opts[:allowed_tools]) ++
        list_flag("--disallowedTools", opts[:disallowed_tools]) ++
        flag("--max-budget-usd", opts[:max_budget_usd]) ++
        flag("--max-turns", opts[:max_turns])

    %{
      executable: "/bin/sh",
      args: ["-c", ~s(exec "$0" "$@" 2>>"#{stderr}"), binary | args],
      env: env(opts),
      cwd: Keyword.fetch!(opts, :cwd)
    }
  end

  @doc "The environment for the port: nested-run and updater guards, config dir, MCP timeout."
  def env(opts) do
    base = [
      {~c"CLAUDECODE", false},
      {~c"DISABLE_AUTOUPDATER", ~c"1"}
    ]

    config_dir =
      case opts[:config_dir] do
        dir when is_binary(dir) and dir != "" ->
          [{~c"CLAUDE_CONFIG_DIR", String.to_charlist(dir)}]

        _ ->
          []
      end

    timeout =
      case opts[:mcp_tool_timeout_ms] do
        ms when is_integer(ms) and ms > 0 ->
          [{~c"MCP_TOOL_TIMEOUT", String.to_charlist(Integer.to_string(ms))}]

        _ ->
          []
      end

    extra =
      Enum.map(opts[:extra_env] || [], fn {k, v} ->
        {String.to_charlist(k), String.to_charlist(to_string(v))}
      end)

    base ++ config_dir ++ timeout ++ extra
  end

  @doc """
  One stream-json `user` line. `content` is a string or a list of content
  blocks (`%{type: "text", text: ...}`, `%{type: "image", source: ...}`).
  """
  def user_message(content) when is_binary(content) or is_list(content) do
    JSON.encode!(%{type: "user", message: %{role: "user", content: content}}) <> "\n"
  end

  defp flag(_name, nil), do: []
  defp flag(_name, ""), do: []
  defp flag(name, value), do: [name, to_string(value)]

  defp list_flag(_name, nil), do: []
  defp list_flag(_name, []), do: []
  defp list_flag(name, values) when is_list(values), do: [name | Enum.map(values, &to_string/1)]
end
