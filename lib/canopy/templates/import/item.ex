defmodule Canopy.Templates.Import.Item do
  @moduledoc """
  One thing an import would write: an agent, a team, or a playbook, read from
  one file. The first group of fields comes from the file and never changes;
  the rest is worked out against the database, this machine, and the user's
  choice each time the preview changes (`Canopy.Templates.Import.choose/2`).

    * `status` — `:new`, `:conflict` (the name is taken), `:identical`
      (already here, nothing differs), or `:invalid`
    * `picked` — what the user chose in the preview (any of `action`,
      `name`, `memory`, `engine`); `choice` — what will happen, worked out
      from `picked` and the status: `action` (`:create`, `:rename`,
      `:replace`, `:skip`), the new `name` for a rename, `memory`
      (`:import`/`:skip` for a new agent, `:keep`/`:replace`/`:append` for a
      replaced one), and `engine` (an agent's engine, which the user may
      switch). A pick the status doesn't offer falls back to the default.
    * `errors` block the import unless the item is skipped; `notices` are
      what was changed to fit this machine, or worth knowing
  """

  defstruct id: nil,
            kind: :agent,
            path: nil,
            name: nil,
            template: nil,
            file_errors: [],
            file_notices: [],
            # worked out
            engine: nil,
            attrs: %{},
            memory: nil,
            body: nil,
            status: :new,
            existing: nil,
            diff: [],
            prompt_diff: nil,
            members: [],
            permission: nil,
            errors: [],
            notices: [],
            picked: %{},
            choice: %{action: nil, name: nil, memory: nil, engine: nil}

  @type t :: %__MODULE__{}

  @doc "The name the item will have: the rename, or the file's."
  def target_name(%__MODULE__{choice: %{action: :rename, name: name}}) when is_binary(name),
    do: name

  def target_name(%__MODULE__{name: name}), do: name

  @doc "Whether the import writes this item."
  def writes?(%__MODULE__{choice: %{action: action}}), do: action not in [:skip, nil]

  @doc "The actions the preview offers for the item's status."
  def actions(%__MODULE__{status: :invalid}), do: [:skip]
  def actions(%__MODULE__{status: :new}), do: [:create, :skip]
  def actions(%__MODULE__{status: :identical}), do: [:skip, :rename]
  def actions(%__MODULE__{status: :conflict, existing: nil}), do: [:rename, :skip]
  def actions(%__MODULE__{status: :conflict}), do: [:rename, :replace, :skip]

  @doc "The action an item starts with."
  def default_action(%__MODULE__{status: :invalid}), do: :skip
  def default_action(%__MODULE__{status: :new}), do: :create
  def default_action(%__MODULE__{status: :identical}), do: :skip
  def default_action(%__MODULE__{status: :conflict}), do: :rename

  @doc "How the item is named in the preview and the summary (`@backend`, `bug-fix`)."
  def label(%__MODULE__{kind: :playbook} = item), do: "playbook " <> (target_name(item) || "?")
  def label(%__MODULE__{kind: :team} = item), do: "@" <> (target_name(item) || "?") <> " (team)"
  def label(%__MODULE__{} = item), do: "@" <> (target_name(item) || item.path || "?")
end
