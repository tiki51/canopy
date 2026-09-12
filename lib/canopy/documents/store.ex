defmodule Canopy.Documents.Store do
  @moduledoc """
  Where document bytes live: one file per document id, no extension, in a
  directory next to the database (`canopy_dev.db` → `canopy_dev_files/`).
  `config :canopy, :files_dir` or `CANOPY_FILES_DIR` overrides the location.
  Nothing outside this module touches the directory.
  """

  @doc "The absolute storage directory. Created on first use."
  def dir do
    path =
      Application.get_env(:canopy, :files_dir) ||
        derive_from_database(Canopy.Repo.config()[:database])

    path = Path.expand(path)
    File.mkdir_p!(path)
    path
  end

  defp derive_from_database(nil), do: Path.expand("canopy_files")

  defp derive_from_database(database) do
    Path.rootname(Path.expand(database), ".db") <> "_files"
  end

  @doc "The absolute path of a document's bytes (whether or not they exist)."
  def path(id) when is_binary(id), do: Path.join(dir(), id)

  @doc """
  Writes the bytes for `id` from `{:binary, bytes}` or `{:path, file}`. A
  source path is copied, never moved: LiveView removes its own temp files.
  """
  def put(id, {:binary, bytes}) when is_binary(bytes), do: File.write(path(id), bytes)
  def put(id, {:path, source}) when is_binary(source), do: File.cp(source, path(id))

  def delete(id) do
    case File.rm(path(id)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  def exists?(id), do: File.regular?(path(id))

  def read(id), do: File.read(path(id))

  @doc "Total bytes on disk across every stored document."
  def total_bytes do
    dir()
    |> File.ls!()
    |> Enum.reduce(0, fn name, acc ->
      case File.stat(Path.join(dir(), name)) do
        {:ok, %{type: :regular, size: size}} -> acc + size
        _ -> acc
      end
    end)
  end
end
