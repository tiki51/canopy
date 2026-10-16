defmodule Canopy.Channels.Sections do
  @moduledoc """
  Sidebar sections: named groups of a project's channels, in the user's
  order. A channel is in at most one section; one in none sits at the top of
  its project. Sections are layout only: they record nothing on any timeline,
  and deleting one archives nothing.

  Positions are 0-based and contiguous per repository. Every write that
  changes them runs in one `IMMEDIATE` transaction, so concurrent moves
  serialise. Every write broadcasts `{:channels, :changed}`, apart from
  `find_or_create/2`, whose callers broadcast.

  Agents reach this module only through a channel's creation (`section:` on
  `Canopy.Channels.create/1`, `find_or_create/2`): they never rename, move,
  collapse or delete a section, nor move a channel.
  """

  import Ecto.Query, warn: false

  alias Canopy.Channels
  alias Canopy.Channels.{Channel, Section}
  alias Canopy.Repo

  @doc "A repository's sections, by position."
  def list(repository_id) do
    Repo.all(
      from s in Section,
        where: s.repository_id == ^repository_id,
        order_by: [asc: s.position, asc: s.inserted_at]
    )
  end

  @doc "Every repository's sections, by repository and position (for the sidebar)."
  def list_all do
    Repo.all(
      from s in Section, order_by: [asc: s.repository_id, asc: s.position, asc: s.inserted_at]
    )
  end

  def get(id) when is_binary(id), do: Repo.get(Section, id)
  def get(_), do: nil

  @doc "The section with this name (trimmed, any ASCII case) in a repository, or nil."
  def find_by_name(repository_id, name) when is_binary(name) do
    case Section.normalize_name(name) do
      nil -> nil
      name -> Repo.get_by(Section, repository_id: repository_id, name: name)
    end
  end

  def find_by_name(_repository_id, _name), do: nil

  @doc """
  Checks a section name without touching the database: `:ok`, or
  `{:error, message}` ("should be at most 40 character(s)"). Blank counts as
  valid here; callers treat it as no section.
  """
  def validate_name(name) when is_binary(name) do
    case Section.normalize_name(name) do
      nil ->
        :ok

      _ ->
        %Section{}
        |> Section.name_changeset(%{name: name})
        |> case do
          %{valid?: true} -> :ok
          changeset -> {:error, name_error(changeset)}
        end
    end
  end

  def validate_name(nil), do: :ok
  def validate_name(_), do: {:error, "must be a name"}

  @doc """
  The sidebar's "New section": inserted first (position 0), the others shift
  down one.
  """
  def create(repository_id, name) do
    changeset =
      %Section{}
      |> Section.changeset(%{repository_id: repository_id, name: name})
      |> check_repository()

    if changeset.valid? do
      transaction(fn ->
        shift(repository_id, 0, 1)

        case Repo.insert(Ecto.Changeset.put_change(changeset, :position, 0)) do
          {:ok, section} -> section
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
      |> notify()
    else
      {:error, changeset}
    end
  end

  @doc """
  The one resolver for a section named by an agent, a playbook run or a
  picker: the section with that name in any case (`created?: false`), else a
  new one appended last (`created?: true`). Runs in an `IMMEDIATE`
  transaction, joining the caller's when nested, so two callers asking for
  the same new name get one section. An invalid name is a changeset error on
  `:name`. Broadcasts nothing; `Canopy.Channels.create/1` does.
  """
  def find_or_create(repository_id, name) do
    changeset = Section.changeset(%Section{}, %{repository_id: repository_id, name: name})

    if changeset.valid? do
      transaction(fn ->
        case find_by_name(repository_id, name) do
          %Section{} = section ->
            section

          nil ->
            changeset
            |> Ecto.Changeset.put_change(:position, count(repository_id))
            |> Repo.insert()
            |> case do
              {:ok, section} -> %{section | created?: true}
              {:error, changeset} -> Repo.rollback(changeset)
            end
        end
      end)
    else
      {:error, changeset}
    end
  end

  def rename(%Section{} = section, name) do
    section
    |> Section.name_changeset(%{name: name})
    |> Repo.update()
    |> notify()
  end

  @doc """
  Moves a section to a final 0-based index (clamped) and renumbers the rest.
  Returns the repository's sections in their new order.
  """
  def move(%Section{} = section, index) when is_integer(index) do
    transaction(fn ->
      sections = list(section.repository_id)

      case Enum.find_index(sections, &(&1.id == section.id)) do
        nil ->
          Repo.rollback(:not_found)

        from ->
          {moved, rest} = List.pop_at(sections, from)
          index = index |> max(0) |> min(length(rest))
          sections = List.insert_at(rest, index, moved)
          renumber(sections)
          list(section.repository_id)
      end
    end)
    |> notify()
  end

  @doc """
  Deletes a section in one transaction: its channels (open or archived) go
  back to the top of the project, and the rest are renumbered. Archives
  nothing.
  """
  def delete(%Section{} = section) do
    transaction(fn ->
      Repo.update_all(from(c in Channel, where: c.section_id == ^section.id),
        set: [section_id: nil]
      )

      case Repo.delete(section) do
        {:ok, deleted} ->
          section.repository_id |> list() |> renumber()
          deleted

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> notify()
  end

  @doc "Sets a section's collapsed state: an explicit target, so two tabs can't toggle each other back."
  def set_collapsed(%Section{} = section, collapsed) when is_boolean(collapsed) do
    section
    |> Ecto.Changeset.change(collapsed: collapsed)
    |> Repo.update()
    |> notify()
  end

  @doc """
  Files a channel under a section of its own project, or at the top (nil).
  Archived channels may be moved; they keep the section when reopened.
  """
  def move_channel(%Channel{kind: "dm"}, _section), do: {:error, :dm}

  def move_channel(%Channel{repository_id: repo_id}, %Section{repository_id: other})
      when repo_id != other,
      do: {:error, :other_repository}

  # By id, not through a changeset: the caller's struct may be stale, and a
  # changeset would see no change.
  def move_channel(%Channel{id: id}, section) do
    case Repo.update_all(from(c in Channel, where: c.id == ^id),
           set: [section_id: section && section.id, updated_at: DateTime.utc_now()]
         ) do
      {1, _} ->
        Channels.notify_changed()
        {:ok, Channels.get!(id)}

      {0, _} ->
        {:error, :not_found}
    end
  end

  @doc """
  A project's sidebar, from a repository carrying `:channels` and `:sections`
  (`Canopy.Repositories.list_with_channels/0`): open channels with no section
  (`top`), the sections by position with their open channels, and the
  archived channels, each list A→Z. The current channel, if archived, stays in
  its place rather than in `archived`. A `section_id` that matches no loaded
  section counts as top. Empty sections are listed with `channels: []`.
  """
  def group(%{channels: channels} = repository, current_channel_id) do
    sections = Map.get(repository, :sections, [])
    known = MapSet.new(sections, & &1.id)

    {archived, shown} =
      Enum.split_with(channels, &(&1.status == "archived" and &1.id != current_channel_id))

    shown = Enum.sort_by(shown, & &1.name)

    by_section =
      Enum.group_by(shown, fn c ->
        if c.section_id in known, do: c.section_id, else: nil
      end)

    %{
      top: Map.get(by_section, nil, []),
      sections: Enum.map(sections, &%{section: &1, channels: Map.get(by_section, &1.id, [])}),
      archived: Enum.sort_by(archived, & &1.name)
    }
  end

  @doc "The first error on a section changeset's name, as a sentence: \"Name is already a section in this project\"."
  def error_message(%Ecto.Changeset{} = changeset) do
    case name_error(changeset) do
      nil -> "That section couldn't be saved."
      message -> "Name " <> message
    end
  end

  defp name_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Map.get(:name, [])
    |> List.first()
  end

  # SQLite reports a foreign key failure without a constraint name, which makes
  # Ecto raise, so the repository is checked up front.
  defp check_repository(%{valid?: true} = changeset) do
    id = Ecto.Changeset.get_field(changeset, :repository_id)

    if Repo.get(Canopy.Repositories.Repository, id),
      do: changeset,
      else: Ecto.Changeset.add_error(changeset, :repository_id, "does not exist")
  end

  defp check_repository(changeset), do: changeset

  defp count(repository_id),
    do: Repo.aggregate(from(s in Section, where: s.repository_id == ^repository_id), :count)

  defp shift(repository_id, from, by) do
    Repo.update_all(
      from(s in Section, where: s.repository_id == ^repository_id and s.position >= ^from),
      inc: [position: by]
    )
  end

  defp renumber(sections) do
    sections
    |> Enum.with_index()
    |> Enum.each(fn {section, index} ->
      if section.position != index,
        do:
          Repo.update_all(from(s in Section, where: s.id == ^section.id), set: [position: index])
    end)
  end

  defp transaction(fun), do: Repo.transaction(fun, mode: :immediate)

  defp notify({:ok, _} = result) do
    Channels.notify_changed()
    result
  end

  defp notify(error), do: error
end
