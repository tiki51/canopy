defmodule CanopyWeb.ChannelNewLiveTest do
  use CanopyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Canopy.Channels
  alias Canopy.Fixtures

  setup do
    repository = Fixtures.repository_fixture()
    builder = Fixtures.agent_fixture(%{name: "builder"})
    reviewer = Fixtures.agent_fixture(%{name: "reviewer"})
    %{repository: repository, builder: builder, reviewer: reviewer}
  end

  test "preselects all active agents as members and the first as owner", ctx do
    inactive = Fixtures.agent_fixture(%{name: "retired"})
    {:ok, _} = Canopy.Agents.deactivate(inactive)

    {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")

    assert has_element?(view, "#channel-form")
    assert has_element?(view, "#member-#{ctx.builder.id}[checked]")
    assert has_element?(view, "#member-#{ctx.reviewer.id}[checked]")
    refute has_element?(view, "#member-#{inactive.id}")

    assert has_element?(
             view,
             "#channel-form select[name='channel[owner_agent_id]'] option[selected][value='#{ctx.builder.id}']"
           )

    assert has_element?(
             view,
             "#channel-form select[name='channel[repository_id]'] option[value='#{ctx.repository.id}']"
           )
  end

  test "select all / clear all toggles every member and keeps the rest of the form", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")

    view
    |> form("#channel-form", channel: %{name: "retry-logic", topic: "keep me"})
    |> render_change()

    assert has_element?(view, "#toggle-all-members", "Clear all")
    view |> element("#toggle-all-members") |> render_click()
    refute has_element?(view, "#member-#{ctx.builder.id}[checked]")
    refute has_element?(view, "#member-#{ctx.reviewer.id}[checked]")
    assert has_element?(view, "#toggle-all-members", "Select all")
    assert has_element?(view, "#channel-form input[name='channel[name]'][value='retry-logic']")
    assert has_element?(view, "#channel-form input[name='channel[topic]'][value='keep me']")

    view |> element("#toggle-all-members") |> render_click()
    assert has_element?(view, "#member-#{ctx.builder.id}[checked]")
    assert has_element?(view, "#member-#{ctx.reviewer.id}[checked]")
    assert has_element?(view, "#toggle-all-members", "Clear all")

    assert has_element?(
             view,
             "#channel-form select[name='channel[owner_agent_id]'] option[selected][value='#{ctx.builder.id}']"
           )
  end

  test "members are grouped under their group labels", ctx do
    {:ok, _} = Canopy.Agents.update(ctx.builder, %{group: "Engineering"})
    {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")
    assert has_element?(view, "#channel-members li", "Engineering")
    assert has_element?(view, "#member-#{ctx.builder.id}")
    assert has_element?(view, "#member-#{ctx.reviewer.id}")
  end

  test "preselects the repository given in the query string", ctx do
    other = Fixtures.repository_fixture(%{name: "zzz-other"})
    {:ok, view, _html} = live(ctx.conn, ~p"/channels/new?repository_id=#{other.id}")

    assert has_element?(
             view,
             "#channel-form select[name='channel[repository_id]'] option[selected][value='#{other.id}']"
           )
  end

  test "creates the channel with members and owner, then redirects into it", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")

    view
    |> form("#channel-form",
      channel: %{
        repository_id: ctx.repository.id,
        name: "Retry-Logic",
        topic: "Make the client retry",
        owner_agent_id: ctx.reviewer.id,
        agent_ids: [ctx.builder.id, ctx.reviewer.id]
      }
    )
    |> render_submit()

    assert %{} = channel = Channels.get_by_name(ctx.repository.id, "retry-logic")
    assert_redirect(view, ~p"/channels/#{channel.id}")

    assert channel.topic == "Make the client retry"
    assert channel.owner_agent_id == ctx.reviewer.id
    assert channel.task.owner_agent_id == ctx.reviewer.id
    assert channel.task.title == "Make the client retry"

    assert Enum.map(channel.agents, & &1.id) |> Enum.sort() ==
             Enum.sort([ctx.builder.id, ctx.reviewer.id])
  end

  test "creates a channel with a spend limit", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")

    view
    |> form("#channel-form",
      channel: %{
        repository_id: ctx.repository.id,
        name: "budgeted",
        owner_agent_id: ctx.reviewer.id,
        agent_ids: [ctx.reviewer.id],
        spend_limit: "4.5"
      }
    )
    |> render_submit()

    assert %{spend_limit: 4.5} = Channels.get_by_name(ctx.repository.id, "budgeted")
  end

  test "a brief added behind \"Add a brief\" is stored with the channel", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")

    refute has_element?(view, "#channel-form textarea[name='channel[brief]']")
    view |> element("#add-brief") |> render_click()
    assert has_element?(view, "#channel-form textarea[name='channel[brief]']")

    view
    |> form("#channel-form",
      channel: %{
        repository_id: ctx.repository.id,
        name: "briefed",
        owner_agent_id: ctx.reviewer.id,
        agent_ids: [ctx.reviewer.id],
        brief: "  Goal: ship it.\nDon't touch vendor/.  "
      }
    )
    |> render_submit()

    channel = Channels.get_by_name(ctx.repository.id, "briefed")
    assert channel.brief == "Goal: ship it.\nDon't touch vendor/."
    assert channel.brief_updated_by == "user"
    assert [%{payload: %{"by" => "user"}}] = Channels.brief_history(channel.id)
  end

  test "a brief over the cap is an error on the form", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")
    view |> element("#add-brief") |> render_click()

    html =
      view
      |> form("#channel-form",
        channel: %{name: "toolong", brief: String.duplicate("x", 4_001)}
      )
      |> render_submit()

    assert html =~ "should be at most 4000 character"
    refute Channels.get_by_name(ctx.repository.id, "toolong")
  end

  test "creates a channel with only the owner as member", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")

    view
    |> form("#channel-form",
      channel: %{
        repository_id: ctx.repository.id,
        name: "solo",
        owner_agent_id: ctx.builder.id,
        agent_ids: [ctx.builder.id]
      }
    )
    |> render_submit()

    assert %{} = channel = Channels.get_by_name(ctx.repository.id, "solo")
    assert_redirect(view, ~p"/channels/#{channel.id}")
    assert Enum.map(channel.agents, & &1.id) == [ctx.builder.id]
    assert channel.task.title == "solo"
  end

  test "unchecking the owner moves ownership to another member", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")

    view
    |> form("#channel-form",
      channel: %{owner_agent_id: ctx.builder.id, agent_ids: [ctx.reviewer.id]}
    )
    |> render_change()

    refute has_element?(view, "#member-#{ctx.builder.id}[checked]")

    refute has_element?(
             view,
             "#channel-form select[name='channel[owner_agent_id]'] option[value='#{ctx.builder.id}']"
           )

    assert has_element?(
             view,
             "#channel-form select[name='channel[owner_agent_id]'] option[selected][value='#{ctx.reviewer.id}']"
           )
  end

  test "shows validation errors inline and does not create anything", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")

    view
    |> form("#channel-form", channel: %{name: "", topic: "x"})
    |> render_submit()

    assert has_element?(view, "#channel-form", "can't be blank")
    assert Channels.list() == []

    view
    |> form("#channel-form", channel: %{name: "Has Spaces"})
    |> render_submit()

    assert has_element?(view, "#channel-form", "must be lowercase letters")
    assert Channels.list() == []
  end

  test "rejects a duplicate name within the repository", ctx do
    Fixtures.channel_fixture(%{
      repository_id: ctx.repository.id,
      name: "taken",
      owner_agent_id: ctx.builder.id
    })

    {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")

    view
    |> form("#channel-form", channel: %{repository_id: ctx.repository.id, name: "taken"})
    |> render_submit()

    assert has_element?(view, "#channel-form", "has already been taken")
    assert length(Channels.list()) == 1
  end

  test "requires at least one member", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")

    render_submit(view, "save", %{
      "channel" => %{"repository_id" => ctx.repository.id, "name" => "lonely", "agent_ids" => []}
    })

    assert has_element?(view, "#channel-form", "pick at least one agent")
    assert Channels.list() == []
  end

  test "points to the repositories screen when there are none", %{conn: conn} do
    Enum.each(Canopy.Repositories.list(), &Canopy.Repositories.delete/1)

    {:ok, view, _html} = live(conn, ~p"/channels/new")

    assert has_element?(view, "#new-channel-no-repositories")
    refute has_element?(view, "#channel-form")
  end

  test "points to the agents screen when there are no active agents", ctx do
    {:ok, _} = Canopy.Agents.deactivate(ctx.builder)
    {:ok, _} = Canopy.Agents.deactivate(ctx.reviewer)

    {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")

    assert has_element?(view, "#new-channel-no-agents")
    refute has_element?(view, "#channel-form")
  end

  describe "teams and groups" do
    setup ctx do
      tester = Fixtures.agent_fixture(%{name: "tester", group: "Review"})
      {:ok, reviewer} = Canopy.Agents.update(ctx.reviewer, %{group: "Review"})

      team =
        Fixtures.team_fixture([tester, ctx.builder], name: "qa-team", lead_agent_id: tester.id)

      %{tester: tester, reviewer: reviewer, team: team}
    end

    test "a team chip ticks its members, or clears them when all are ticked", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")
      view |> element("#toggle-all-members") |> render_click()
      refute has_element?(view, "#member-#{ctx.tester.id}[checked]")

      view |> element("#team-chip-#{ctx.team.id}") |> render_click()
      assert has_element?(view, "#member-#{ctx.tester.id}[checked]")
      assert has_element?(view, "#member-#{ctx.builder.id}[checked]")
      refute has_element?(view, "#member-#{ctx.reviewer.id}[checked]")
      assert has_element?(view, "#team-chip-#{ctx.team.id}[aria-pressed='true']")

      view |> element("#team-chip-#{ctx.team.id}") |> render_click()
      refute has_element?(view, "#member-#{ctx.tester.id}[checked]")
      refute has_element?(view, "#member-#{ctx.builder.id}[checked]")
    end

    test "a group heading toggles everyone in the group", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")

      view |> element("#group-toggle-review") |> render_click()
      refute has_element?(view, "#member-#{ctx.tester.id}[checked]")
      refute has_element?(view, "#member-#{ctx.reviewer.id}[checked]")
      assert has_element?(view, "#member-#{ctx.builder.id}[checked]")

      view |> element("#group-toggle-review") |> render_click()
      assert has_element?(view, "#member-#{ctx.tester.id}[checked]")
      assert has_element?(view, "#member-#{ctx.reviewer.id}[checked]")
    end

    test "?team= preselects only the team's members with its lead as owner", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/channels/new?team=#{ctx.team.id}")

      assert has_element?(view, "#member-#{ctx.tester.id}[checked]")
      assert has_element?(view, "#member-#{ctx.builder.id}[checked]")
      refute has_element?(view, "#member-#{ctx.reviewer.id}[checked]")

      assert has_element?(
               view,
               "#channel-form select[name='channel[owner_agent_id]'] option[selected][value='#{ctx.tester.id}']"
             )

      view
      |> form("#channel-form", channel: %{name: "qa-pass", repository_id: ctx.repository.id})
      |> render_submit()

      channel = Channels.get_by_name(ctx.repository.id, "qa-pass")
      assert channel.owner_agent_id == ctx.tester.id

      assert Enum.map(channel.agents, & &1.id) |> Enum.sort() ==
               Enum.sort([ctx.tester.id, ctx.builder.id])
    end
  end

  describe "section picker" do
    alias Canopy.Channels.Sections

    defp create(view, ctx, extra) do
      # the name field is only there once "New section…" is picked
      if extra[:section] == " new" do
        view
        |> form("#channel-form", channel: %{repository_id: ctx.repository.id, section: " new"})
        |> render_change()
      end

      view
      |> form("#channel-form",
        channel:
          Map.merge(
            %{
              repository_id: ctx.repository.id,
              name: "release-1-9",
              topic: "Cut 1.9",
              owner_agent_id: ctx.builder.id,
              agent_ids: [ctx.builder.id]
            },
            extra
          )
      )
      |> render_submit()
    end

    test "?section= picks that section, or New section… with the name", ctx do
      {:ok, _} = Sections.create(ctx.repository.id, "Payments")
      base = "/channels/new?repository_id=#{ctx.repository.id}&section="

      {:ok, view, _html} = live(ctx.conn, base <> "payments")
      assert has_element?(view, "#channel-form_section option[selected][value='Payments']")

      {:ok, view, _html} = live(ctx.conn, base <> "Releases")
      assert has_element?(view, "#channel-form_section option[selected][value=' new']")
      assert has_element?(view, "#channel-form_section_new[value='Releases']")
    end

    test "lists the repository's sections, and re-lists them for another repository", ctx do
      {:ok, _} = Sections.create(ctx.repository.id, "Payments")
      other = Fixtures.repository_fixture()
      {:ok, _} = Sections.create(other.id, "Launch")

      {:ok, view, _html} = live(ctx.conn, ~p"/channels/new?repository_id=#{ctx.repository.id}")

      select = "#channel-form select[name='channel[section]']"
      assert has_element?(view, "#{select} option[value='']", "No section")
      assert has_element?(view, "#{select} option[value='Payments']")
      assert has_element?(view, "#{select} option[value=' new']", "New section…")
      refute has_element?(view, "#{select} option[value='Launch']")
      refute has_element?(view, "#channel-form input[name='channel[section_new]']")

      view
      |> form("#channel-form", channel: %{repository_id: ctx.repository.id, section: "Payments"})
      |> render_change()

      assert has_element?(view, "#{select} option[selected][value='Payments']")

      # Payments isn't a section of the other repository: back to none
      view
      |> form("#channel-form", channel: %{repository_id: other.id, section: "Payments"})
      |> render_change()

      assert has_element?(view, "#{select} option[value='Launch']")
      refute has_element?(view, "#{select} option[value='Payments']")
      refute has_element?(view, "#{select} option[selected][value='Payments']")
    end

    test "files the new channel in a picked section", ctx do
      {:ok, payments} = Sections.create(ctx.repository.id, "Payments")
      {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")

      create(view, ctx, %{section: "Payments"})

      channel = Channels.get_by_name(ctx.repository.id, "release-1-9")
      assert channel.section_id == payments.id
      flash = assert_redirect(view, ~p"/channels/#{channel.id}")
      assert flash["info"] == "Created #release-1-9 in Payments."
    end

    test "New section… shows a name field; the section is made last and the channel filed", ctx do
      {:ok, _} = Sections.create(ctx.repository.id, "Payments")
      {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")

      view
      |> form("#channel-form", channel: %{repository_id: ctx.repository.id, section: " new"})
      |> render_change()

      assert has_element?(view, "#channel-form input[name='channel[section_new]']")

      create(view, ctx, %{section: " new", section_new: "  Releases "})

      channel = Channels.get_by_name(ctx.repository.id, "release-1-9")
      assert [%{name: "Payments"}, %{name: "Releases", id: id}] = Sections.list(ctx.repository.id)
      assert channel.section_id == id
      flash = assert_redirect(view, ~p"/channels/#{channel.id}")
      assert flash["info"] == "Created #release-1-9 in the new section Releases."
    end

    test "a new name matching a section in another case files it there", ctx do
      {:ok, payments} = Sections.create(ctx.repository.id, "Payments")
      {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")

      create(view, ctx, %{section: " new", section_new: "payments"})

      channel = Channels.get_by_name(ctx.repository.id, "release-1-9")
      assert channel.section_id == payments.id
      assert length(Sections.list(ctx.repository.id)) == 1
      flash = assert_redirect(view, ~p"/channels/#{channel.id}")
      assert flash["info"] == "Created #release-1-9 in Payments."
    end

    test "New section… with no name is an error on the field, and nothing is made", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")

      create(view, ctx, %{section: " new", section_new: " "})

      assert has_element?(view, "#channel-form", "name the new section")
      assert Channels.get_by_name(ctx.repository.id, "release-1-9") == nil
      assert Sections.list(ctx.repository.id) == []
    end

    test "a section name over 40 characters is said under the field; no section is left", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")

      create(view, ctx, %{section: " new", section_new: String.duplicate("x", 41)})

      assert has_element?(view, "#channel-form", "should be at most 40 character(s)")
      assert has_element?(view, "#channel-form input[name='channel[section_new]']")
      assert has_element?(view, "#channel-form select option[selected][value=' new']")
      assert Channels.get_by_name(ctx.repository.id, "release-1-9") == nil
      assert Sections.list(ctx.repository.id) == []
    end

    test "No section puts the channel at the top of the project", ctx do
      {:ok, _} = Sections.create(ctx.repository.id, "Payments")
      {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")

      create(view, ctx, %{section: ""})

      channel = Channels.get_by_name(ctx.repository.id, "release-1-9")
      assert channel.section_id == nil
      flash = assert_redirect(view, ~p"/channels/#{channel.id}")
      assert flash["info"] == "Created #release-1-9."
    end
  end
end
