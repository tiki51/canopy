defmodule Canopy.PlaybookHelpers do
  @moduledoc """
  Helpers for playbook and watch tests: playbook texts, and an OpenCode
  double that answers whatever a woken coordinator's channel server asks
  (sessions, MCP status) and reports each prompt to the test process as
  `{:prompted, session_id, body}`. Call it from a test that runs with
  `setup :set_mox_global`; `stop_channels/0` in `on_exit` stops the channel
  servers a wake started.
  """

  import Mox

  alias Canopy.OpenCode.ClientMock, as: OC

  @doc "A playbook's text: `steps` as `{id, title, owner}` or `{id, title, owner, extra_yaml}`."
  def playbook_text(name, steps, extra \\ "") do
    steps_yaml =
      Enum.map_join(steps, "\n", fn
        {id, title, owner} ->
          "  - id: #{id}\n    title: #{title}\n    owner: #{owner}"

        {id, title, owner, more} ->
          "  - id: #{id}\n    title: #{title}\n    owner: #{owner}\n" <>
            (more |> String.split("\n", trim: true) |> Enum.map_join("\n", &("    " <> &1)))
      end)

    sections =
      Enum.map_join(steps, "\n\n", fn step -> "## #{elem(step, 0)}\n\nDo #{elem(step, 1)}." end)

    "---\nname: #{name}\ndescription: The #{name} process.\n#{extra}steps:\n#{steps_yaml}\n---\n\nGround rules for #{name}.\n\n#{sections}\n"
  end

  @doc "Creates (enabled) and returns a playbook."
  def playbook_fixture(name, steps, extra \\ "") do
    {:ok, playbook} = Canopy.Playbooks.create(%{body: playbook_text(name, steps, extra)})
    playbook
  end

  @doc "Stubs the OpenCode client so channel servers can wake agents."
  def stub_engine(test_pid, repository) do
    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)

    stub(OC, :create_session, fn _dir, _attrs, _opts ->
      {:ok, %{"id" => "ses_" <> Canopy.Fixtures.unique_suffix()}}
    end)

    stub(OC, :prompt_async, fn _dir, sid, body, _opts ->
      send(test_pid, {:prompted, sid, body})
      {:ok, ""}
    end)

    stub(OC, :dispose_instance, fn _dir, _opts -> {:ok, true} end)

    stub(OC, :add_mcp, fn _dir, _name, _config, _opts ->
      {:ok, %{"canopy" => %{"status" => "connected"}}}
    end)

    Canopy.MCP.mark_registered(repository.id)
  end

  @doc "The text part of a prompt body."
  def prompt_text(%{parts: [%{text: text} | _]}), do: text

  @doc "Stops every running channel server."
  def stop_channels do
    Enum.each(Canopy.Runtime.Supervisor.running_channel_ids(), &Canopy.Runtime.stop_channel/1)
  end
end
