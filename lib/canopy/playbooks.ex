defmodule Canopy.Playbooks do
  @moduledoc """
  The playbook library: named, reusable processes a coordinator agent loads
  when asked and follows step by step (`Canopy.Playbooks.Runs` tracks each
  run). Playbooks are global to Canopy and live only in its database; a run
  happens in a channel and so works in that channel's repository.

  Enabled playbooks are listed in every agent's system prompt (`for_prompt/0`)
  and instruct every agent, so the user approves them: an agent may only save
  a disabled draft (`save_draft/2`) that the user reviews and enables.
  """

  import Ecto.Query, warn: false

  alias Canopy.Playbooks.{Definition, Playbook, Run}
  alias Canopy.Repo

  @topic "playbooks"
  @prompt_entries 20
  @prompt_chars 2_000

  @seed_path Application.app_dir(:canopy, "priv/playbooks/bug-fix.md")
  @external_resource @seed_path
  @bug_fix File.read!(@seed_path)

  # -- Reading ------------------------------------------------------------------

  @doc "Every playbook, by name; `enabled: true` keeps the enabled ones."
  def list(opts \\ []) do
    query = from p in Playbook, order_by: [asc: p.name], preload: [:created_by]

    query =
      if Keyword.get(opts, :enabled), do: where(query, [p], p.enabled == true), else: query

    Repo.all(query)
  end

  def get(id), do: Repo.get(Playbook, id)
  def get!(id), do: Repo.get!(Playbook, id)

  @doc "A playbook by name; a leading `@` or surrounding space is ignored."
  def get_by_name(name) when is_binary(name) do
    Repo.get_by(Playbook, name: name |> String.trim() |> String.downcase())
  end

  @doc "The parsed definition of a playbook (or of a run's snapshot)."
  def definition(%Playbook{body: body}), do: Definition.parse(body)
  def definition(%Run{definition: body}), do: Definition.parse(body)

  @doc "Runs in progress per playbook id, for the library page."
  def active_run_counts do
    Repo.all(
      from r in Run,
        where: r.status in ^Run.live_statuses() and not is_nil(r.playbook_id),
        group_by: r.playbook_id,
        select: {r.playbook_id, count(r.id)}
    )
    |> Map.new()
  end

  @doc "When each playbook last started a run, per playbook id, for the library page."
  def last_run_at do
    Repo.all(
      from r in Run,
        where: not is_nil(r.playbook_id),
        group_by: r.playbook_id,
        select: {r.playbook_id, max(r.inserted_at)}
    )
    |> Map.new()
  end

  # -- Writing ------------------------------------------------------------------

  @doc "Creates a playbook from its text (`:body`), plus `:enabled`, `:source`."
  def create(attrs) do
    %Playbook{} |> Playbook.changeset(attrs) |> Repo.insert() |> notify()
  end

  @doc """
  The user's edit. Every write checks the version the caller read (an
  optimistic lock), so an edit made from a page that went stale fails with
  `{:error, changeset}` saying so. Editing an agent's draft claims it for the
  user: the agent can no longer replace it.
  """
  def update(%Playbook{} = playbook, attrs) do
    changeset = Playbook.changeset(playbook, attrs)

    changeset =
      if playbook.source == "agent" and Ecto.Changeset.changed?(changeset, :body),
        do: Ecto.Changeset.put_change(changeset, :source, "user"),
        else: changeset

    changeset |> locked_update() |> notify()
  end

  @doc """
  Enables or disables a playbook. Enabling approves the text the user saw:
  `seen_version` is the `lock_version` on the page, and a playbook changed
  since (an agent replaced its draft) is not enabled
  (`{:error, :stale}`).
  """
  def set_enabled(%Playbook{} = playbook, enabled?, seen_version \\ nil)
      when is_boolean(enabled?) do
    playbook = if seen_version, do: %{playbook | lock_version: seen_version}, else: playbook

    case playbook |> Playbook.changeset(%{enabled: enabled?}) |> locked_update() do
      {:ok, playbook} ->
        notify({:ok, playbook})

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :lock_version),
          do: {:error, :stale},
          else: {:error, changeset}
    end
  end

  defp locked_update(changeset) do
    changeset
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update(
      stale_error_field: :lock_version,
      stale_error_message: "changed since you opened it; reload and try again"
    )
  end

  @doc """
  Deletes a playbook. Refused while a run of it is in progress (disable it
  instead), checked in the same transaction as the delete, so a run cannot
  start in between; finished runs keep their own copy of the text.
  """
  def delete(%Playbook{} = playbook) do
    fn ->
      live? =
        Repo.exists?(
          from r in Run, where: r.playbook_id == ^playbook.id and r.status in ^Run.live_statuses()
        )

      if live? do
        Repo.rollback(
          "#{playbook.name} has a run in progress; disable it instead, or cancel the run"
        )
      else
        case Repo.delete(playbook, stale_error_field: :lock_version) do
          {:ok, deleted} -> deleted
          {:error, _} -> Repo.rollback("#{playbook.name} could not be deleted")
        end
      end
    end
    |> Repo.transaction(mode: :immediate)
    |> notify()
  end

  @doc """
  A disabled copy under a free name (`<name>-copy`, `<name>-copy-2`, …), so
  the copy instructs no agent until the user has edited and enabled it.
  """
  def duplicate(%Playbook{} = playbook) do
    name = copy_name(playbook.name)
    body = String.replace(playbook.body, ~r/^name:.*$/m, "name: " <> name, global: false)
    create(%{body: body, enabled: false, source: "user"})
  end

  @doc """
  A free name for a copy of `name`: `<name>-copy`, `<name>-copy-2`, …, with
  `name` shortened so the whole stays within 40 characters.
  """
  def copy_name(name) do
    taken = MapSet.new(Repo.all(from p in Playbook, select: p.name))

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> "-copy"
      n -> "-copy-#{n}"
    end)
    |> Stream.map(fn suffix ->
      (name |> String.slice(0, 40 - String.length(suffix)) |> String.trim_trailing("-")) <>
        suffix
    end)
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  @doc """
  An agent's playbook: saved as a disabled draft the user reviews and
  enables. The agent may replace a draft of the same name only while it is
  still its own: disabled, saved by this agent, and not edited by the user
  since (an edit makes it the user's). Read and written in one immediate
  transaction, so a draft the user enables or edits meanwhile is never
  overwritten.
  """
  def save_draft(agent, body) do
    with {:ok, definition} <- parse_for_draft(body) do
      fn ->
        case Repo.get_by(Playbook, name: definition.name) do
          nil ->
            insert_or_rollback(%{
              body: body,
              enabled: false,
              source: "agent",
              created_by_agent_id: agent.id
            })

          %Playbook{source: "agent", enabled: false, created_by_agent_id: id} = draft
          when id == agent.id ->
            case draft |> Playbook.changeset(%{body: body}) |> locked_update() do
              {:ok, playbook} -> playbook
              {:error, changeset} -> Repo.rollback(changeset)
            end

          %Playbook{source: "agent", enabled: false} ->
            Repo.rollback(
              "#{definition.name} is another agent's draft; pick another name for yours"
            )

          %Playbook{} ->
            Repo.rollback(
              "a playbook named #{definition.name} already exists; pick another name, or ask the user to edit it"
            )
        end
      end
      |> Repo.transaction(mode: :immediate)
      |> notify()
    end
  end

  defp insert_or_rollback(attrs) do
    case %Playbook{} |> Playbook.changeset(attrs) |> Repo.insert() do
      {:ok, playbook} -> playbook
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp parse_for_draft(body) do
    case Definition.parse(body) do
      {:ok, definition} -> {:ok, definition}
      {:error, reasons} -> {:error, "the playbook does not parse: " <> Enum.join(reasons, "; ")}
    end
  end

  @doc "A changeset for the editor; errors on `body` say why the text does not parse."
  def change(%Playbook{} = playbook, attrs \\ %{}), do: Playbook.changeset(playbook, attrs)

  # -- Prompt -------------------------------------------------------------------

  @doc """
  The `{{playbooks}}` preamble variable: the enabled playbooks, one line
  each, capped at #{@prompt_entries} entries and #{@prompt_chars} characters.
  It changes only when the library does, so the system text stays a stable,
  cacheable prefix between prompts.
  """
  def for_prompt do
    case list(enabled: true) do
      [] ->
        "No playbooks are defined yet."

      playbooks ->
        {lines, _} =
          playbooks
          |> Enum.take(@prompt_entries)
          |> Enum.map(&"- #{&1.name} — #{&1.description}")
          |> Enum.reduce({[], 0}, fn line, {acc, size} ->
            if size + String.length(line) + 1 > @prompt_chars,
              do: {acc, @prompt_chars + 1},
              else: {acc ++ [line], size + String.length(line) + 1}
          end)

        more =
          if length(lines) < length(playbooks),
            do: "\n(#{length(playbooks) - length(lines)} more; canopy_playbooks_list shows all)",
            else: ""

        "Playbooks you can run with canopy_playbook_start:\n" <> Enum.join(lines, "\n") <> more
    end
  end

  # -- Seeds --------------------------------------------------------------------

  @doc "The text of the seeded `bug-fix` playbook."
  def bug_fix_text, do: @bug_fix

  @doc "Seeds the starter playbooks that are missing by name; existing ones are left alone."
  def seed do
    for text <- [@bug_fix] do
      {:ok, definition} = Definition.parse(text)

      case get_by_name(definition.name) do
        nil ->
          {:ok, playbook} = create(%{body: text, source: "seed"})
          {:created, playbook.name}

        playbook ->
          {:exists, playbook.name}
      end
    end
  end

  # -- PubSub -------------------------------------------------------------------

  @doc "Subscribe to `{:playbooks, :changed}`, sent when the library changes."
  def subscribe, do: Phoenix.PubSub.subscribe(Canopy.PubSub, @topic)

  @doc "Tells subscribers the library changed, after a transaction that wrote playbooks directly (an import)."
  def broadcast_changed,
    do: Phoenix.PubSub.broadcast(Canopy.PubSub, @topic, {:playbooks, :changed})

  defp notify({:ok, _} = result) do
    Phoenix.PubSub.broadcast(Canopy.PubSub, @topic, {:playbooks, :changed})
    result
  end

  defp notify(other), do: other
end
