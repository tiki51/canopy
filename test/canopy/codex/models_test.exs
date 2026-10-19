defmodule Canopy.Codex.ModelsTest do
  @moduledoc "The Codex model list, against the fake binary; env vars are global, so not async."
  use Canopy.DataCase, async: false

  alias Canopy.Codex.Models

  @fixture Path.expand("../../support/codex_fixtures/models.json", __DIR__)

  defp fixture_models do
    @fixture |> File.read!() |> JSON.decode!() |> Map.fetch!("data") |> Enum.map(&Models.parse/1)
  end

  defp visible, do: Enum.reject(fixture_models(), &(&1.id == "internal-preview"))

  defp changeset(params) do
    Ecto.Changeset.cast({%{}, %{model_id: :string, effort: :string}}, params, [:model_id, :effort])
  end

  defp binary, do: Keyword.fetch!(Application.get_env(:canopy, :codex), :binary)

  setup do
    previous = System.get_env("FAKE_CODEX_MODELS")

    on_exit(fn ->
      if previous,
        do: System.put_env("FAKE_CODEX_MODELS", previous),
        else: System.delete_env("FAKE_CODEX_MODELS")

      Models.clear_cache()
    end)

    System.delete_env("FAKE_CODEX_MODELS")
    Models.clear_cache()
    :ok
  end

  describe "parse/1" do
    test "a model/list entry" do
      assert Models.parse(%{
               "id" => "gpt-5-codex",
               "model" => "gpt-5-codex",
               "displayName" => "GPT-5 Codex",
               "isDefault" => true,
               "defaultReasoningEffort" => "medium",
               "supportedReasoningEfforts" => [
                 %{"reasoningEffort" => "low", "description" => ""},
                 %{"reasoningEffort" => "high", "description" => ""}
               ]
             }) == %{
               id: "gpt-5-codex",
               label: "GPT-5 Codex",
               efforts: ["low", "high"],
               default_effort: "medium",
               default?: true
             }
    end

    test "the label falls back to the id; missing fields are empty" do
      assert Models.parse(%{"id" => "x", "displayName" => ""}) == %{
               id: "x",
               label: "x",
               efforts: [],
               default_effort: nil,
               default?: false
             }
    end
  end

  describe "validate/4" do
    test "an empty list (unknown) passes anything" do
      cs =
        Models.validate(changeset(%{model_id: "nope", effort: "ultra"}), [], {:model_id, :effort})

      assert cs.valid?
    end

    test "a model Codex doesn't offer" do
      cs = Models.validate(changeset(%{model_id: "gpt-9"}), visible(), {:model_id, :effort})
      assert %{model_id: ["is not offered by Codex"]} = errors_on(cs)
    end

    test "an effort the model doesn't offer" do
      cs =
        Models.validate(
          changeset(%{model_id: "gpt-5-codex-mini", effort: "xhigh"}),
          visible(),
          {:model_id, :effort}
        )

      assert %{effort: ["gpt-5-codex-mini doesn't offer xhigh"]} = errors_on(cs)

      cs =
        Models.validate(
          changeset(%{model_id: "gpt-5", effort: "max"}),
          visible(),
          {:model_id, :effort}
        )

      assert cs.valid?
    end

    test "no model: the default_model option, else Codex's own default" do
      cs =
        Models.validate(changeset(%{effort: "xhigh"}), visible(), {:model_id, :effort},
          default_model: "gpt-5-codex-mini"
        )

      assert %{effort: ["gpt-5-codex-mini doesn't offer xhigh"]} = errors_on(cs)

      # gpt-5-codex is the fixture's default and offers xhigh, not max
      assert Models.validate(changeset(%{effort: "xhigh"}), visible(), {:model_id, :effort}).valid?

      cs = Models.validate(changeset(%{effort: "max"}), visible(), {:model_id, :effort})
      assert %{effort: ["gpt-5-codex doesn't offer max"]} = errors_on(cs)
    end

    test "no effort, or an unknown default model, passes" do
      assert Models.validate(changeset(%{model_id: "gpt-5"}), visible(), {:model_id, :effort}).valid?

      assert Models.validate(changeset(%{effort: "max"}), visible(), {:model_id, :effort},
               default_model: "someone-elses"
             ).valid?
    end
  end

  test "efforts_for/2 and find/2" do
    models = visible()
    assert Models.efforts_for(models, "gpt-5") == ~w(low medium high xhigh max)
    assert Models.efforts_for(models, "gpt-5-codex-mini") == ~w(low medium high)
    assert Models.efforts_for(models, nil) == ~w(low medium high xhigh)
    assert Models.efforts_for(models, "") == ~w(low medium high xhigh)
    assert Models.efforts_for(models, "gpt-9") == []
    assert Models.efforts_for([], nil) == []

    assert %{id: "gpt-5"} = Models.find(models, "gpt-5")
    assert Models.find(models, "gpt-9") == nil
    assert Models.find(models, nil) == nil
  end

  describe "list/1 against the fake" do
    test "visible models in Codex's order; hidden ones are dropped" do
      assert {:ok, models} = Models.list(binary: binary(), config_dir: nil)
      assert Enum.map(models, & &1.id) == ["gpt-5-codex", "gpt-5", "gpt-5-codex-mini"]
      assert models == visible()
      assert [%{default?: true, label: "GPT-5 Codex", default_effort: "medium"} | _] = models
    end

    test "with the binary and config dir from Settings" do
      assert {:ok, [_ | _]} = Models.list()
    end

    test "a JSON-RPC error is {:error, reason}" do
      System.put_env("FAKE_CODEX_MODELS", "fail")
      assert {:error, reason} = Models.list(binary: binary(), config_dir: nil)
      assert reason =~ "model list unavailable"
    end

    test "a binary that isn't there" do
      assert {:error, reason} = Models.list(binary: "/nonexistent/codex", config_dir: nil)
      assert reason =~ "not found"
    end

    test "with the TTL at 0 (tests), nothing is cached" do
      assert {:ok, _} = Models.list(binary: binary(), config_dir: nil)
      assert Models.cached(binary: binary(), config_dir: nil) == :miss
    end

    test "the cache: hit, refresh: true bypasses it, clear_cache/0 empties it" do
      put_ttl(60_000)
      opts = [binary: binary(), config_dir: nil]

      assert Models.cached(opts) == :miss
      assert {:ok, models} = Models.list(opts)
      assert Models.cached(opts) == {:ok, models}

      # a second list is served from the cache: the fake would fail now
      System.put_env("FAKE_CODEX_MODELS", "fail")
      assert {:ok, ^models} = Models.list(opts)

      # refresh goes to Codex
      assert {:error, _} = Models.list([refresh: true] ++ opts)

      # the cache is per binary and config dir
      assert Models.cached(binary: binary(), config_dir: "/elsewhere") == :miss

      assert Models.clear_cache() == :ok
      assert Models.cached(opts) == :miss
      assert {:error, _} = Models.list(opts)
    end

    test "an expired entry is a miss" do
      put_ttl(60_000)
      opts = [binary: binary(), config_dir: nil]
      assert {:ok, _} = Models.list(opts)
      assert {:ok, _} = Models.cached(opts)

      put_ttl(0)
      assert Models.cached(opts) == :miss
    end
  end

  describe "fetch_with/3" do
    test "follows nextCursor across pages and caches the result" do
      put_ttl(60_000)
      parent = self()

      call = fn "model/list", params ->
        send(parent, {:params, params})

        case params do
          %{"cursor" => "p2"} ->
            {:ok,
             %{"data" => [%{"id" => "b"}, %{"id" => "h", "hidden" => true}], "nextCursor" => nil}}

          _ ->
            {:ok, %{"data" => [%{"id" => "a", "isDefault" => true}], "nextCursor" => "p2"}}
        end
      end

      assert {:ok, [%{id: "a", default?: true}, %{id: "b"}] = models} =
               Models.fetch_with(call, "/bin/codex-x", nil)

      assert_received {:params, %{}}
      assert_received {:params, %{"cursor" => "p2"}}

      assert models ==
               Enum.map([%{"id" => "a", "isDefault" => true}, %{"id" => "b"}], &Models.parse/1)
    end

    test "fills the cache list/1 reads" do
      put_ttl(60_000)
      opts = [binary: binary(), config_dir: "/warm"]
      path = System.find_executable(binary())
      call = fn "model/list", _ -> {:ok, %{"data" => [%{"id" => "warm"}]}} end

      assert {:ok, [%{id: "warm"}]} = Models.fetch_with(call, path, "/warm")
      assert {:ok, [%{id: "warm"}]} = Models.cached(opts)
      assert {:ok, [%{id: "warm"}]} = Models.list(opts)
    end

    test "an error on any page is the error" do
      call = fn "model/list", _ -> {:error, "boom"} end
      assert Models.fetch_with(call, "/bin/codex-y", nil) == {:error, "boom"}
    end
  end

  defp put_ttl(ms) do
    original = Application.get_env(:canopy, :codex)
    Application.put_env(:canopy, :codex, Keyword.put(original, :models_cache_ms, ms))
    on_exit(fn -> Application.put_env(:canopy, :codex, original) end)
  end
end
