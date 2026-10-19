defmodule Canopy.Codex.Pricing do
  @moduledoc """
  Estimated dollars for a Codex turn, from OpenAI's API list prices in
  `config :canopy, :codex_list_prices` (USD per million tokens, a map of
  model id or id prefix to `%{input, cached_input, output}`). Codex reports
  tokens, never dollars, so every Codex cost is an estimate (shown with ≈),
  and a ChatGPT plan is not billed per token at all.

  A model is looked up by its exact id, else by the longest entry its id
  starts with followed by `-` (`gpt-5-2025-08-07` is priced as `gpt-5`, but
  `gpt-5.6-terra` is not), else by the `"default"` entry: the flagship
  Codex price, so an unknown new model is estimated rather than free.
  """

  @type price :: %{input: float, cached_input: float, output: float}

  # used only when the config carries no "default" entry: gpt-6.1-sol
  @fallback %{input: 2.0, cached_input: 0.10, output: 10.0}

  @doc """
  The estimated cost in USD of `tokens`, Canopy's token map
  (`%{"input", "output", "reasoning", "cache" => %{"read", "write"}}`), on
  `model`. `"input"` is the uncached input (Codex's input minus its cached
  input); cached reads are priced at the cached-input rate and cache writes
  as input. Reasoning tokens are part of `"output"`, so they are not added.
  """
  @spec cost(String.t() | nil, map | nil) :: float
  def cost(model, tokens) when is_map(tokens) do
    price = price(model)
    cache = if is_map(tokens["cache"]), do: tokens["cache"], else: %{}

    (number(tokens["input"]) * price.input + number(cache["write"]) * price.input +
       number(cache["read"]) * price.cached_input + number(tokens["output"]) * price.output) /
      1_000_000
  end

  def cost(_model, _tokens), do: 0.0

  @doc "The price entry for `model`: exact id, else the longest prefix, else the default."
  @spec price(String.t() | nil) :: price
  def price(model) do
    prices = prices()
    Map.get(prices, lookup(model, prices)) || Map.get(prices, "default") || @fallback
  end

  @doc "Whether `model` has a price of its own (exact or by prefix), not the default."
  @spec known?(String.t() | nil) :: boolean
  def known?(model), do: lookup(model, prices()) != nil

  defp lookup(model, prices) when is_binary(model) do
    if Map.has_key?(prices, model) and model != "default" do
      model
    else
      prices
      |> Map.keys()
      |> Enum.filter(&(&1 != "default" and String.starts_with?(model, &1 <> "-")))
      |> Enum.max_by(&String.length/1, fn -> nil end)
    end
  end

  defp lookup(_model, _prices), do: nil

  defp prices, do: Application.get_env(:canopy, :codex_list_prices, %{})

  defp number(n) when is_number(n), do: n
  defp number(_), do: 0
end
