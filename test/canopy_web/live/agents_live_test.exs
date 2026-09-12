defmodule CanopyWeb.AgentsLiveTest do
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Canopy.Agents
  alias Canopy.Fixtures
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global
  setup :verify_on_exit!

  @providers %{
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
          "big-pickle" => %{"cost" => %{"input" => 0, "output" => 0}}
        }
      },
      %{
        "id" => "openai",
        "name" => "OpenAI",
        "models" => %{"gpt-5.4" => %{"cost" => %{"input" => 0, "output" => 0}}}
      }
    ],
    "default" => %{"opencode" => "gpt-5-nano"}
  }

  setup do
    stub(OC, :providers, fn _opts -> {:ok, @providers} end)
    :ok
  end

  describe "the list" do
    test "renders the empty state with a link to the new-agent page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents")

      assert has_element?(view, "#agents-empty")
      assert has_element?(view, "#new-agent[href='/agents/new']")
      refute has_element?(view, "#agent-form")
    end

    test "lists active agents as links to their pages, and deactivated ones behind a toggle", %{
      conn: conn
    } do
      agent = Fixtures.agent_fixture(%{name: "listed", role: "Lists things"})
      sleepy = Fixtures.agent_fixture(%{name: "sleepy", active: false})

      {:ok, view, _html} = live(conn, ~p"/agents")

      assert has_element?(
               view,
               "#active-agents #agent-#{agent.id} a[href='/agents/#{agent.id}']",
               "@listed"
             )

      assert has_element?(view, "#agent-#{agent.id}", "Lists things")
      refute has_element?(view, "#active-agents #agent-#{sleepy.id}")

      assert has_element?(view, "#toggle-inactive", "1 deactivated")
      view |> element("#toggle-inactive") |> render_click()
      assert has_element?(view, "#inactive-agents #agent-#{sleepy.id}", "@sleepy")

      view |> element("#reactivate-agent-#{sleepy.id}") |> render_click()
      assert Agents.get!(sleepy.id).active
      assert has_element?(view, "#active-agents #agent-#{sleepy.id}")
      assert has_element?(view, "#sidebar-agent-#{sleepy.id}")
    end
  end

  describe "the agent page" do
    test "shows identity, channels, schedules, and the actions; sidebar row is marked", %{
      conn: conn
    } do
      %{channel: channel, agent: agent, repository: repository} = Fixtures.scenario()
      other = Fixtures.agent_fixture()
      {:ok, dm} = Canopy.Channels.ensure_dm(repository.id, agent)

      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}")
      assert page_title(view) =~ "@" <> agent.name
      assert has_element?(view, "#agent-page[data-agent-id='#{agent.id}']")
      assert has_element?(view, "#agent-about", agent.opencode_agent)
      assert has_element?(view, "#agent-about", "OpenCode default")
      assert has_element?(view, "#agent-system-prompt", "You are #{agent.name}.")

      assert has_element?(
               view,
               "#agent-channel-#{channel.id} a[href='/channels/#{channel.id}']",
               channel.name
             )

      assert has_element?(view, "#agent-channel-#{channel.id}", "owner")
      assert has_element?(view, "#agent-channel-#{dm.id}", "@#{agent.name}")
      assert has_element?(view, "#agent-schedules", "Nothing scheduled for this agent.")

      assert has_element?(view, "#message-agent-#{agent.id}[href='/dm/#{agent.id}']", "Message")

      assert has_element?(
               view,
               "#edit-agent-#{agent.id}[href='/agents/#{agent.id}/edit']",
               "Edit"
             )

      assert has_element?(view, "#back-to-agents[href='/agents']")
      assert has_element?(view, "#sidebar-agent-#{agent.id}[data-active]")
      refute has_element?(view, "#sidebar-agent-#{other.id}[data-active]")

      # an unknown id goes back to the list
      assert {:error, {:live_redirect, %{to: "/agents"}}} = live(conn, ~p"/agents/agt_nope")
    end

    test "the memory panel shows, edits, and follows the agent's own writes", %{conn: conn} do
      agent = Fixtures.agent_fixture(%{name: "remember"})
      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}")
      assert has_element?(view, "#agent-memory-empty")

      view |> element("#edit-memory") |> render_click()

      view
      |> form("#memory-form", memory: "## 2026-09-10\n- **loves** small PRs")
      |> render_submit()

      assert has_element?(view, "#agent-memory strong", "loves")
      assert Canopy.Memory.get(agent.id) =~ "small PRs"
      refute has_element?(view, "#memory-form")

      # the agent writes through the context (as the tool does): the page follows
      {:ok, _} = Canopy.Memory.append(agent.id, "- payments.py is the worker")
      assert has_element?(view, "#agent-memory", "payments.py is the worker")
      assert has_element?(view, "#agent-memory-panel", "updated")
    end

    test "the page shows the model's price and the agent's spend", %{conn: conn} do
      %{channel: channel, agent: agent} = Fixtures.scenario()

      {:ok, agent} =
        Canopy.Agents.update(agent, %{model_provider: "opencode", model_id: "claude-haiku-4-5"})

      {:ok, _} =
        Canopy.Timeline.record(%{
          channel_id: channel.id,
          agent_id: agent.id,
          event_type: "agent_turn_completed",
          payload: %{"outcome" => "ok", "cost" => 0.75, "tools" => 1, "duration_ms" => 10}
        })

      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}")
      render_async(view)
      assert has_element?(view, "#agent-model-price", "$1.00 in / $5.00 out per million tokens")
      assert has_element?(view, "#agent-model-price", "cached input $0.1")
      assert has_element?(view, "#agent-spend", "$0.75 today")

      # no override: OpenCode's default and its price
      plain = Fixtures.agent_fixture(%{name: "plain"})
      {:ok, view, _html} = live(conn, ~p"/agents/#{plain.id}")
      render_async(view)
      assert has_element?(view, "#agent-model-price", "(opencode/gpt-5-nano)")
      assert has_element?(view, "#agent-model-price", "$0.05 in / $0.4 out")
    end

    test "deactivate and reactivate from the page", %{conn: conn} do
      agent = Fixtures.agent_fixture(%{name: "sleepy"})
      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}")

      view |> element("#deactivate-agent-#{agent.id}") |> render_click()
      refute Agents.get!(agent.id).active
      assert has_element?(view, "#agent-about", "deactivated")
      refute has_element?(view, "#message-agent-#{agent.id}")
      refute has_element?(view, "#sidebar-agent-#{agent.id}")

      view |> element("#reactivate-agent-#{agent.id}") |> render_click()
      assert Agents.get!(agent.id).active
      assert has_element?(view, "#agent-about", "active")
      assert has_element?(view, "#sidebar-agent-#{agent.id}")
    end

    test "schedules are listed across channels, cancellable, and live", %{conn: conn} do
      %{channel: channel, agent: agent, repository: repository} = Fixtures.scenario()
      other = Fixtures.channel_fixture(%{repository_id: repository.id, owner_agent_id: agent.id})

      {:ok, a} =
        Canopy.Schedules.create(%{
          channel_id: channel.id,
          agent_id: agent.id,
          instruction: "Here.",
          when: "1h"
        })

      {:ok, b} =
        Canopy.Schedules.create(%{
          channel_id: other.id,
          agent_id: agent.id,
          instruction: "There.",
          when: "0 9 * * 1-5"
        })

      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}")
      assert has_element?(view, "#agent-schedules-#{a.id}", "Here.")

      assert has_element?(
               view,
               "#agent-schedules-#{a.id} a[href='/channels/#{channel.id}']",
               "##{channel.name}"
             )

      assert has_element?(view, "#agent-schedules-#{b.id}", "every weekday at 09:00")
      assert has_element?(view, "#schedules-#{agent.id}", "2")

      view |> element("#cancel-schedule-#{a.id}") |> render_click()
      refute has_element?(view, "#agent-schedules-#{a.id}")
      assert has_element?(view, "#schedules-#{agent.id}", "1")

      # a change made elsewhere shows up without a reload
      {:ok, _} = Canopy.Schedules.cancel(Canopy.Schedules.get!(b.id), "elsewhere")
      refute has_element?(view, "#agent-schedules-#{b.id}")
      assert has_element?(view, "#agent-schedules", "Nothing scheduled for this agent.")
      refute has_element?(view, "#schedules-#{agent.id}")
    end
  end

  describe "creating" do
    test "creates an agent and lands on its page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents/new")
      assert has_element?(view, "#cancel-edit[href='/agents']")

      view
      |> form("#agent-form",
        agent: %{
          name: "Backend",
          display_name: "Backend engineer",
          role: "Owns the Phoenix backend",
          system_prompt: "You are the backend engineer.",
          opencode_agent: "build"
        }
      )
      |> render_submit()

      assert %{display_name: "Backend engineer", role: "Owns the Phoenix backend", model_id: nil} =
               agent = Agents.get_by_name("backend")

      assert_redirect(view, ~p"/agents/#{agent.id}")
    end

    test "shows validation errors inline", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents/new")

      view
      |> form("#agent-form", agent: %{name: "has spaces"})
      |> render_submit()

      assert has_element?(view, "#agent-form", "must be lowercase letters")
      assert Agents.list() == []
    end

    test "fills the OpenCode agent datalist from the server when a repository exists", %{
      conn: conn
    } do
      repository = Fixtures.repository_fixture()

      stub(OC, :agents, fn dir, _opts ->
        assert dir == repository.path

        {:ok,
         [
           %{"name" => "plan", "mode" => "primary"},
           %{"name" => "build", "mode" => "primary"},
           %{"name" => "custom-reviewer", "mode" => "primary"},
           %{"name" => "title", "mode" => "primary", "hidden" => true},
           %{"name" => "explore", "mode" => "subagent"},
           %{"mode" => "no-name"}
         ]}
      end)

      {:ok, view, _html} = live(conn, ~p"/agents/new")
      render_async(view)

      assert has_element?(view, "#opencode-agents option[value='build']")
      assert has_element?(view, "#opencode-agents option[value='plan']")
      assert has_element?(view, "#opencode-agents option[value='custom-reviewer']")
      refute has_element?(view, "#opencode-agents option[value='title']")
      refute has_element?(view, "#opencode-agents option[value='explore']")

      assert has_element?(view, "#agent-form select[name='agent[opencode_agent]']")
    end

    test "offers the built-in agents when the OpenCode server is unreachable", %{conn: conn} do
      Fixtures.repository_fixture()
      stub(OC, :agents, fn _dir, _opts -> {:error, {:transport, %{reason: :econnrefused}}} end)

      {:ok, view, _html} = live(conn, ~p"/agents/new")
      render_async(view)

      assert has_element?(view, "#opencode-agents option[value='build']")
      assert has_element?(view, "#opencode-agents option[value='plan']")

      assert has_element?(view, "#agent-form select[name='agent[opencode_agent]']")
    end

    test "offers the built-in agents with no repository registered", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents/new")
      assert has_element?(view, "#opencode-agents option[value='build']")
      assert has_element?(view, "#opencode-agents option[value='plan']")
    end
  end

  describe "groups" do
    test "the sidebar and the list show group headings, and the form saves a group", %{conn: conn} do
      eng = Fixtures.agent_fixture(%{name: "builder", group: "Engineering"})
      loose = Fixtures.agent_fixture(%{name: "loose"})

      {:ok, view, _html} = live(conn, ~p"/agents")
      assert has_element?(view, "#sidebar-group-engineering", "Engineering")
      assert has_element?(view, "#agents-group-engineering", "Engineering")
      assert has_element?(view, "#sidebar-agent-#{eng.id}")
      assert has_element?(view, "#sidebar-agent-#{loose.id}")

      {:ok, view, _html} = live(conn, ~p"/agents/#{loose.id}/edit")
      assert has_element?(view, "#agent-groups option[value='Engineering']")
      view |> form("#agent-form", agent: %{group: "Product"}) |> render_submit()
      assert Canopy.Agents.get!(loose.id).group == "Product"
    end
  end

  describe "editing" do
    test "edits an existing agent and returns to its page", %{conn: conn} do
      agent = Fixtures.agent_fixture(%{name: "reviewer", role: "Reviews"})
      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}/edit")
      render_async(view)

      assert page_title(view) =~ "@reviewer"
      assert has_element?(view, "#agent-form input[name='agent[name]'][value='reviewer']")
      assert has_element?(view, "#cancel-edit[href='/agents/#{agent.id}']")

      # picking a provider enables the model select, as in the browser
      view |> form("#agent-form", agent: %{model_provider: "opencode"}) |> render_change()

      view
      |> form("#agent-form",
        agent: %{
          role: "Reviews every diff",
          model_provider: "opencode",
          model_id: "gpt-5-nano"
        }
      )
      |> render_submit()

      assert %{role: "Reviews every diff", model_provider: "opencode"} = Agents.get!(agent.id)
      assert_redirect(view, ~p"/agents/#{agent.id}")

      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}")
      assert has_element?(view, "#agent-about", "Reviews every diff")
      assert has_element?(view, "#agent-about", "opencode/gpt-5-nano")
    end
  end

  describe "model override" do
    test "offers providers and models from OpenCode and validates the pair", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents/new")
      render_async(view)

      assert has_element?(
               view,
               "#agent-form select[name='agent[model_provider]'] option[value='opencode']"
             )

      assert has_element?(
               view,
               "#agent-form select[name='agent[model_provider]'] option[value='openai']"
             )

      # picking a provider fills the model list
      html =
        view
        |> form("#agent-form",
          agent: %{name: "picky", display_name: "Picky", model_provider: "opencode"}
        )
        |> render_change()

      assert html =~ "claude-haiku-4-5"
      assert html =~ "gpt-5-nano"
      refute html =~ "gpt-5.4</option>"

      # saving with a provider but no model is refused
      html =
        view
        |> form("#agent-form",
          agent: %{name: "picky", display_name: "Picky", model_provider: "opencode", model_id: ""}
        )
        |> render_submit()

      assert html =~ "pick a model from opencode"
      assert Agents.get_by_name("picky") == nil

      # a valid pair saves
      view
      |> form("#agent-form",
        agent: %{
          name: "picky",
          display_name: "Picky",
          model_provider: "opencode",
          model_id: "gpt-5-nano"
        }
      )
      |> render_submit()

      assert %{model_provider: "opencode", model_id: "gpt-5-nano"} = Agents.get_by_name("picky")
    end

    test "the form shows the price of the chosen model, and the default's when none is chosen", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/agents/new")
      render_async(view)
      assert has_element?(view, "#model-price", "opencode/gpt-5-nano")
      assert has_element?(view, "#model-price", "(OpenCode's default)")
      assert has_element?(view, "#model-price", "$0.05 in / $0.4 out")

      view |> form("#agent-form", agent: %{model_provider: "opencode"}) |> render_change()

      view
      |> form("#agent-form", agent: %{model_provider: "opencode", model_id: "claude-haiku-4-5"})
      |> render_change()

      assert has_element?(view, "#model-price", "$1.00 in / $5.00 out per million tokens")

      view |> form("#agent-form", agent: %{model_provider: "openai"}) |> render_change()

      view
      |> form("#agent-form", agent: %{model_provider: "openai", model_id: "gpt-5.4"})
      |> render_change()

      # a provider whose every model is $0 is unpriced, not free
      assert has_element?(view, "#model-price", "no per-token price reported")
      refute has_element?(view, "#model-price", "free")

      # a $0 model among priced ones really is free
      view |> form("#agent-form", agent: %{model_provider: "opencode"}) |> render_change()

      view
      |> form("#agent-form", agent: %{model_provider: "opencode", model_id: "big-pickle"})
      |> render_change()

      assert has_element?(view, "#model-price", "big-pickle — free")
    end

    test "an existing override for an unconfigured provider is shown and flagged", %{conn: conn} do
      agent =
        Fixtures.agent_fixture(%{
          name: "legacy",
          model_provider: "anthropic",
          model_id: "claude-sonnet-4-5"
        })

      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}/edit")
      render_async(view)
      assert render(view) =~ "anthropic (not configured)"

      html =
        view
        |> form("#agent-form",
          agent: %{model_provider: "anthropic", model_id: "claude-sonnet-4-5"}
        )
        |> render_submit()

      assert html =~ "is not configured in OpenCode"
      assert Agents.get!(agent.id).model_provider == "anthropic"
    end

    test "falls back to text inputs when the provider list is unavailable", %{conn: conn} do
      stub(OC, :providers, fn _opts -> {:error, {:transport, %{reason: :econnrefused}}} end)
      {:ok, view, _html} = live(conn, ~p"/agents/new")
      render_async(view)

      assert has_element?(view, "#agent-form input[name='agent[model_provider]']")
      assert has_element?(view, "#agent-form input[name='agent[model_id]']")
    end
  end
end
