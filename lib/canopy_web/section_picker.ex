defmodule CanopyWeb.SectionPicker do
  @moduledoc """
  The section pickers on the New channel form and the playbook Start page:
  "No section" (`""`), a section's name, or "New section…", whose value is
  `new/0`. Section names are trimmed when saved, so a value with a leading
  space can never be one.
  """

  @new " new"

  @doc "The option value of \"New section…\"."
  def new, do: @new
end
