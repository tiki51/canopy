defmodule Canopy.Templates.AgentTemplate do
  @moduledoc """
  One agent as a file: YAML frontmatter (`canopy_template: 1`, `kind: agent`,
  the agent's fields) and the system prompt as the body. With
  `memory: included`, the body splits at the first line that is exactly
  `#{"<!-- canopy:memory -->"}`; everything after it is the agent's memory.

  The frontmatter is engine-neutral where it can be: `mode` (`plan` or
  `build`) says what the agent may do, and `attrs/2` turns it into the
  engine's own setting when the engine-specific key is absent. `model` is a
  Claude Code alias (`opus`) or an OpenCode `provider/model`.

  `decode/2` checks the file (frontmatter, version, kind, field types); the
  agent's own rules (name, enums, models) stay with `Agent.changeset/2`.
  Unknown keys are warnings, so a file from a newer Canopy still imports.
  A Claude Code subagent file (`.claude/agents/*.md`: `name`, `description`,
  `tools`, `model`) is read too, by `from_claude_code/2`.

  Never in a file: ids, `active`, timestamps, sessions and tokens, channels,
  schedules, costs, Settings, notes. Memory only when asked for.
  """

  alias Canopy.Agents.Agent
  alias Canopy.Frontmatter

  @version 1
  @memory_marker "<!-- canopy:memory -->"
  @max_bytes 256 * 1024
  @max_header_bytes 16_000

  @text_keys ~w(name display_name role group color mode engine model effort permission_mode
                opencode_agent memory exported_from)
  @known_keys ["canopy_template", "kind", "allowed_tools" | @text_keys]
  @claude_code_keys ~w(permission_mode effort allowed_tools)
  @opencode_keys ~w(opencode_agent)

  defstruct name: nil,
            display_name: nil,
            role: nil,
            group: nil,
            color: nil,
            mode: nil,
            engine: nil,
            model: nil,
            effort: nil,
            permission_mode: nil,
            allowed_tools: nil,
            opencode_agent: nil,
            system_prompt: nil,
            memory: nil,
            seed: false,
            format: :canopy,
            warnings: []

  @type t :: %__MODULE__{}

  def version, do: @version
  def memory_marker, do: @memory_marker
  def max_bytes, do: @max_bytes
  def max_header_bytes, do: @max_header_bytes

  # -- Writing ------------------------------------------------------------------

  @doc """
  The agent as a template file. `memory:` (text) adds the memory section;
  leave it out (the default) to export the agent alone.
  """
  def encode(%Agent{} = agent, opts \\ []) do
    memory =
      case Keyword.get(opts, :memory) do
        text when is_binary(text) -> if String.trim(text) == "", do: nil, else: String.trim(text)
        _ -> nil
      end

    mode = Agent.execution_mode(agent)

    engine_fields =
      case agent.engine do
        "claude_code" ->
          [
            model: agent.model_id,
            effort: agent.effort,
            permission_mode: agent.permission_mode,
            allowed_tools: Agent.allowed_tools_list(agent)
          ]

        _ ->
          [model: opencode_model(agent), opencode_agent: agent.opencode_agent]
      end

    fields =
      [
        canopy_template: @version,
        kind: "agent",
        name: agent.name,
        display_name: agent.display_name,
        role: agent.role,
        group: agent.group,
        color: agent.color,
        mode: mode && Atom.to_string(mode),
        engine: agent.engine
      ] ++
        engine_fields ++
        [memory: memory && "included", exported_from: Canopy.Templates.exported_from()]

    prompt = String.trim(agent.system_prompt || "")

    body =
      if memory,
        do: prompt <> "\n\n" <> @memory_marker <> "\n\n" <> memory,
        else: prompt

    Frontmatter.document(fields, body)
  end

  defp opencode_model(%Agent{model_provider: p, model_id: m}) when is_binary(p) and is_binary(m),
    do: "#{p}/#{m}"

  defp opencode_model(_agent), do: nil

  # -- Reading ------------------------------------------------------------------

  @doc """
  Reads an agent template: `{:ok, %AgentTemplate{}}` or `{:error, lines}`.
  `gallery: true` also accepts `seed: true`, a key only Canopy's own gallery
  files carry.
  """
  def decode(text, opts \\ []) when is_binary(text) do
    with {:ok, data, body} <-
           Frontmatter.read(text, "the file", @max_bytes, @max_header_bytes),
         :ok <- check_version(data),
         :ok <- check_kind(data, "agent") do
      from_fields(data, body, opts)
    end
  end

  @doc "`:ok` when the file names a version this Canopy reads."
  def check_version(data) do
    case Map.get(data, "canopy_template") do
      nil ->
        {:error, ["canopy_template is missing: this isn't a Canopy template"]}

      @version ->
        :ok

      n when is_integer(n) and n > @version ->
        {:error, ["made by a newer Canopy (template version #{n}); update Canopy to import it"]}

      _ ->
        {:error, ["canopy_template must be #{@version}"]}
    end
  end

  defp check_kind(data, kind) do
    case Map.get(data, "kind") do
      ^kind -> :ok
      nil -> {:error, ["kind is missing (agent, team or bundle)"]}
      other -> {:error, ["expected kind: #{kind}, found #{inspect(other)}"]}
    end
  end

  @doc "Builds the template from already-read frontmatter and body (see `decode/2`)."
  def from_fields(data, body, opts \\ []) do
    allowed = if Keyword.get(opts, :gallery), do: ["seed" | @known_keys], else: @known_keys

    errors =
      Enum.flat_map(@text_keys, &text_error(data, &1)) ++
        tools_error(data["allowed_tools"]) ++
        mode_error(data["mode"]) ++
        seed_error(data["seed"]) ++
        if(blank?(data["name"]), do: ["name is missing"], else: [])

    if errors == [] do
      {prompt, memory, memory_warnings} = split_memory(body, data["memory"])

      {:ok,
       %__MODULE__{
         name: trimmed(data["name"]),
         display_name: trimmed(data["display_name"]),
         role: trimmed(data["role"]),
         group: trimmed(data["group"]),
         color: trimmed(data["color"]),
         mode: trimmed(data["mode"]),
         engine: trimmed(data["engine"]),
         model: trimmed(data["model"]),
         effort: trimmed(data["effort"]),
         permission_mode: trimmed(data["permission_mode"]),
         allowed_tools: tools(data["allowed_tools"]),
         opencode_agent: trimmed(data["opencode_agent"]),
         system_prompt: prompt,
         memory: memory,
         seed: data["seed"] == true,
         warnings: unknown_keys(data, allowed) ++ memory_warnings
       }}
    else
      {:error, errors}
    end
  end

  @doc """
  A Claude Code subagent file (`name`, `description`, the prompt as body):
  `description` becomes the role, a model alias the Claude Code model
  (`inherit` the default). `tools` restricts tools in Claude Code, while
  Canopy's `allowed_tools` approves them, so it is left out, with a notice.
  """
  def from_claude_code(data, body) do
    errors =
      Enum.flat_map(~w(name description model), &text_error(data, &1)) ++
        if(blank?(data["name"]), do: ["name is missing"], else: [])

    if errors == [] do
      description = trimmed(data["description"]) || ""

      {role, role_warnings} =
        if String.length(description) > 200,
          do:
            {String.slice(description, 0, 199) <> "…",
             ["the description was cut to 200 characters for the role"]},
          else: {description, []}

      model =
        case trimmed(data["model"]) do
          "inherit" -> nil
          model -> model
        end

      tool_warnings =
        if Map.has_key?(data, "tools"),
          do: [
            "tools was left out: Claude Code uses it to restrict tools, Canopy's allowed tools approve them"
          ],
          else: []

      other =
        data
        |> Map.drop(~w(name description model tools))
        |> Map.keys()
        |> Enum.sort()
        |> Enum.map(&"#{&1} is a Claude Code setting Canopy doesn't use; ignored")

      {:ok,
       %__MODULE__{
         format: :claude_code,
         name: trimmed(data["name"]),
         role: role,
         engine: "claude_code",
         model: model,
         system_prompt: String.trim(body),
         warnings:
           ["read as a Claude Code subagent file"] ++ role_warnings ++ tool_warnings ++ other
       }}
    else
      {:error, errors}
    end
  end

  defp text_error(data, key) do
    case Map.get(data, key) do
      nil -> []
      value when is_binary(value) -> []
      _ -> ["#{key} must be text"]
    end
  end

  defp tools_error(nil), do: []

  defp tools_error(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1), do: [], else: ["allowed_tools must be a list of text"]
  end

  defp tools_error(_), do: ["allowed_tools must be a list of text"]

  defp mode_error(nil), do: []
  defp mode_error(mode) when mode in ["plan", "build"], do: []
  defp mode_error(mode) when is_binary(mode), do: ["mode must be plan or build"]
  defp mode_error(_), do: []

  defp seed_error(nil), do: []
  defp seed_error(value) when is_boolean(value), do: []
  defp seed_error(_), do: ["seed must be true or false"]

  defp tools(nil), do: nil

  defp tools(list) do
    case list |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> nil
      patterns -> patterns
    end
  end

  defp unknown_keys(data, allowed) do
    (Map.keys(data) -- allowed)
    |> Enum.sort()
    |> Enum.map(&"unknown field #{inspect(&1)}; ignored")
  end

  # Only a file that says it carries memory is split, so a prompt that happens
  # to contain the marker is never cut by accident.
  defp split_memory(body, "included") do
    case String.split(body, ~r/^#{Regex.escape(@memory_marker)}[ \t]*$/m, parts: 2) do
      [prompt, memory] ->
        memory = String.trim(memory)
        {String.trim(prompt), if(memory == "", do: nil, else: memory), []}

      [prompt] ->
        {String.trim(prompt), nil, ["memory: included, but the file has no memory section"]}
    end
  end

  defp split_memory(body, nil), do: {String.trim(body), nil, []}

  defp split_memory(body, _other),
    do: {String.trim(body), nil, ["memory must be included or left out; ignored"]}

  defp trimmed(nil), do: nil

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  # -- Into an agent ------------------------------------------------------------

  @doc """
  The agent attributes for `engine`, as `{attrs, notices}`. Every agent field
  is present (nil where the file says nothing), so the same attrs create a
  new agent or replace an existing one like saving its edit form.

  Engine-specific keys apply when they belong to `engine` and the file named
  that engine or none; otherwise they are dropped with a notice. When the
  engine's own mode key is absent, `mode` sets it (`plan` → OpenCode's `plan`
  agent or Claude Code's `plan` permission mode). `model` is read as the
  engine's kind of model; one that cannot be is dropped, so the agent
  inherits the default.
  """
  def attrs(%__MODULE__{} = t, engine) do
    own? = is_nil(t.engine) or t.engine == engine

    base = %{
      name: t.name,
      display_name: t.display_name,
      role: t.role,
      group: t.group,
      color: t.color,
      system_prompt: t.system_prompt,
      engine: engine,
      opencode_agent: "build",
      permission_mode: "default",
      model_provider: nil,
      model_id: nil,
      effort: nil,
      allowed_tools: nil
    }

    {engine_attrs, notices} = engine_attrs(t, engine, own?)
    dropped = dropped_keys(t, engine, own?)
    {Map.merge(base, engine_attrs), notices ++ dropped}
  end

  defp engine_attrs(t, "claude_code", own?) do
    permission_mode =
      (own? && t.permission_mode) ||
        case t.mode do
          "plan" -> "plan"
          _ -> "default"
        end

    {model, notices} =
      cond do
        not own? or is_nil(t.model) ->
          {nil, []}

        t.model in Agent.claude_models() ->
          {t.model, []}

        true ->
          {nil,
           [
             "model #{t.model} isn't a Claude Code model here (#{Enum.join(Agent.claude_models(), ", ")}); using the default model"
           ]}
      end

    {%{
       permission_mode: permission_mode,
       effort: own? && t.effort,
       allowed_tools: own? && t.allowed_tools && Enum.join(t.allowed_tools, "\n"),
       model_id: model
     }
     |> Map.new(fn {k, v} -> {k, if(v == false, do: nil, else: v)} end), notices}
  end

  defp engine_attrs(t, _opencode, own?) do
    opencode_agent =
      (own? && t.opencode_agent) ||
        case t.mode do
          "plan" -> "plan"
          _ -> "build"
        end

    {provider, model, notices} =
      cond do
        not own? or is_nil(t.model) ->
          {nil, nil, []}

        String.contains?(t.model, "/") ->
          [provider, model] = String.split(t.model, "/", parts: 2)

          if provider != "" and model != "",
            do: {provider, model, []},
            else: {nil, nil, ["model #{t.model} isn't provider/model; using the default model"]}

        true ->
          {nil, nil,
           ["model #{t.model} isn't an OpenCode provider/model; using the default model"]}
      end

    {%{opencode_agent: opencode_agent, model_provider: provider, model_id: model}, notices}
  end

  # A setting the chosen engine has no use for is named, never silently lost.
  defp dropped_keys(t, engine, own?) do
    keys =
      [
        {"permission_mode", t.permission_mode},
        {"effort", t.effort},
        {"allowed_tools", t.allowed_tools},
        {"opencode_agent", t.opencode_agent}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map(&elem(&1, 0))

    for_engine = if engine == "claude_code", do: @claude_code_keys, else: @opencode_keys

    dropped =
      if own?, do: Enum.reject(keys, &(&1 in for_engine)), else: keys

    model = if not own? and t.model, do: ["model #{t.model}"], else: []

    case dropped ++ model do
      [] ->
        []

      names ->
        [
          "#{Enum.join(names, ", ")} #{if length(names) == 1, do: "doesn't", else: "don't"} apply to #{Canopy.Engine.label(engine)}; left out"
        ]
    end
  end
end
