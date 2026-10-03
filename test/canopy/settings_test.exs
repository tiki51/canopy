defmodule Canopy.SettingsTest do
  use Canopy.DataCase, async: false

  alias Canopy.{Settings, Users}

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
      assert Settings.default_efforts() == %{"claude_code" => "high", "opencode" => nil}

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
end
