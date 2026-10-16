defmodule CanopyWeb.SidebarSectionsLiveTest do
  @moduledoc """
  The sidebar's sections and archiving as rendered (CanopyWeb.Sidebar), the
  channel page's "Task done" bar, and the palette's data. The events
  themselves are `CanopyWeb.NavSectionsTest`'s.
  """
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import Canopy.PlaybookHelpers

  alias Canopy.{Channels, Fixtures, Messages, Tasks}
  alias Canopy.Channels.Sections

  setup :set_mox_global

  setup do
    ctx = Fixtures.scenario()
    on_exit(&stop_channels/0)
    stub_engine(self(), ctx.repository)
    ctx
  end

  defp channel(ctx, name, attrs \\ %{}) do
    Fixtures.channel_fixture(
      Map.merge(
        %{repository_id: ctx.repository.id, owner_agent_id: ctx.agent.id, name: name},
        attrs
      )
    )
  end

  defp file(channel, section) do
    {:ok, channel} = Sections.move_channel(Channels.get!(channel.id), section)
    channel
  end

  # Ids of the elements of `tag` whose id starts with `prefix`, in page order.
  defp order(html, tag, prefix) do
    Regex.scan(~r/<#{tag}\b[^>]*\sid="#{prefix}([^"]+)"/, html, capture: :all_but_first)
    |> List.flatten()
  end

  # A page with no channel of its own.
  defp page(conn), do: live(conn, ~p"/agents")

  describe "the sidebar" do
    test "unsectioned channels first, then sections by position; A→Z inside", ctx do
      zeta = channel(ctx, "zeta")
      {:ok, testing} = Sections.create(ctx.repository.id, "Testing")
      {:ok, payments} = Sections.create(ctx.repository.id, "Payments")
      refunds = channel(ctx, "refunds") |> file(payments)
      billing = channel(ctx, "billing") |> file(payments)
      load = channel(ctx, "load") |> file(testing)

      {:ok, view, html} = page(ctx.conn)

      assert order(html, "button", "sidebar-section-toggle-") == [payments.id, testing.id]

      rows = order(html, "li", "sidebar-row-")

      assert Enum.take(rows, 2) ==
               Enum.sort_by([ctx.channel, zeta], & &1.name) |> Enum.map(& &1.id)

      assert Enum.drop(rows, 2) == [billing.id, refunds.id, load.id]

      assert has_element?(view, "#sidebar-top-#{ctx.repository.id} #sidebar-row-#{zeta.id}")
      assert has_element?(view, "#sidebar-section-#{payments.id} #sidebar-row-#{billing.id}")
      assert has_element?(view, "#sidebar-section-#{testing.id}[data-section-name='Testing']")
      assert has_element?(view, "#sidebar-row-#{billing.id}[data-section-id='#{payments.id}']")
      assert has_element?(view, "#sidebar-new-section-btn-#{ctx.repository.id}[data-new-section]")

      assert has_element?(
               view,
               "#sidebar-new-section-#{ctx.repository.id}[data-section-editor=create]"
             )

      assert has_element?(view, "#sidebar-projects[phx-hook=SidebarChannels]")
      assert has_element?(view, "#sidebar-menu[popover=auto][phx-update=ignore]")
      assert has_element?(view, "#sidebar-undo-toast[phx-hook=UndoToast][phx-update=ignore]")
    end

    test "archived channels fold under N archived, whatever their section", ctx do
      {:ok, payments} = Sections.create(ctx.repository.id, "Payments")
      old = channel(ctx, "old") |> file(payments)
      {:ok, _} = Channels.archive(old)

      {:ok, view, _html} = page(ctx.conn)

      refute has_element?(view, "#sidebar-row-#{old.id}")
      assert has_element?(view, "#sidebar-archived-#{ctx.repository.id}", "1 archived")

      assert has_element?(
               view,
               "#sidebar-archived-#{ctx.repository.id} #sidebar-channel-#{old.id}"
             )
    end

    test "a collapsed section hides its rows and shows a count, and a dot for unread", ctx do
      {:ok, launch} = Sections.create(ctx.repository.id, "Launch")
      quiet = channel(ctx, "quiet") |> file(launch)
      busy = channel(ctx, "busy") |> file(launch)
      {:ok, launch} = Sections.set_collapsed(launch, true)

      {:ok, view, _html} = page(ctx.conn)

      toggle = "#sidebar-section-toggle-#{launch.id}"
      assert has_element?(view, "#{toggle}[aria-expanded=false][phx-click=toggle_section]")
      assert has_element?(view, "#{toggle}[phx-value-collapsed=false]")
      assert has_element?(view, "#sidebar-section-count-#{launch.id}", "2")
      assert has_element?(view, "#sidebar-row-#{quiet.id}.hidden")
      assert has_element?(view, "#sidebar-row-#{busy.id}.hidden")
      refute has_element?(view, "#sidebar-section-dot-#{launch.id}")

      {:ok, _} = Messages.post_agent_message(busy.id, ctx.agent.id, "a finding")
      assert has_element?(view, "#sidebar-section-dot-#{launch.id}")

      {:ok, _} = Sections.set_collapsed(launch, false)
      assert has_element?(view, "#{toggle}[aria-expanded=true][phx-value-collapsed=true]")
      refute has_element?(view, "#sidebar-section-count-#{launch.id}")
      refute has_element?(view, "#sidebar-row-#{busy.id}.hidden")
    end

    test "the open channel still shows under its collapsed section", ctx do
      {:ok, launch} = Sections.create(ctx.repository.id, "Launch")
      here = file(ctx.channel, launch)
      other = channel(ctx, "other") |> file(launch)
      {:ok, _} = Sections.set_collapsed(launch, true)

      {:ok, view, _html} = live(ctx.conn, ~p"/channels/#{here.id}")

      assert has_element?(view, "#sidebar-row-#{here.id}")
      refute has_element?(view, "#sidebar-row-#{here.id}.hidden")
      assert has_element?(view, "#sidebar-row-#{other.id}.hidden")
    end

    test "a row is a link with its actions beside it, not inside", ctx do
      {:ok, view, _html} = page(ctx.conn)
      id = ctx.channel.id

      assert has_element?(view, "#sidebar-row-#{id} > a#sidebar-channel-#{id}")
      refute has_element?(view, "#sidebar-channel-#{id} button")

      assert has_element?(
               view,
               "#sidebar-archive-#{id}[phx-click=archive_channel][phx-value-id='#{id}'][tabindex='-1']"
             )

      assert has_element?(
               view,
               "#sidebar-row-menu-#{id}[data-menu=channel][aria-haspopup=menu][aria-expanded=false]"
             )
    end

    test "a completed task marks the row ✓, in every tab", ctx do
      {:ok, view, _html} = page(ctx.conn)
      refute has_element?(view, "#sidebar-done-#{ctx.channel.id}")

      {:ok, _} = Tasks.update(ctx.task, %{status: "completed"})
      assert has_element?(view, "#sidebar-done-#{ctx.channel.id}")

      {:ok, _} = Channels.dismiss_archive_offer(Channels.get!(ctx.channel.id))
      refute has_element?(view, "#sidebar-done-#{ctx.channel.id}")
    end

    test "moving a channel re-renders it under its section", ctx do
      {:ok, payments} = Sections.create(ctx.repository.id, "Payments")
      {:ok, view, _html} = page(ctx.conn)

      render_hook(view, "move_channel", %{"id" => ctx.channel.id, "section_id" => payments.id})
      assert has_element?(view, "#sidebar-section-#{payments.id} #sidebar-row-#{ctx.channel.id}")

      render_hook(view, "move_channel", %{"id" => ctx.channel.id, "section_id" => ""})

      assert has_element?(
               view,
               "#sidebar-top-#{ctx.repository.id} #sidebar-row-#{ctx.channel.id}"
             )
    end

    test "archiving from the sidebar while viewing another channel keeps the page", ctx do
      other = channel(ctx, "other")
      {:ok, view, _html} = live(ctx.conn, ~p"/channels/#{ctx.channel.id}")

      view |> element("#sidebar-archive-#{other.id}") |> render_click()

      assert_push_event(view, "canopy:channel_archived", %{id: id, name: "other"})
      assert id == other.id
      refute has_element?(view, "#sidebar-row-#{other.id}")
      assert has_element?(view, "#composer-form")
      assert Channels.get!(other.id).status == "archived"
    end
  end

  describe "the Task done bar" do
    test "shows once the task is completed; Keep open hides it here and in another tab", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/channels/#{ctx.channel.id}")
      {:ok, second, _html} = live(ctx.conn, ~p"/channels/#{ctx.channel.id}")
      refute has_element?(view, "#done-bar")

      {:ok, _} = Tasks.update(ctx.task, %{status: "completed"}, agent_id: ctx.agent.id)

      assert has_element?(view, "#done-bar", "Task done.")
      assert has_element?(view, "#done-bar", "@#{ctx.agent.name}")
      assert has_element?(view, "#done-bar", ctx.task.title)
      assert has_element?(view, "#done-bar-archive[phx-value-id='#{ctx.channel.id}']")
      assert has_element?(second, "#done-bar")

      view |> element("#done-bar-keep") |> render_click()
      refute has_element?(view, "#done-bar")
      refute has_element?(second, "#done-bar")

      {:ok, again, _html} = live(ctx.conn, ~p"/channels/#{ctx.channel.id}")
      refute has_element?(again, "#done-bar")
    end

    test "a task you completed yourself credits you, not the owner", ctx do
      {:ok, _} = Tasks.update(ctx.task, %{status: "completed"})
      {:ok, view, _html} = live(ctx.conn, ~p"/channels/#{ctx.channel.id}")

      assert has_element?(view, "#done-bar", "You marked “#{ctx.task.title}” complete")
      refute has_element?(view, "#done-bar", "@#{ctx.agent.name}")
    end

    test "Archive channel archives it and the bar goes", ctx do
      {:ok, _} = Tasks.update(ctx.task, %{status: "completed"})
      {:ok, view, _html} = live(ctx.conn, ~p"/channels/#{ctx.channel.id}")
      assert has_element?(view, "#done-bar")

      view |> element("#done-bar-archive") |> render_click()

      assert_push_event(view, "canopy:channel_archived", %{id: _})
      refute has_element?(view, "#done-bar")
      assert has_element?(view, "#archived-bar")
    end

    test "Reopen after an archive keeps a done channel open for good", ctx do
      {:ok, _} = Tasks.update(ctx.task, %{status: "completed"})
      {:ok, _} = Channels.archive(Channels.get!(ctx.channel.id))
      {:ok, view, _html} = live(ctx.conn, ~p"/channels/#{ctx.channel.id}")

      view |> element("#archived-bar button", "Reopen") |> render_click()

      refute has_element?(view, "#archived-bar")
      refute has_element?(view, "#done-bar")
      assert Channels.get!(ctx.channel.id).archive_offer_dismissed_at
    end
  end

  describe "the command palette" do
    test "knows the open channel's section and its project's sections", ctx do
      {:ok, payments} = Sections.create(ctx.repository.id, "Payments")
      file(ctx.channel, payments)

      {:ok, view, _html} = live(ctx.conn, ~p"/channels/#{ctx.channel.id}")

      [items] = view |> element("#cmdk") |> render() |> attribute("data-items")
      [context] = view |> element("#cmdk") |> render() |> attribute("data-context")

      assert %{"section" => section_id} =
               items |> Jason.decode!() |> Enum.find(&(&1["id"] == ctx.channel.id))

      assert section_id == payments.id

      assert %{"sections" => [%{"id" => id, "name" => "Payments"}]} = Jason.decode!(context)
      assert id == payments.id
    end
  end

  defp attribute(html, name) do
    html |> LazyHTML.from_fragment() |> LazyHTML.attribute(name)
  end
end
