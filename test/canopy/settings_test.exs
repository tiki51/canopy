defmodule Canopy.SettingsTest do
  use Canopy.DataCase, async: false

  alias Canopy.{Settings, Users}

  # every engine registered, whatever config.exs has yet
  setup do
    engines = Application.get_env(:canopy, :engines)
    Application.put_env(:canopy, :engines, Map.put_new(engines, "codex", Canopy.Engine.Codex))
    on_exit(fn -> Application.put_env(:canopy, :engines, engines) end)
    :ok
  end

  test "get/0 creates the default row with a token on first call" do
    setting = Settings.get()
    assert setting.id == "default"
    assert setting.opencode_url == "http://127.0.0.1:4096"
    assert setting.user_display_name == "You"
    assert byte_size(setting.mcp_token) >= 43
    assert Settings.get().mcp_token == setting.mcp_token
  end

  test "rotate_mcp_token/0 replaces the token" do
    before = Settings.get().mcp_token
    assert {:ok, rotated} = Settings.rotate_mcp_token()
    assert rotated.mcp_token != before
    assert Settings.get().mcp_token == rotated.mcp_token
  end

  test "update/1 validates the url and syncs the local user's name" do
    user = Users.local()
    assert user.display_name == "You"

    assert {:error, changeset} = Settings.update(%{opencode_url: "not a url"})
    assert %{opencode_url: [_]} = errors_on(changeset)

    assert {:ok, setting} =
             Settings.update(%{
               opencode_url: "http://localhost:5000",
               user_display_name: "Steven"
             })

    assert setting.opencode_url == "http://localhost:5000"
    assert Users.get!(user.id).display_name == "Steven"
  end

  test "Claude config directory expands HOME and must be absolute" do
    assert {:ok, setting} = Settings.update(%{claude_config_dir: "~/.claude-agents"})
    assert setting.claude_config_dir == Path.join(System.user_home!(), ".claude-agents")

    assert {:error, changeset} = Settings.update(%{claude_config_dir: "relative/path"})
    assert %{claude_config_dir: ["must be an absolute path"]} = errors_on(changeset)
  end

  describe "default models" do
    test "put_default_model/2 round-trips per engine, and nils clear it" do
      assert Settings.default_model("claude_code") == %{model_provider: nil, model_id: nil}

      assert {:ok, _} = Settings.put_default_model("claude_code", %{model_id: "sonnet"})

      assert {:ok, _} =
               Settings.put_default_model("opencode", %{
                 model_provider: "opencode",
                 model_id: "gpt-5-nano"
               })

      assert Settings.default_model("claude_code") == %{model_provider: nil, model_id: "sonnet"}

      assert Settings.default_models() == %{
               "claude_code" => %{model_provider: nil, model_id: "sonnet"},
               "codex" => %{model_provider: nil, model_id: nil},
               "opencode" => %{model_provider: "opencode", model_id: "gpt-5-nano"}
             }

      assert {:ok, _} =
               Settings.put_default_model("opencode", %{model_provider: nil, model_id: nil})

      assert Settings.default_model("opencode") == %{model_provider: nil, model_id: nil}
      # Claude Code has no provider: one passed is ignored
      assert {:ok, _} =
               Settings.put_default_model("claude_code", %{
                 "model_provider" => "x",
                 "model_id" => "opus"
               })

      assert Settings.default_model("claude_code") == %{model_provider: nil, model_id: "opus"}
    end

    test "put_default_model/2 validates like an agent's own model" do
      assert {:error, changeset} =
               Settings.put_default_model("claude_code", %{model_id: "gpt-5-nano"})

      assert %{claude_default_model: [message]} = errors_on(changeset)
      assert message =~ "fable, opus, sonnet, haiku"

      assert {:error, changeset} =
               Settings.put_default_model("opencode", %{model_provider: "opencode", model_id: nil})

      assert %{opencode_default_model: ["pick a model from opencode"]} = errors_on(changeset)

      assert {:error, changeset} =
               Settings.put_default_model("opencode", %{model_provider: nil, model_id: "x"})

      assert %{opencode_default_provider: ["pick a provider for this model"]} =
               errors_on(changeset)

      assert {:error, changeset} = Settings.put_default_model("nope", %{model_id: "x"})
      assert %{model_id: ["nope has no default model"]} = errors_on(changeset)
      assert Settings.default_model("nope") == %{model_provider: nil, model_id: nil}
    end

    test "the Claude Code default effort round-trips; OpenCode has none" do
      assert Settings.default_effort("claude_code") == nil
      assert {:ok, _} = Settings.put_default_effort("claude_code", "high")
      assert Settings.default_effort("claude_code") == "high"

      assert Settings.default_efforts() == %{
               "claude_code" => "high",
               "codex" => nil,
               "opencode" => nil
             }

      assert {:error, changeset} = Settings.put_default_effort("claude_code", "ultra")
      assert %{claude_default_effort: ["is invalid"]} = errors_on(changeset)

      assert {:error, changeset} = Settings.put_default_effort("opencode", "high")
      assert %{effort: ["opencode has no effort setting"]} = errors_on(changeset)

      assert {:ok, _} = Settings.put_default_effort("claude_code", nil)
      assert Settings.default_effort("claude_code") == nil
    end

    test "a changed default is broadcast; an unrelated change is not" do
      Settings.subscribe()

      {:ok, _} = Settings.put_default_model("claude_code", %{model_id: "haiku"})
      assert_receive {:settings, :default_models_changed}

      {:ok, _} = Settings.put_default_effort("claude_code", "low")
      assert_receive {:settings, :default_models_changed}

      {:ok, _} = Settings.update(%{user_display_name: "Someone"})
      refute_receive {:settings, :default_models_changed}, 50

      # saving the same default again changes nothing
      {:ok, _} = Settings.put_default_model("claude_code", %{model_id: "haiku"})
      refute_receive {:settings, :default_models_changed}, 50
    end
  end

  describe "default engine" do
    test "falls back to OpenCode until one is chosen; put_default_engine/1 round-trips" do
      {:ok, _} = Settings.put_default_engine(nil)
      refute Settings.default_engine_chosen?()
      assert Settings.default_engine() == "opencode"

      assert {:ok, setting} = Settings.put_default_engine("claude_code")
      assert setting.default_engine == "claude_code"
      assert Settings.default_engine() == "claude_code"
      assert Settings.default_engine(setting) == "claude_code"
      assert Settings.default_engine_chosen?()

      # blank clears it
      assert {:ok, _} = Settings.update(%{default_engine: " "})
      assert Settings.get().default_engine == nil
      assert Settings.default_engine() == "opencode"
    end

    test "only an engine Canopy has is accepted" do
      assert {:error, changeset} = Settings.put_default_engine("warp")
      assert %{default_engine: [_]} = errors_on(changeset)
      assert Settings.get().default_engine == nil
    end

    test "a change is broadcast with the default models'; saving it again is not" do
      Settings.subscribe()

      {:ok, _} = Settings.put_default_engine("claude_code")
      assert_receive {:settings, :default_models_changed}

      {:ok, _} = Settings.put_default_engine("claude_code")
      refute_receive {:settings, :default_models_changed}, 50
    end
  end

  describe "first-run setup" do
    alias Canopy.Repo
    alias Canopy.Settings.{Presets, Setting}

    test "a fresh row is not onboarded; mark_onboarded/0 stamps it, and again later" do
      Repo.delete_all(Setting)
      refute Settings.onboarded?()

      assert {:ok, %{onboarded_at: first}} = Settings.mark_onboarded()
      assert Settings.onboarded?()

      assert {:ok, %{onboarded_at: second}} = Settings.mark_onboarded()
      assert DateTime.compare(second, first) == :gt
    end

    test "onboarded_at is not cast by update/1" do
      Repo.update_all(Setting, set: [onboarded_at: nil])

      assert {:ok, setting} = Settings.update(%{onboarded_at: DateTime.utc_now()})
      assert setting.onboarded_at == nil
      refute Settings.onboarded?()
    end

    test "user_named?/0 is false while the name is the default" do
      refute Settings.user_named?()
      {:ok, _} = Settings.update(%{user_display_name: "Ada"})
      assert Settings.user_named?()
    end

    test "Presets.match/1 names the preset a row is on, or :custom" do
      setting = Settings.get()

      for preset <- Presets.all() do
        assert Presets.match(struct(setting, preset.attrs)) == preset.id
      end

      assert Presets.match(setting) == :balanced

      assert Presets.match(%{setting | chatter_limit: 12}) == :custom
      assert Presets.match(%{setting | serialize_turns: false}) == :custom

      # with pausing off the limit does nothing, so any limit is Autonomous
      assert Presets.match(%{setting | serialize_turns: false, chatter_pause: false}) ==
               :autonomous
    end

    test "every preset's attrs are valid settings" do
      for preset <- Presets.all() do
        assert Setting.changeset(Settings.get(), preset.attrs).valid?, inspect(preset.id)
        assert {:ok, setting} = Settings.update(preset.attrs)
        assert Presets.match(setting) == preset.id
      end

      assert Presets.get("careful") == Presets.get(:careful)
      assert Presets.get("nope") == nil
    end
  end

  describe "light profiles (model routing)" do
    test "round trip, nil when unset" do
      assert Settings.light_profile("claude_code") == %{
               model_provider: nil,
               model_id: nil,
               effort: nil
             }

      assert {:ok, _} =
               Settings.put_light_profile("claude_code", %{model_id: "haiku", effort: "low"})

      assert {:ok, _} =
               Settings.put_light_profile("opencode", %{
                 model_provider: "opencode",
                 model_id: "small"
               })

      assert Settings.light_profiles() == %{
               "claude_code" => %{model_provider: nil, model_id: "haiku", effort: "low"},
               "codex" => %{model_provider: nil, model_id: nil, effort: nil},
               "opencode" => %{model_provider: "opencode", model_id: "small", effort: nil}
             }

      # keys left out are left alone; nils clear
      assert {:ok, _} = Settings.put_light_profile("claude_code", %{effort: nil})
      assert Settings.light_profile("claude_code").model_id == "haiku"
      assert Settings.light_profile("claude_code").effort == nil
    end

    test "validated like the default models" do
      assert {:error, cs} = Settings.put_light_profile("claude_code", %{model_id: "gpt"})
      assert %{claude_light_model: [_]} = errors_on(cs)
      assert {:error, cs} = Settings.put_light_profile("claude_code", %{effort: "huge"})
      assert %{claude_light_effort: [_]} = errors_on(cs)
      assert {:error, cs} = Settings.put_light_profile("opencode", %{model_id: "small"})
      assert %{opencode_light_provider: [_]} = errors_on(cs)
      assert {:error, _} = Settings.put_light_profile("nope", %{model_id: "x"})
    end

    test "a change is broadcast, separately from the default models" do
      Settings.subscribe()
      {:ok, _} = Settings.put_light_profile("claude_code", %{model_id: "haiku"})
      assert_receive {:settings, :light_profiles_changed}
      refute_receive {:settings, :default_models_changed}, 50
    end
  end

  describe "Codex" do
    test "the binary defaults to codex on PATH; the config dir is optional" do
      setting = Settings.get()
      assert setting.codex_binary == "codex"
      assert setting.codex_config_dir == nil

      assert {:ok, setting} = Settings.update(%{codex_binary: "  /opt/bin/codex  "})
      assert setting.codex_binary == "/opt/bin/codex"

      # blank goes back to the default
      assert {:ok, %{codex_binary: "codex"}} = Settings.update(%{codex_binary: " "})
    end

    test "the config directory expands HOME, must be absolute, and blank clears it" do
      assert {:ok, setting} = Settings.update(%{codex_config_dir: " ~/.codex-agents "})
      assert setting.codex_config_dir == Path.join(System.user_home!(), ".codex-agents")

      assert {:error, changeset} = Settings.update(%{codex_config_dir: "relative/path"})
      assert %{codex_config_dir: ["must be an absolute path"]} = errors_on(changeset)

      assert {:ok, %{codex_config_dir: nil}} = Settings.update(%{codex_config_dir: ""})
    end

    test "normalize_config_dir/1 serves both engines; the Claude name still works" do
      alias Canopy.Settings.Setting

      home = System.user_home!()
      assert Setting.normalize_config_dir("~") == home
      assert Setting.normalize_config_dir(" /tmp/x ") == "/tmp/x"
      assert Setting.normalize_config_dir("  ") == nil
      assert Setting.normalize_config_dir(nil) == nil
      assert Setting.normalize_claude_config_dir("~/a") == Path.join(home, "a")
    end

    test "the default model has no provider and round-trips; models are trimmed" do
      assert Settings.default_model("codex") == %{model_provider: nil, model_id: nil}

      assert {:ok, _} =
               Settings.put_default_model("codex", %{
                 model_provider: "x",
                 model_id: " gpt-6.1-sol "
               })

      assert Settings.default_model("codex") == %{model_provider: nil, model_id: "gpt-6.1-sol"}
      assert Settings.default_models()["codex"] == %{model_provider: nil, model_id: "gpt-6.1-sol"}

      # a Claude Code alias is another engine's model
      assert {:error, changeset} = Settings.put_default_model("codex", %{model_id: "opus"})
      assert %{codex_default_model: [_]} = errors_on(changeset)

      assert {:ok, _} = Settings.put_default_model("codex", %{model_id: nil})
      assert Settings.default_model("codex").model_id == nil
    end

    test "the default effort takes Codex's levels, ultra included" do
      assert Settings.effort?("codex")
      assert Settings.effort?("claude_code")
      refute Settings.effort?("opencode")
      refute Settings.effort?(nil)

      assert {:ok, _} = Settings.put_default_effort("codex", "ultra")
      assert Settings.default_effort("codex") == "ultra"
      assert Settings.default_efforts()["codex"] == "ultra"

      assert {:error, changeset} = Settings.put_default_effort("codex", "minimal")
      assert %{codex_default_effort: ["is invalid"]} = errors_on(changeset)
    end

    test "the light profile round-trips with an effort, validated like the defaults" do
      assert {:ok, _} =
               Settings.put_light_profile("codex", %{model_id: "gpt-5.6-terra", effort: "low"})

      assert Settings.light_profile("codex") ==
               %{model_provider: nil, model_id: "gpt-5.6-terra", effort: "low"}

      assert Settings.light_profiles()["codex"] == Settings.light_profile("codex")

      assert {:error, cs} = Settings.put_light_profile("codex", %{model_id: "haiku"})
      assert %{codex_light_model: [_]} = errors_on(cs)
      assert {:error, cs} = Settings.put_light_profile("codex", %{effort: "huge"})
      assert %{codex_light_effort: [_]} = errors_on(cs)
    end

    test "a stale model on one engine doesn't block saving another's" do
      # a row holding a value today's rules refuse, written around the changeset
      Settings.get() |> Ecto.Changeset.change(codex_default_model: "opus") |> Repo.update!()

      assert {:ok, _} = Settings.put_default_model("claude_code", %{model_id: "sonnet"})
      assert {:ok, _} = Settings.update(%{codex_binary: "codex"})
    end

    test "changes are broadcast like the other engines'" do
      Settings.subscribe()

      {:ok, _} = Settings.put_default_model("codex", %{model_id: "gpt-6-luna"})
      assert_receive {:settings, :default_models_changed}

      {:ok, _} = Settings.put_default_effort("codex", "high")
      assert_receive {:settings, :default_models_changed}

      {:ok, _} = Settings.put_light_profile("codex", %{model_id: "gpt-5.6-terra"})
      assert_receive {:settings, :light_profiles_changed}

      {:ok, _} = Settings.update(%{codex_binary: "/usr/local/bin/codex"})
      refute_receive {:settings, _}, 50
    end
  end
end
