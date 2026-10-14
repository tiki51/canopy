defmodule Canopy.Signoffs.SignoffRequest do
  @moduledoc """
  A card asking the user to sign off on an agent's work: Accept or Reject,
  or one Accept per option plus Reject all. It comes from the
  `canopy_signoff_request` tool (freestanding) or from a playbook step held
  for the user's approval (run-linked: `run_id`, `playbook_step_id`, and the
  step's key in `step_id`).

  `options` is a list of `%{"label", "description", "recommended"}` maps,
  empty for a plain Accept / Reject. An answer sets `status`, `choice` (the
  chosen label) and `choice_index`, `note`, `resolved_by` and `resolved_at`;
  a freestanding answer also points at the message that carried it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["so"]}}
  @foreign_key_type :string

  @statuses ~w(pending accepted rejected withdrawn)
  @max_title 80
  @max_question 300
  @max_label 80
  @max_description 300
  @max_options 6
  @max_note 2_000

  schema "signoff_requests" do
    field :title, :string
    field :question, :string
    field :summary, :string
    field :options, {:array, :map}, default: []
    field :document_ids, {:array, :string}, default: []
    field :status, :string, default: "pending"
    field :choice, :string
    field :choice_index, :integer
    # the step's key ("tech-design"); nil outside runs
    field :step_id, :string
    field :note, :string
    field :resolved_by, :string
    field :resolved_at, :utc_datetime_usec
    # filled by Canopy.Signoffs on read, in `document_ids` order
    field :documents, {:array, :any}, virtual: true, default: []

    belongs_to :channel, Canopy.Channels.Channel
    belongs_to :agent, Canopy.Agents.Agent
    belongs_to :run, Canopy.Playbooks.Run
    belongs_to :step, Canopy.Playbooks.Step, foreign_key: :playbook_step_id
    belongs_to :message, Canopy.Messages.Message

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def max_title, do: @max_title
  def max_question, do: @max_question
  def max_note, do: @max_note

  @doc "A new card. `options` are normalised to string keys with a boolean `recommended`."
  def changeset(request, attrs) do
    request
    |> cast(attrs, [
      :channel_id,
      :agent_id,
      :run_id,
      :playbook_step_id,
      :step_id,
      :title,
      :question,
      :summary,
      :options,
      :document_ids,
      :status
    ])
    |> update_change(:title, &trim/1)
    |> update_change(:question, &trim/1)
    |> update_change(:options, &normalize_options/1)
    |> validate_required([:channel_id, :title, :question, :status])
    |> validate_length(:title, max: @max_title)
    |> validate_format(:title, ~r/\A[^\r\n]*\z/, message: "must be one line")
    |> validate_length(:question, max: @max_question)
    |> validate_length(:document_ids, max: Canopy.Messages.max_attachments())
    |> validate_options()
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:channel_id)
    |> foreign_key_constraint(:agent_id)
    |> unique_constraint(:playbook_step_id, name: :signoff_requests_one_pending_per_step)
  end

  @doc "Normalises tool or caller options to `%{\"label\", \"description\", \"recommended\"}`."
  def normalize_options(nil), do: []

  def normalize_options(options) when is_list(options) do
    Enum.map(options, fn option ->
      option = Map.new(option, fn {k, v} -> {to_string(k), v} end)

      %{
        "label" => trim(option["label"]),
        "description" => blank_to_nil(option["description"]),
        "recommended" => option["recommended"] in [true, "true"]
      }
    end)
  end

  defp validate_options(changeset) do
    options = get_field(changeset, :options) || []
    labels = Enum.map(options, & &1["label"])

    cond do
      length(options) == 1 or length(options) > @max_options ->
        add_error(changeset, :options, "give 2–6 options, or none for Accept / Reject")

      Enum.any?(labels, &(not is_binary(&1) or &1 == "")) ->
        add_error(changeset, :options, "each option needs a label")

      Enum.any?(labels, &(String.length(&1) > @max_label)) ->
        add_error(changeset, :options, "labels are at most #{@max_label} characters")

      Enum.uniq(labels) != labels ->
        add_error(changeset, :options, "labels must differ")

      Enum.any?(
        options,
        &(is_binary(&1["description"]) and
              String.length(&1["description"]) > @max_description)
      ) ->
        add_error(changeset, :options, "descriptions are at most #{@max_description} characters")

      Enum.count(options, & &1["recommended"]) > 1 ->
        add_error(changeset, :options, "at most one option may be recommended")

      true ->
        changeset
    end
  end

  defp trim(text) when is_binary(text), do: String.trim(text)
  defp trim(other), do: other

  defp blank_to_nil(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil
end
