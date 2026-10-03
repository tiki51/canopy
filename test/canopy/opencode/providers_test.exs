defmodule Canopy.OpenCode.ProvidersTest do
  use Canopy.DataCase, async: false

  import Mox

  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.OpenCode.Providers
  alias Canopy.Settings.Setting

  setup :set_mox_global
  setup :verify_on_exit!

  @body %{
    "providers" => [
      %{
        "id" => "opencode",
        "name" => "OpenCode Zen",
        "models" => %{
          "claude-haiku-4-5" => %{
            "cost" => %{"input" => 1, "output" => 5, "cache" => %{"read" => 0.1}}
          },
          "gpt-5-nano" => %{
            "cost" => %{"input" => 0.05, "output" => 0.4, "cache" => %{"read" => 0.005}}
          },
          "big-pickle" => %{"cost" => %{"input" => 0, "output" => 0}},
          "mystery" => %{}
        }
      },
      %{
        "id" => "openai",
        "name" => "OpenAI",
        "models" => %{"gpt-5.4" => %{"cost" => %{"input" => 0, "output" => 0}}}
      },
      %{"name" => "no id"}
    ],
    "default" => %{"opencode" => "gpt-5-nano", "openai" => "gpt-5.4"}
  }

  test "list/1 asks the server in Settings and normalises the catalogue" do
    test_pid = self()

    expect(OC, :providers, fn opts ->
      send(test_pid, {:asked, opts[:base_url]})
      {:ok, @body}
    end)

    assert {:ok, %{providers: [openai, opencode], defaults: defaults}} = Providers.list()
    assert_receive {:asked, url}
    assert url == Canopy.Settings.get().opencode_url

    assert openai == %{
             id: "openai",
             name: "OpenAI",
             models: ["gpt-5.4"],
             pricing: %{"gpt-5.4" => %{input: 0.0, output: 0.0, cache_read: 0.0}}
           }

    assert opencode.models == ["big-pickle", "claude-haiku-4-5", "gpt-5-nano", "mystery"]
    assert opencode.pricing["mystery"] == nil
    assert opencode.pricing["gpt-5-nano"] == %{input: 0.05, output: 0.4, cache_read: 0.005}
    assert defaults == %{"opencode" => "gpt-5-nano", "openai" => "gpt-5.4"}
    assert Providers.server_default(defaults) == {"openai", "gpt-5.4"}
    assert Providers.server_default(%{}) == nil

    stub(OC, :providers, fn _opts -> {:error, :down} end)
    assert {:error, :down} = Providers.list(base_url: "http://elsewhere")
  end

  test "pricing/3 and price_text/3" do
    %{providers: providers} = Providers.normalize(@body)

    assert Providers.price_text(
             Providers.pricing(providers, "opencode", "claude-haiku-4-5"),
             providers,
             "opencode"
           ) == "$1.00 in / $5.00 out per million tokens · cached input $0.1"

    # a $0 model among priced ones is free; a provider with no prices is unpriced
    assert Providers.price_text(
             Providers.pricing(providers, "opencode", "big-pickle"),
             providers,
             "opencode"
           ) == "free"

    assert Providers.price_text(
             Providers.pricing(providers, "openai", "gpt-5.4"),
             providers,
             "openai"
           ) =~ "no per-token price reported"

    assert Providers.pricing(providers, "opencode", "mystery") == nil
    assert Providers.pricing(providers, "nope", "x") == nil
    assert Providers.price_text(nil, providers, "opencode") == nil
  end

  test "validate/3 checks a pair against the live list, on any pair of fields" do
    %{providers: providers} = Providers.normalize(@body)
    fields = {:opencode_default_provider, :opencode_default_model}

    check = fn attrs ->
      %Setting{id: "default"}
      |> Ecto.Changeset.cast(attrs, [:opencode_default_provider, :opencode_default_model])
      |> Providers.validate(providers, fields)
      |> errors_on()
    end

    assert check.(%{opencode_default_provider: "opencode", opencode_default_model: "gpt-5-nano"}) ==
             %{}

    assert check.(%{opencode_default_provider: "anthropic", opencode_default_model: "x"}) ==
             %{opencode_default_provider: ["is not configured in OpenCode"]}

    assert check.(%{opencode_default_provider: "openai", opencode_default_model: "gpt-5-nano"}) ==
             %{opencode_default_model: ["is not available from openai"]}

    # half pairs are the schema's to report; no list means nothing to check
    assert check.(%{opencode_default_provider: "opencode"}) == %{}

    assert %Setting{id: "default"}
           |> Ecto.Changeset.cast(%{opencode_default_provider: "anthropic"}, [
             :opencode_default_provider
           ])
           |> Providers.validate([], fields)
           |> errors_on() == %{}
  end

  test "the select options flag a value OpenCode no longer offers" do
    %{providers: providers} = Providers.normalize(@body)

    assert Providers.provider_options(providers, "opencode") == [
             {"OpenAI", "openai"},
             {"OpenCode Zen (opencode)", "opencode"}
           ]

    assert List.last(Providers.provider_options(providers, "anthropic")) ==
             {"anthropic (not configured)", "anthropic"}

    assert List.last(Providers.model_options(providers, "openai", "gpt-9")) ==
             {"gpt-9 (not available)", "gpt-9"}
  end
end
