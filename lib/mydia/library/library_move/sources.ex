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
  Finishes each recorded source whose row now lives in `target`: deletes the
  old path when it is still the same file as the new one (a hardlink or a
  byte-identical copy, on S3 too), then carries its sidecars. An old path
  that is already gone had its delete done, and only its sidecars and their
  `subtitles` rows are finished.

  An old path that a row now claims (a scan re-registered the orphan during
  a backoff) is someone's file and is kept.

  Returns how many sources failed in a way worth retrying.
  """
  @spec sweep([map()], LibraryPath.t()) :: non_neg_integer()
  def sweep(sources, %LibraryPath{} = target) do
    Enum.count(sources, fn source ->
      case sweep_one(source, target) do
        {result, _left_behind} -> FileStep.transient?(result)
        _skipped -> false
      end
    end)
  end

  defp sweep_one(%{"id" => id, "path" => old} = source, target) do
    with %MediaFile{library_path_id: lp_id} = row when lp_id == target.id <-
           Repo.get(MediaFile, id) |> Repo.preload(:library_path),
         new when is_binary(new) and new != old <- MediaFile.storage_path(row),
         true <- FileMove.exists?(new),
         false <- is_nil(source["lp"]) or FileMove.claimed?(source["lp"], source["rel"], id),
         true <- gone?(old) or FileMove.same_file?(old, new) or FileMove.identical_copy?(old, new),
         %MediaFile{} = old_file <- old_file(source, library(source["lp"])) do
      FileStep.finish_swept(old_file, new, target)
    end
  end

  # Only a definite "not found": a storage outage is not proof of a delete.
  defp gone?(path) do
    with {:ok, source} <- Mydia.Storage.at(path),
         {:error, %Mydia.Storage.Error{kind: :not_found}} <- Mydia.Storage.stat(source) do
      true
    else
      _ -> false
    end
  end

  @doc """
  The recorded locations as unsaved media files with `:library_path` loaded,
  for `Mydia.Library.ItemFolders.folders_for/1`.
  """
  @spec old_files([map()]) :: [MediaFile.t()]
  def old_files(sources) do
    libraries = sources |> Enum.map(& &1["lp"]) |> Enum.uniq() |> Map.new(&{&1, library(&1)})

    for %{"lp" => lp} = source <- sources, libraries[lp], do: old_file(source, libraries[lp])
  end

  defp old_file(_source, nil), do: nil

  # struct/2, not a %MediaFile{} literal: the literal's nil defaults for
  # fields MediaFile.t() types as non-nil (inserted_at, ...) make Dialyzer
  # reject every call that takes it as a MediaFile.t().
  defp old_file(source, %LibraryPath{} = library) do
    struct(MediaFile,
      id: source["id"],
      relative_path: source["rel"],
      library_path_id: library.id,
      library_path: library,
      extra_kind: if(source["extra"], do: :featurette)
    )
  end

  defp library(nil), do: nil
  defp library(id), do: Repo.get(LibraryPath, id)
end
