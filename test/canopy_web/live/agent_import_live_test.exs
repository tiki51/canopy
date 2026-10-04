defmodule CanopyWeb.AgentImportLiveTest do
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Canopy.{Agents, Memory}
  alias Canopy.Fixtures
  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.Templates.{AgentTemplate, Bundle}

  setup :set_mox_global

  setup do
    stub(OC, :providers, fn _opts ->
      {:ok, %{"providers" => [%{"id" => "openai", "models" => %{"gpt-5.4" => %{}}}]}}
    end)

    stub(OC, :agents, fn _dir, _opts -> {:ok, []} end)
    :ok
  end

  defp template(name, extra \\ "") do
    "---\ncanopy_template: 1\nkind: agent\nname: #{name}\nrole: Imported role\nmode: plan\n#{extra}\n---\nYou are @#{name}.\n"
  end

  defp upload(view, name, content, type \\ "text/markdown") do
    view
    |> file_input("#import-upload-form", :template, [%{name: name, content: content, type: type}])
    |> render_upload(name)
  end

  test "an uploaded file shows the preview; Import creates the agent", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agents/import")
    assert has_element?(view, "#import-drop")
    refute has_element?(view, "#import-preview")

    upload(view, "scout.md", template("scout"))
    assert has_element?(view, "#import-item-1[data-status=new]", "@scout")
    assert has_element?(view, "#import-item-1-permission", "OpenCode · agent plan")
    assert has_element?(view, "#import-apply:not([disabled])", "Import 1")

    view |> form("#import-choices") |> render_submit()
    {path, flash} = assert_redirect(view)
    assert path == ~p"/agents"
    assert flash["info"] == "Imported @scout."
    assert %{role: "Imported role", opencode_agent: "plan"} = Agents.get_by_name("scout")
  end

  test "a file naming no engine follows the default; the engine select can pick one", %{
    conn: conn
  } do
    {:ok, _} = Canopy.Settings.put_default_engine("claude_code")
    {:ok, view, _html} = live(conn, ~p"/agents/import")
    upload(view, "scout.md", template("scout"))

    assert has_element?(
             view,
             "#import-item-1-engine option[value=default][selected]",
             "Default (Claude Code)"
           )

    assert has_element?(view, "#import-item-1-permission", "Claude Code")

    view
    |> form("#import-choices", %{choices: %{"item-1" => %{engine: "opencode"}}})
    |> render_change()

    assert has_element?(view, "#import-item-1-engine option[value=opencode][selected]")
    assert has_element?(view, "#import-item-1-permission", "OpenCode · agent plan")

    view
    |> form("#import-choices", %{choices: %{"item-1" => %{engine: "default"}}})
    |> render_change()

    view |> form("#import-choices") |> render_submit()
    assert_redirect(view)

    assert %{engine: nil, permission_mode: "plan", opencode_agent: "plan"} =
             Agents.get_by_name("scout")
  end

  test "a taken name: rename by default, or replace, or skip", %{conn: conn} do
    existing = Fixtures.agent_fixture(%{name: "taken", role: "Original"})
    {:ok, _} = Memory.put(existing.id, "Kept.")

    {:ok, view, _html} = live(conn, ~p"/agents/import")
    upload(view, "taken.md", template("taken"))

    assert has_element?(view, "#import-item-1[data-status=conflict][data-action=rename]")
    assert has_element?(view, "#import-item-1-name[value=taken-2]")
    assert has_element?(view, "#import-item-1-changes", "Changes from @taken here")

    # skip everything: nothing to import
    view
    |> form("#import-choices", %{choices: %{"item-1" => %{action: "skip"}}})
    |> render_change()

    assert has_element?(view, "#import-apply[disabled]", "Import 0")

    view
    |> form("#import-choices", %{choices: %{"item-1" => %{action: "replace"}}})
    |> render_change()

    assert has_element?(view, "#import-item-1[data-action=replace]")
    refute has_element?(view, "#import-item-1-name")

    view |> form("#import-choices") |> render_submit()
    {_path, flash} = assert_redirect(view)
    assert flash["info"] == "Replaced @taken."
    replaced = Agents.get!(existing.id)
    assert replaced.role == "Imported role"
    assert Memory.get(existing.id) == "Kept."
  end

  test "rename with a typed name", %{conn: conn} do
    Fixtures.agent_fixture(%{name: "twice"})
    {:ok, view, _html} = live(conn, ~p"/agents/import")
    upload(view, "twice.md", template("twice"))

    view
    |> form("#import-choices", %{choices: %{"item-1" => %{action: "rename", name: "twice-copy"}}})
    |> render_change()

    view |> form("#import-choices") |> render_submit()
    {_path, flash} = assert_redirect(view)
    assert flash["info"] == "Imported @twice-copy."
    assert Agents.get_by_name("twice-copy")
  end

  test "pasting a template", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agents/import")

    view
    |> form("#import-paste-form", paste: %{text: template("pasted")})
    |> render_submit()

    assert has_element?(view, "#import-item-1[data-status=new]", "@pasted")
  end

  test "an invalid item disables Import and says why", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agents/import")

    upload(
      view,
      "bad.md",
      template("bad", "engine: claude_code\npermission_mode: bypassPermissions")
    )

    assert has_element?(view, "#import-item-1[data-status=invalid]")
    assert has_element?(view, "#import-item-1-errors", "permission_mode")
    assert has_element?(view, "#import-apply[disabled]")
  end

  test "a file that isn't a template says so", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agents/import")
    upload(view, "notes.md", "# Just notes")
    assert has_element?(view, "#import-item-1-errors", "YAML frontmatter")
    assert has_element?(view, "#import-apply[disabled]")
  end

  test "a bundle zip shows every item", %{conn: conn} do
    zip =
      Bundle.encode(%{name: "pair", description: "Two agents"}, [
        {"agents/one.md", template("one")},
        {"agents/two.md", template("two")}
      ])

    {:ok, view, _html} = live(conn, ~p"/agents/import")
    upload(view, "pair.canopy.zip", zip, "application/zip")

    assert has_element?(view, "#import-manifest", "pair")
    assert has_element?(view, "#import-item-1", "@one")
    assert has_element?(view, "#import-item-2", "@two")
    assert has_element?(view, "#import-apply", "Import 2")

    view |> form("#import-choices") |> render_submit()
    {_path, flash} = assert_redirect(view)
    assert flash["info"] == "Imported @one and @two."
  end

  test "an export reads back as already here", %{conn: conn} do
    agent = Fixtures.agent_fixture(%{name: "roundtrip"})
    {:ok, view, _html} = live(conn, ~p"/agents/import")
    upload(view, "roundtrip.md", AgentTemplate.encode(agent))
    assert has_element?(view, "#import-item-1[data-status=identical][data-action=skip]")
  end
end
