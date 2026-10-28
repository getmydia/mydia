defmodule Mydia.Library.LibraryMove.Sources do
  @moduledoc """
  Where an item's files were when its move was enqueued, kept in the job's
  args so a retry can still find them after their rows have moved.

  `sweep/2` finishes files whose relink committed but whose source was not
  deleted (a crash, or a failed delete); `old_files/1` rebuilds those old
  locations so their folders are tidied on a retry too.
  """

  alias Mydia.Library.FileMove
  alias Mydia.Library.LibraryMove.FileStep
  alias Mydia.Library.LibraryMove.Move
  alias Mydia.Library.MediaFile
  alias Mydia.Repo
  alias Mydia.Settings.LibraryPath

  @doc "The job-args form of a plan."
  @spec encode([Move.t()]) :: [map()]
  def encode(moves) do
    Enum.map(moves, fn %Move{media_file: file, source_path: path} ->
      %{
        "id" => file.id,
        "path" => path,
        "rel" => file.relative_path,
        "lp" => file.library_path_id,
        "extra" => not is_nil(file.extra_kind)
      }
    end)
  end

  @doc """
  Deletes each recorded source whose row now lives in `target` and whose old
  path is still the same file as the new one (a hardlink or a byte-identical
  copy), then carries its sidecars. Local paths only: the predicates stat
  files, so an S3 source never matches and is left alone.
  """
  @spec sweep([map()], LibraryPath.t()) :: :ok
  def sweep(sources, %LibraryPath{} = target) do
    Enum.each(sources, fn %{"id" => id, "path" => old} ->
      with %MediaFile{library_path_id: lp_id} = row when lp_id == target.id <-
             Repo.get(MediaFile, id) |> Repo.preload(:library_path),
           new when is_binary(new) and new != old <- MediaFile.storage_path(row),
           true <- FileMove.exists?(new) and FileMove.exists?(old),
           true <- FileMove.same_file?(old, new) or FileMove.identical_copy?(old, new) do
        FileStep.finish_source(old, new, id, target)
      end
    end)
  end

  @doc """
  The recorded locations as unsaved media files with `:library_path` loaded,
  for `Mydia.Library.ItemFolders.folders_for/1`.
  """
  @spec old_files([map()]) :: [MediaFile.t()]
  def old_files(sources) do
    libraries = sources |> Enum.map(& &1["lp"]) |> Enum.uniq() |> Map.new(&{&1, library(&1)})

    for %{"rel" => rel, "lp" => lp} = source <- sources, libraries[lp] do
      %MediaFile{
        id: source["id"],
        relative_path: rel,
        library_path_id: lp,
        library_path: libraries[lp],
        extra_kind: if(source["extra"], do: :featurette)
      }
    end
  end

  defp library(nil), do: nil
  defp library(id), do: Repo.get(LibraryPath, id)
end
