defmodule Canopy.Playbooks.Playbook do
  @moduledoc """
  A named, reusable process in the library: one Markdown text with YAML
  frontmatter (see `Canopy.Playbooks.Definition`). `name` and `description`
  are copied out of the text when it is saved, so lists need no parsing;
  a text that does not parse is an error on `body`, one per reason.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Canopy.Playbooks.Definition
  alias Canopy.Playbooks.Sharing.Text

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["pb"]}}
  @foreign_key_type :string

  @sources ~w(seed user agent)

  schema "playbooks" do
    field :name, :string
    field :description, :string
    field :body, :string
    field :enabled, :boolean, default: true
    field :source, :string, default: "user"
    field :lock_version, :integer, default: 1
    # the user's star (`Canopy.Playbooks.set_starred/2`); never cast, so an edit keeps it
    field :starred_at, :utc_datetime_usec
    # the number users see (`Canopy.Playbooks.Sharing`), separate from
    # lock_version; bumped by `Canopy.Playbooks.update/2` when the content
    # changes, never cast by the editor, and never written into the body
    field :version, :integer, default: 1
    # the GitHub copy this playbook follows, as of the last import or merged
    # export: origin_body is the text at that sync, the base for "who changed it"
    field :origin_repo, :string
    field :origin_path, :string
    field :origin_version, :integer
    field :origin_sha, :string
    field :origin_body, :string
    field :synced_at, :utc_datetime_usec
    # the open export pull request, if any; cleared when it merges or closes
    field :pr_number, :integer
    field :pr_url, :string
    field :pr_path, :string
    field :pr_version, :integer
    field :pr_sha, :string
    field :pr_body, :string

    belongs_to :created_by, Canopy.Agents.Agent, foreign_key: :created_by_agent_id

    timestamps(type: :utc_datetime_usec)
  end

  def sources, do: @sources

  def changeset(playbook, attrs) do
    playbook
    |> cast(attrs, [:body, :enabled, :source, :created_by_agent_id])
    |> common()
  end

  @doc """
  For `Canopy.Playbooks.Sharing` only (import): also casts `version` and the
  origin fields, with no version bump.
  """
  def sharing_changeset(playbook, attrs) do
    playbook
    |> cast(attrs, [
      :body,
      :enabled,
      :source,
      :version,
      :origin_repo,
      :origin_path,
      :origin_version,
      :origin_sha,
      :origin_body,
      :synced_at
    ])
    |> validate_number(:version, greater_than: 0)
    |> common()
  end

  @doc """
  Whether the changeset changes the body's content, as `Sharing.Text.content_hash/1`
  sees it (whitespace at line ends, `name:` and `version:` lines don't count).
  """
  def content_changed?(changeset) do
    case fetch_change(changeset, :body) do
      {:ok, body} -> Text.content_hash(body) != Text.content_hash(changeset.data.body)
      :error -> false
    end
  end

  defp common(changeset) do
    changeset
    # the version column is authoritative; a shared file's `version:` line
    # is dropped here and written back on export
    |> update_change(:body, &strip_version/1)
    |> validate_required([:body, :source])
    |> validate_length(:body, max: 40_000)
    |> validate_inclusion(:source, @sources)
    |> put_definition()
    |> unique_constraint(:name, message: "is already a playbook's name")
  end

  defp strip_version(body) when is_binary(body), do: Text.strip_version(body)
  defp strip_version(body), do: body

  defp put_definition(%{errors: errors} = changeset) do
    if Keyword.has_key?(errors, :body) do
      changeset
    else
      case Definition.parse(get_field(changeset, :body)) do
        {:ok, definition} ->
          changeset
          |> put_change(:name, definition.name)
          |> put_change(:description, definition.description)

        {:error, reasons} ->
          Enum.reduce(reasons, changeset, &add_error(&2, :body, &1))
      end
    end
  end
end
