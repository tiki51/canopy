defmodule Canopy.OpenCode.Providers do
  @moduledoc """
  OpenCode's model catalogue (`GET /config/providers`), normalised for the
  pages and reports that offer or price models: the Agents page, the default
  model in Settings, the spend report, and onboarding.

  `list/1` answers `{:ok, %{providers: [provider], defaults: %{provider_id => model_id}}}`,
  where a provider is `%{id, name, models: [model_id], pricing: %{model_id => pricing | nil}}`
  and a pricing is models.dev's dollars per million tokens
  (`%{input, output, cache_read}`). `defaults` is the server's own default
  model per provider.
  """

  alias Canopy.OpenCode.Client

  @doc """
  Fetches and normalises the catalogue from the server in Settings (or
  `base_url:`); `{:error, reason}` when OpenCode does not answer.
  """
  def list(opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :base_url, fn -> Canopy.Settings.get().opencode_url end)

    case Client.impl().providers(opts) do
      {:ok, %{"providers" => list} = body} when is_list(list) -> {:ok, normalize(body)}
      {:ok, other} -> {:error, {:unexpected, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Normalises a `/config/providers` body (see the moduledoc)."
  def normalize(%{"providers" => list} = body) when is_list(list) do
    providers =
      list
      |> Enum.flat_map(fn
        %{"id" => id} = p when is_binary(id) ->
          model_map = if is_map(p["models"]), do: p["models"], else: %{}
          models = model_map |> Map.keys() |> Enum.sort()
          pricing = Map.new(model_map, fn {mid, m} -> {mid, pricing_of(m)} end)
          [%{id: id, name: Map.get(p, "name") || id, models: models, pricing: pricing}]

        _ ->
          []
      end)
      |> Enum.sort_by(& &1.id)

    defaults = if is_map(body["default"]), do: body["default"], else: %{}
    %{providers: providers, defaults: defaults}
  end

  # models.dev pricing, in dollars per million tokens; nil when OpenCode has none
  defp pricing_of(%{"cost" => %{} = cost}) do
    %{
      input: number(cost["input"]),
      output: number(cost["output"]),
      cache_read: number(get_in(cost, ["cache", "read"]))
    }
  end

  defp pricing_of(_), do: nil

  defp number(n) when is_number(n), do: n / 1
  defp number(_), do: 0.0

  @doc """
  OpenCode's own default, as far as Canopy can tell: the server's default for
  the first provider that has one, as `{provider, model}`, or nil. What an
  agent with no model runs on when Canopy has no OpenCode default either.
  """
  def server_default(defaults) when is_map(defaults) and map_size(defaults) > 0,
    do: Enum.min_by(defaults, fn {p, _} -> p end)

  def server_default(_defaults), do: nil

  @doc "The pricing of a model, or nil when it or its price is unknown."
  def pricing(providers, provider, model) when is_binary(provider) and is_binary(model) do
    case Enum.find(providers, &(&1.id == provider)) do
      %{pricing: pricing} -> Map.get(pricing, model)
      _ -> nil
    end
  end

  def pricing(_providers, _provider, _model), do: nil

  @doc "A pricing as one line for the pickers; nil for an unknown price."
  def price_text(nil, _providers, _provider), do: nil

  # A provider whose every model costs $0 is not free: OpenCode has no per-token
  # price for it, typically a subscription login (ChatGPT, Claude) that bills
  # by plan. A $0 model among priced ones really is free.
  def price_text(%{input: i, output: o, cache_read: c}, providers, provider) do
    cond do
      i == 0 and o == 0 and provider_unpriced?(providers, provider) ->
        "no per-token price reported by OpenCode; usually a subscription login billed by plan"

      i == 0 and o == 0 ->
        "free"

      true ->
        cache = if c > 0, do: " · cached input #{dollars(c)}", else: ""
        "#{dollars(i)} in / #{dollars(o)} out per million tokens#{cache}"
    end
  end

  defp provider_unpriced?(providers, provider) do
    case Enum.find(providers, &(&1.id == provider)) do
      %{pricing: pricing} when map_size(pricing) > 0 ->
        Enum.all?(pricing, fn {_, p} -> is_nil(p) or (p.input == 0 and p.output == 0) end)

      _ ->
        true
    end
  end

  defp dollars(n) when n >= 1, do: "$" <> :erlang.float_to_binary(n / 1, decimals: 2)

  defp dollars(n),
    do:
      "$" <>
        (:erlang.float_to_binary(n / 1, decimals: 3)
         |> String.trim_trailing("0")
         |> String.trim_trailing("."))

  @doc """
  With the provider list known, a model choice must name a configured provider
  and one of its models; otherwise OpenCode rejects every prompt at run time.
  `fields` names the changeset's provider and model fields. A half-filled
  pair is the schema's to report (`Canopy.Agents.Agent.model_errors/3`), and
  an empty list checks nothing (OpenCode is away).
  """
  def validate(changeset, providers, fields \\ {:model_provider, :model_id})

  def validate(changeset, [], _fields), do: changeset

  def validate(changeset, providers, {provider_field, model_field}) do
    provider = Ecto.Changeset.get_field(changeset, provider_field)
    model = Ecto.Changeset.get_field(changeset, model_field)

    case {provider, model, Enum.find(providers, &(&1.id == provider))} do
      {nil, _model, _} ->
        changeset

      {_provider, _model, nil} ->
        Ecto.Changeset.add_error(changeset, provider_field, "is not configured in OpenCode")

      {_provider, nil, _} ->
        changeset

      {_provider, model, %{models: models}} ->
        if model in models,
          do: changeset,
          else:
            Ecto.Changeset.add_error(changeset, model_field, "is not available from #{provider}")
    end
  end

  @doc """
  Select options for the providers, plus the current value flagged
  "(not configured)" when OpenCode no longer offers it.
  """
  def provider_options(providers, current) do
    known = Enum.map(providers, &{provider_label(&1), &1.id})

    if current && not Enum.any?(providers, &(&1.id == current)),
      do: known ++ [{"#{current} (not configured)", current}],
      else: known
  end

  # "OpenAI" reads better than "OpenAI (openai)"; the id is shown only when it
  # is not obvious from the name.
  defp provider_label(%{id: id, name: name}) do
    if String.downcase(name) |> String.replace(~r/[^a-z0-9]/, "") ==
         String.replace(id, ~r/[^a-z0-9]/, ""),
       do: name,
       else: "#{name} (#{id})"
  end

  @doc """
  Select options for one provider's models, plus the current value flagged
  "(not available)" when the provider does not offer it.
  """
  def model_options(providers, provider, current) do
    models =
      case Enum.find(providers, &(&1.id == provider)) do
        %{models: models} -> models
        nil -> []
      end

    options = Enum.map(models, &{&1, &1})

    if current && current not in models,
      do: options ++ [{"#{current} (not available)", current}],
      else: options
  end
end
