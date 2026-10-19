defmodule CanopyWeb.CodexOptions do
  @moduledoc """
  Select options for Codex models and efforts, from `Canopy.Codex.Models.list/1`,
  shared by Settings, first-run setup and the agent form.

  The efforts on offer always follow a model: the one chosen in the form, else
  a fallback (the default from Settings), else Codex's own default model. A
  saved value the list doesn't offer stays selectable, so a select never
  silently submits something else; `Canopy.Codex.Models.validate/3` flags it.
  """

  alias Canopy.Agents.Agent

  @doc "`{label, id}` for each model, plus `current` when the list lacks it."
  def model_options(models, current) do
    models
    |> Enum.map(&{&1.label, &1.id})
    |> keep_current(current)
  end

  @doc "The model whose efforts are on offer (nil when none is known)."
  def effective_model(models, chosen, fallback \\ nil) do
    Enum.find_value([chosen, fallback], fn id -> present?(id) && find(models, id) end) ||
      Enum.find(models, & &1.default?)
  end

  @doc """
  The efforts of the effective model, plus `current` when it lacks it. With no
  model known (Codex sent none), every effort a Codex agent may name.
  """
  def effort_options(models, chosen, fallback, current) do
    case effective_model(models, chosen, fallback) do
      %{efforts: efforts} -> efforts
      nil -> Agent.efforts("codex")
    end
    |> keep_current(current)
  end

  @doc """
  The prompt of an effort select left on its default: the effective model's
  own default effort when Codex names one, else `fallback`.
  """
  def effort_prompt(models, chosen, model_fallback, fallback) do
    case effective_model(models, chosen, model_fallback) do
      %{default_effort: effort} when is_binary(effort) -> "Default (#{effort})"
      _ -> fallback
    end
  end

  @doc "A model's label, with the id when they differ."
  def label(models, id) do
    case find(models, id) do
      %{label: label} when label != id -> "#{label} (#{id})"
      _ -> id
    end
  end

  defp find(models, id), do: Enum.find(models, &(&1.id == id))

  defp keep_current(options, current) do
    if present?(current) and not Enum.any?(options, &(option_value(&1) == current)),
      do: options ++ [current],
      else: options
  end

  defp option_value({_label, value}), do: value
  defp option_value(value), do: value

  defp present?(value), do: value not in [nil, ""]
end
