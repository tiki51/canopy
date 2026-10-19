defmodule Canopy.Codex.PricingTest do
  # changes application env
  use ExUnit.Case, async: false

  alias Canopy.Codex.Pricing

  @prices %{
    "gpt-5" => %{input: 1.25, cached_input: 0.125, output: 10.0},
    "gpt-5-mini" => %{input: 0.25, cached_input: 0.025, output: 2.0},
    "default" => %{input: 2.0, cached_input: 0.2, output: 16.0}
  }

  setup do
    old = Application.get_env(:canopy, :codex_list_prices)
    Application.put_env(:canopy, :codex_list_prices, @prices)
    on_exit(fn -> Application.put_env(:canopy, :codex_list_prices, old) end)
    %{shipped: old}
  end

  describe "price/1" do
    test "an exact id" do
      assert Pricing.price("gpt-5") == @prices["gpt-5"]
      assert Pricing.price("gpt-5-mini") == @prices["gpt-5-mini"]
      assert Pricing.known?("gpt-5-mini")
    end

    test "the longest prefix, at a dash" do
      assert Pricing.price("gpt-5-2025-08-07") == @prices["gpt-5"]
      assert Pricing.price("gpt-5-mini-2025-08-07") == @prices["gpt-5-mini"]
      assert Pricing.known?("gpt-5-mini-2025-08-07")
    end

    test "anything else takes the default" do
      # a newer family is not the older one's price
      for model <- ["gpt-5.6-terra", "gpt-6.1-sol", "gpt-6-luna", "codex default", "", nil] do
        assert Pricing.price(model) == @prices["default"], inspect(model)
        refute Pricing.known?(model)
      end

      refute Pricing.known?("default")
    end

    test "with no default configured, an unknown model is still estimated" do
      Application.put_env(:canopy, :codex_list_prices, Map.delete(@prices, "default"))
      assert %{input: i, output: o} = Pricing.price("gpt-7")
      assert i > 0 and o > 0
    end

    test "the shipped table prices the GPT-5 family and has a default", %{shipped: shipped} do
      Application.put_env(:canopy, :codex_list_prices, shipped)

      assert %{input: 1.25, cached_input: 0.125, output: 10.0} = Pricing.price("gpt-5-codex")
      assert %{input: 0.25, cached_input: 0.025, output: 2.0} = Pricing.price("gpt-5-mini")
      assert %{input: i, cached_input: c, output: o} = shipped["default"]
      assert i > 0 and c > 0 and o > 0
    end

    test "each current Codex model resolves to its own row", %{shipped: shipped} do
      Application.put_env(:canopy, :codex_list_prices, shipped)

      current = %{
        "gpt-6-astra" => {10.0, 1.0, 50.0},
        "gpt-6.1-sol" => {2.0, 0.10, 10.0},
        "gpt-6-sol" => {2.0, 0.20, 10.0},
        "gpt-6-luna" => {0.10, 0.01, 0.50},
        "gpt-5.6-sol" => {4.0, 0.40, 20.0},
        "gpt-5.6-terra" => {2.0, 0.20, 12.0},
        "gpt-5.6-luna" => {0.20, 0.02, 1.20},
        "gpt-5.5" => {5.0, 0.50, 30.0},
        "gpt-5.4" => {2.50, 0.25, 15.0},
        "gpt-5.4-mini" => {0.75, 0.075, 4.50},
        "gpt-5.3-codex" => {1.75, 0.175, 14.0}
      }

      for {model, {input, cached, output}} <- current do
        assert Pricing.known?(model), model

        assert Pricing.price(model) == %{input: input, cached_input: cached, output: output},
               model
      end

      # a dated snapshot takes its family's row, not a neighbour's
      assert Pricing.price("gpt-6-sol-2026-09-01").cached_input == 0.20
      assert Pricing.price("gpt-5.4-mini-2026-03-01").input == 0.75

      # the default is gpt-6.1-sol's price
      assert shipped["default"] == shipped["gpt-6.1-sol"]
    end
  end

  describe "cost/2" do
    test "uncached input, cached reads, and output, per million tokens" do
      tokens = %{
        # already input minus cached
        "input" => 200_000,
        "output" => 10_000,
        "reasoning" => 4_000,
        "cache" => %{"read" => 800_000, "write" => 0}
      }

      # 0.2M × 1.25 + 0.8M × 0.125 + 0.01M × 10 (reasoning is inside output)
      assert_in_delta Pricing.cost("gpt-5", tokens), 0.25 + 0.1 + 0.1, 1.0e-9
    end

    test "cache writes are priced as input" do
      tokens = %{"input" => 0, "output" => 0, "cache" => %{"read" => 0, "write" => 1_000_000}}
      assert_in_delta Pricing.cost("gpt-5-mini", tokens), 0.25, 1.0e-9
    end

    test "an unknown model is priced at the default, never free" do
      tokens = %{"input" => 1_000_000, "output" => 1_000_000, "cache" => %{"read" => 1_000_000}}
      assert_in_delta Pricing.cost("gpt-7", tokens), 2.0 + 16.0 + 0.2, 1.0e-9
    end

    test "missing fields count as zero" do
      assert Pricing.cost("gpt-5", %{"output" => 1_000_000}) == 10.0
      assert Pricing.cost("gpt-5", %{}) == 0.0
      assert Pricing.cost("gpt-5", nil) == 0.0
    end
  end
end
