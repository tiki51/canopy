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

    belongs_to :created_by, Canopy.Agents.Agent, foreign_key: :created_by_agent_id

    timestamps(type: :utc_datetime_usec)
  end

  def sources, do: @sources

  def changeset(playbook, attrs) do
    playbook
    |> cast(attrs, [:body, :enabled, :source, :created_by_agent_id])
    |> validate_required([:body, :source])
    |> validate_length(:body, max: 40_000)
    |> validate_inclusion(:source, @sources)
    |> put_definition()
    |> unique_constraint(:name, message: "is already a playbook's name")
  end

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
