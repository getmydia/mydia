defmodule Mydia.Library.ItemFolders do
  @moduledoc """
  Finds the folders a media item lives in, and decides whether each can be
  removed when the item is deleted from disk (getmydia/mydia#890).

  A media item stores no folder, so one is derived per file with
  `Mydia.Library.PathAnchor.anchor_for/2`: the folder that names the media,
  above any season, disc, quality or redundant release folder.

  File paths are not proof of ownership. Items often hold files misidentified
  from another show's folder, and a file can sit loose in the library root
  (see "Multi-file items are mostly misidentification" in
  `lib/mydia/media/README.md`). Deleting `Path.dirname/1` of a file would, in
  those cases, delete another show or the whole library. So a folder is only
  removed when `blockers/2` finds nothing media-like in it that is not the
  item's.
  """

  import Ecto.Query

  alias Mydia.Library.Dirs
  alias Mydia.Library.ImportCandidate
  alias Mydia.Library.ItemFolders.Folder
  alias Mydia.Library.MediaFile
  alias Mydia.Library.PathAnchor
  alias Mydia.Library.SampleDetector
  alias Mydia.Library.Scanner
  alias Mydia.Library.TrashStore
  alias Mydia.LibrarySearch.Tokenizer
  alias Mydia.Repo
  alias Mydia.Settings
  alias Mydia.Settings.LibraryPath

  @type blocker :: {:media_file | :import_candidate | :video | :unreadable, String.t()}

  @blocker_limit 5

  @doc """
  The folders to remove for these media files.

  One anchor per untrashed, non-extra file whose library path is loaded. A
  file loose in the library root has no folder. Duplicates collapse, a folder
  nested inside another one from the list is dropped (the outer one covers
  it), and a folder that is a library path or contains one is refused.
  """
  @spec folders_for([MediaFile.t()]) :: [Folder.t()]
  def folders_for(media_files) when is_list(media_files) do
    roots = library_roots()

    media_files
    |> Enum.filter(&(is_nil(&1.trashed_at) and is_nil(&1.extra_kind)))
    |> Enum.flat_map(&anchor_folder/1)
    |> Enum.uniq_by(& &1.absolute)
    |> drop_nested()
    |> Enum.reject(&holds_library_root?(&1, roots))
  end

  @doc """
  What in `folder` is not the item's, and so keeps the folder.

  `ignore` lists the item's own media files: their ids are skipped in the
  database check and their paths on disk. Returns at most #{@blocker_limit}
  blockers, database rows first. `[]` means the folder holds nothing
  media-like beyond the ignored files.

    * `{:media_file, rel}`: an active media file row of anything else
    * `{:import_candidate, rel}`: a file Mydia discovered but has not placed
    * `{:video, rel}`: a video on disk with no row, unless `SampleDetector`
      calls it a sample, trailer or extra
    * `{:unreadable, rel}`: a subdirectory that could not be listed, so what
      it holds is unknown

  `rel` is relative to the library path. The disk walk never follows a
  symlink and skips `.mydia-trash`.
  """
  @spec blockers(Folder.t(), keyword()) :: [blocker()]
  def blockers(%Folder{} = folder, opts \\ []) do
    ignore = Keyword.get(opts, :ignore, [])
    ignore_ids = MapSet.new(ignore, & &1.id)

    rows =
      row_blockers(MediaFile, :media_file, folder, ignore_ids) ++
        row_blockers(ImportCandidate, :import_candidate, folder, MapSet.new())

    if length(rows) >= @blocker_limit do
      Enum.take(rows, @blocker_limit)
    else
      # A file already reported as a row is not reported again as a video.
      row_paths = Enum.map(rows, fn {_kind, rel} -> Path.join(folder.library_path.path, rel) end)
      skip = MapSet.new(ignore_paths(ignore) ++ row_paths)
      rows ++ disk_blockers(folder, skip, @blocker_limit - length(rows))
    end
  end

  defp ignore_paths(files) do
    files |> Enum.map(&MediaFile.absolute_path/1) |> Enum.reject(&is_nil/1)
  end

  # LIKE narrows the rows in SQL, with an explicit ESCAPE so a `%` or `_` in a
  # folder name matches literally on both adapters. The String.starts_with?/2
  # check is the real test: it keeps "Show" from claiming "Show 2/", and holds
  # where SQLite's LIKE ignores ASCII case.
  defp row_blockers(schema, kind, %Folder{} = folder, ignore_ids) do
    prefix = folder.relative <> "/"
    pattern = Tokenizer.escape_like(prefix) <> "%"

    schema
    |> where([r], r.library_path_id == ^folder.library_path.id)
    |> where([r], fragment("? LIKE ? ESCAPE '\\'", r.relative_path, ^pattern))
    |> only_active(schema)
    |> order_by([r], asc: r.relative_path)
    |> select([r], {r.id, r.relative_path})
    |> Repo.all()
    |> Enum.filter(fn {id, rel} ->
      String.starts_with?(rel, prefix) and not MapSet.member?(ignore_ids, id)
    end)
    |> Enum.map(fn {_id, rel} -> {kind, rel} end)
  end

  # A trashed row's bytes already live in the trash, not in this folder.
  defp only_active(query, MediaFile), do: where(query, [r], is_nil(r.trashed_at))
  defp only_active(query, ImportCandidate), do: query

  defp disk_blockers(%Folder{} = folder, skip, limit) do
    folder.absolute
    |> walk([], skip, limit)
    |> Enum.reverse()
    |> Enum.map(fn {kind, path} -> {kind, Path.relative_to(path, folder.library_path.path)} end)
  end

  defp walk(dir, acc, skip, limit) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce_while(acc, fn name, acc ->
          if length(acc) >= limit,
            do: {:halt, acc},
            else: {:cont, visit(Path.join(dir, name), name, acc, skip, limit)}
        end)

      # Vanished between listing and descending: nothing is there.
      {:error, :enoent} ->
        acc

      {:error, _reason} ->
        [{:unreadable, dir} | acc]
    end
  end

  defp visit(path, name, acc, skip, limit) do
    if name == TrashStore.dir_name() do
      acc
    else
      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} ->
          walk(path, acc, skip, limit)

        {:ok, %File.Stat{type: :regular}} ->
          if foreign_video?(path, name, skip), do: [{:video, path} | acc], else: acc

        _symlink_or_other ->
          acc
      end
    end
  end

  defp foreign_video?(path, name, skip) do
    String.downcase(Path.extname(name)) in Scanner.video_extensions() and
      not MapSet.member?(skip, path) and
      not SampleDetector.excluded?(SampleDetector.detect(path))
  end

  defp anchor_folder(%MediaFile{library_path: %LibraryPath{path: root} = library_path} = file)
       when is_binary(root) do
    with absolute when is_binary(absolute) <- MediaFile.absolute_path(file),
         %{anchor_path: relative} when relative != "" <- PathAnchor.anchor_for(absolute, root) do
      [
        %Folder{
          library_path: library_path,
          relative: relative,
          absolute: Path.join(root, relative)
        }
      ]
    else
      _ -> []
    end
  end

  defp anchor_folder(%MediaFile{}), do: []

  defp drop_nested(folders) do
    Enum.reject(folders, fn folder ->
      Enum.any?(folders, &Dirs.inside?(folder.absolute, &1.absolute))
    end)
  end

  defp holds_library_root?(%Folder{absolute: absolute}, roots) do
    expanded = Path.expand(absolute)
    Enum.any?(roots, &(&1 == expanded or Dirs.inside?(&1, expanded)))
  end

  # Disabled rows count: a disabled library's files are still someone's
  # media. Runtime-configured paths count too, in case one has no row yet.
  defp library_roots do
    db_paths = Repo.all(from(l in LibraryPath, select: l.path))
    runtime_paths = Enum.map(Settings.list_library_paths(), & &1.path)

    (db_paths ++ runtime_paths)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end
end
