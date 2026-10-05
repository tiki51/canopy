defmodule CanopyWeb.PlaybookAsk do
  @moduledoc """
  Asking an agent about a playbook from the Playbooks pages: to draft a new
  one from a description, or to fix one the builder cannot read. The
  request is the user's message in the direct message with the agent,
  wherever it works now (a new one starts in the first repository, as
  `CanopyWeb.DmController` opens one), which wakes it.
  """

  alias Canopy.{Channels, Repositories, Runtime}
  alias Canopy.Agents.Agent

  @doc "Posts `text` to a DM with `agent`. `{:ok, channel}` or `{:error, reason}`."
  def ask(%Agent{} = agent, text) do
    with {:ok, channel} <- dm(agent),
         {:ok, _message} <- Runtime.post_user_message(channel.id, text) do
      {:ok, channel}
    else
      {:repository, nil} -> {:error, "Add a repository before messaging an agent."}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, _} -> {:error, "Could not message @#{agent.name}."}
    end
  end

  # the DM with just this agent wherever it works now (asking for it in
  # another repository would move it), else a new one in the first repository
  defp dm(agent) do
    case Enum.find(Channels.list_dms(), &match?([%{id: id}] when id == agent.id, &1.agents)) do
      %{} = channel ->
        {:ok, channel}

      nil ->
        case List.first(Repositories.list()) do
          %{} = repository -> Channels.ensure_dm(repository.id, agent)
          nil -> {:repository, nil}
        end
    end
  end

  @doc "The request to draft a playbook from the user's description."
  def draft_request(description) do
    """
    Please draft a Canopy playbook for this:

    #{String.trim(description)}

    Read the bug-fix playbook with `canopy_playbook_get` for the format, then save yours with \
    `canopy_playbook_save`. It is saved as a disabled draft that I review in the playbook builder \
    and enable myself. Keep steps short and concrete, give each a "Done when:" line, and reply \
    here with its name when it's saved.
    """
  end

  @doc "The request to fix a playbook whose text does not parse."
  def fix_request(playbook_name, reasons) do
    """
    The playbook `#{playbook_name}` has problems the playbook builder can't show:

    #{Enum.map_join(reasons, "\n", &("- " <> &1))}

    Please read it with `canopy_playbook_get` and fix these. If it's your draft, save it again \
    with `canopy_playbook_save`; otherwise reply here with the whole fixed text in a code block, \
    and I'll paste it in.
    """
  end
end
