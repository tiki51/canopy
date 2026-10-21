defmodule CanopyWeb.FallbackOptions do
  @moduledoc """
  Select options for a fallback model (`Canopy.Fallback`), shared by the
  Settings engine panels and the agent form: one group per engine, in
  `Canopy.Engine.names/0` order, whose values are encoded `"engine:model"`
  (`"opencode:provider/model"`).

  - A model on the primary's own engine is marked `(pauses with <Engine>)`:
    a pause covers the whole engine, so it can't take over.
  - An engine that isn't ready has one disabled note in its group instead of
    models: Claude Code needs its binary, Codex its binary and its models
    loaded, OpenCode its providers listed.
  - A saved value the lists don't offer stays selectable, marked `(saved)`,
    so the select never quietly submits something else
    (`CanopyWeb.CodexOptions` keeps its saved values the same way).
  - `exclude` (the primary model itself) is left out.

  The model lists come from what each page already loads; `sources/1` turns
  them into the `sources` map `options/4` takes.
  """

  alias Canopy.Agents.Agent

  @type source :: {:ok, [String.t()]} | :loading | :not_found | :error

  @doc """
  The `sources` map from what a page has loaded: `claude_found` and
  `codex_found` (`Canopy.Engine.available?/1`), `codex_models` and
  `codex_models_state`, `providers` and `providers_state`.
  """
  def sources(assigns) do
    %{
      "claude_code" =>
        if(assigns.claude_found, do: {:ok, Agent.claude_models()}, else: :not_found),
      "codex" => codex_source(assigns),
      "opencode" => opencode_source(assigns.providers_state, assigns.providers)
    }
  end

  defp codex_source(%{codex_found: false}), do: :not_found

  defp codex_source(%{codex_models_state: :ok, codex_models: models}),
    do: {:ok, Enum.map(models, & &1.id)}

  # nil: the page hasn't started loading them yet
  defp codex_source(%{codex_models_state: state}) when state in [nil, :loading], do: :loading
  defp codex_source(_assigns), do: :error

  defp opencode_source(:ok, providers),
    do: {:ok, for(%{id: p, models: models} <- providers, m <- models, do: "#{p}/#{m}")}

  defp opencode_source(state, _providers) when state in [nil, :loading], do: :loading
  defp opencode_source(_state, _providers), do: :error

  @doc """
  `[{group_label, [option]}]` for `options_for_select/2`, each option
  `[key: label, value: encoded]` (`disabled: true` on a not-ready note).
  """
  def options(primary_engine, sources, current, exclude \\ nil) do
    saved = saved_target(current)
    excluded = exclude not in [nil, ""] && encode(primary_engine, exclude)

    for engine <- Canopy.Engine.names(),
        group = group(engine, primary_engine, Map.get(sources, engine, :error), saved, excluded),
        group != [],
        do: {Canopy.Engine.label(engine), group}
  end

  defp group(engine, primary, source, saved, excluded) do
    models =
      case source do
        {:ok, models} -> models
        _ -> []
      end

    offered =
      for model <- models, encode(engine, model) != excluded do
        [key: label(model, engine, primary, false), value: encode(engine, model)]
      end

    kept =
      case saved do
        {^engine, model} ->
          if model in models,
            do: [],
            else: [[key: label(model, engine, primary, true), value: encode(engine, model)]]

        _ ->
          []
      end

    note(engine, source) ++ offered ++ kept
  end

  defp note(_engine, {:ok, _}), do: []

  defp note(engine, source),
    do: [[key: note_text(engine, source), value: "unavailable:" <> engine, disabled: true]]

  defp note_text("opencode", :loading), do: "Loading OpenCode's models…"
  defp note_text("opencode", _), do: "Not running: start opencode serve to list its models"
  defp note_text(engine, :loading), do: "Loading #{Canopy.Engine.label(engine)}'s models…"

  defp note_text("codex", :error),
    do: "Couldn't read Codex's models: check it in Settings"

  defp note_text(engine, _), do: "#{Canopy.Engine.label(engine)} not found: check it in Settings"

  # "sonnet", "sonnet (pauses with Claude Code)", "sonnet (saved, pauses with Claude Code)"
  defp label(model, engine, primary, saved?) do
    marks =
      [saved? && "saved", engine == primary && "pauses with #{Canopy.Engine.label(engine)}"]
      |> Enum.filter(& &1)

    if marks == [], do: model, else: "#{model} (#{Enum.join(marks, ", ")})"
  end

  defp encode(engine, model), do: "#{engine}:#{model}"

  defp saved_target(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [engine, model] when engine != "" and model != "" -> {engine, model}
      _ -> nil
    end
  end

  defp saved_target(_value), do: nil
end
