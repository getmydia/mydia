defmodule Mydia.Library.Relink.Scan do
  @moduledoc """
  What a scan does with rows whose files are no longer where they say.

  Wires `Mydia.Library.Relink` into the two places that notice a file has
  gone: the library scanner (`Mydia.Jobs.LibraryScanner`) and the per-item
  re-scan (`Mydia.Library.Rescan`). A row whose file was renamed or moved is
  repointed at it; the rest are trashed as missing (`trash_missing/1`).

  This is known-file maintenance. It runs in both auto_import modes, and a
  row that fails to relink falls back to the caller's usual handling: the
  row is trashed as missing and the new path is treated as unknown.
  """

  require Logger

  alias Mydia.Library.{MediaFile, MediaFiles, Relink, Trash}
  alias Mydia.{Repo, Storage}
  alias Mydia.Settings.LibraryPath

  @doc """
  Trashes each row a library scan found missing from disk, without moving
  anything (`move: false`). The row is trashed, not deleted, so it can be
  restored if the file reappears. Never raises over one row.
  """
  @spec trash_missing([MediaFile.t()]) :: :ok
  def trash_missing(missing) do
    Enum.each(missing, fn media_file ->
      media_file = Repo.preload(media_file, :library_path)
      absolute_path = MediaFile.absolute_path(media_file)

      # `move: false`: the scan listed this file as gone, but it can reappear
      # before we get here (a reconnecting mount, a concurrent import). A
      # moved file would land in the trash on a row stamped :missing, which
      # the trash page hides and a later reappearance can never restore, so
      # TrashStore refuses to move a present file and the row stays active.
      # Any other failure is a database problem: log it and keep going rather
      # than crashing the whole scan over one row.
      case Trash.trash_media_file(media_file, reason: :missing, move: false) do
        {:ok, _} ->
          Logger.debug("Trashed media file record", path: absolute_path)

        {:error, {:trash_move_failed, :file_present}} ->
          Logger.info("A file the scan called missing is back on disk; leaving it in place",
            path: absolute_path,
            media_file_id: media_file.id
          )

        {:error, reason} ->
          Logger.error("Failed to trash a media file missing from disk",
            path: absolute_path,
            media_file_id: media_file.id,
            reason: inspect(reason)
          )
      end
    end)
  end

  @doc """
  Relinks the pairs between `gone` rows and `new_files`, which must share a
  scope (one library, or one item's directory). `gone` rows need
  `:library_path` preloaded. Returns the gone rows and new files that remain,
  failures included.
  """
  @spec renamed([MediaFile.t()], [Relink.file_info()], [LibraryPath.t()]) ::
          {[MediaFile.t()], [Relink.file_info()]}
  def renamed(gone, new_files, library_paths) do
    {pairs, gone_left, new_left} = Relink.pair(gone, new_files)
    {_relinked, failed} = Relink.relink_all(pairs, library_paths)

    {gone_left ++ Enum.map(failed, &elem(&1, 0)), new_left ++ Enum.map(failed, &elem(&1, 1))}
  end

  @doc """
  A scan's rename pass: `renamed/3` over a library's deleted rows and new
  paths. Never fails the scan: if pairing or a relink raises, both lists are
  handed back unchanged, which is what happened before relinking existed.
  """
  @spec within([MediaFile.t()], [Relink.file_info()], [LibraryPath.t()]) ::
          {[MediaFile.t()], [Relink.file_info()]}
  def within([], new_files, _library_paths), do: {[], new_files}
  def within(deleted, [], _library_paths), do: {deleted, []}

  def within(deleted, new_files, library_paths) do
    deleted |> Repo.preload(:library_path) |> renamed(new_files, library_paths)
  rescue
    error ->
      Logger.warning("Relinking renamed files failed; handling them as deleted and new",
        error: Exception.format(:error, error, __STACKTRACE__)
      )

      {deleted, new_files}
  end

  @doc """
  A scan's move pass. A move between libraries spans two scans, so the old
  row is either already trashed as missing or, when this library is scanned
  first, still active in another library with its file gone.

  Pairs `unknown` paths in `library_path` with such rows elsewhere. Returns
  `{unknown_left, new_files_left}`: relinked paths are dropped from both,
  since they were neither unknown nor new. Never fails the scan: if the
  lookup or a relink raises, both lists come back unchanged and discovery
  treats the paths as new, which is what happened before relinking existed.
  """
  @spec across([Relink.file_info()], [Relink.file_info()], LibraryPath.t(), [LibraryPath.t()]) ::
          {[Relink.file_info()], [Relink.file_info()]}
  def across([], new_files, _library_path, _library_paths), do: {[], new_files}

  def across(unknown, new_files, library_path, library_paths) do
    candidates =
      unknown
      |> Enum.map(& &1.size)
      |> MediaFiles.list_relink_candidates(library_path.id)
      |> Enum.filter(&file_gone?/1)

    {pairs, _, unknown_left} = Relink.pair(candidates, unknown)
    {relinked, failed} = Relink.relink_all(pairs, library_paths)
    relinked_paths = MapSet.new(relinked, fn {_row, info} -> info.path end)

    {unknown_left ++ Enum.map(failed, &elem(&1, 1)),
     Enum.reject(new_files, &MapSet.member?(relinked_paths, &1.path))}
  rescue
    error ->
      Logger.warning("Cross-library relink failed; treating found files as new",
        library_path_id: library_path.id,
        error: Exception.format(:error, error, __STACKTRACE__)
      )

      {unknown, new_files}
  end

  @doc """
  True only when `media_file`'s file is definitely not where its row says.

  Anything that cannot be decided reads as `false`: a row with no resolvable
  path, a local library whose root directory is missing or empty (an
  unmounted share looks exactly like either), or an S3 error other than
  not-found. Used to decide whether an active row may be repointed at a file
  found elsewhere, where guessing wrong would steal a row from a library that
  is merely offline. `media_file` needs `:library_path` preloaded.
  """
  @spec absent?(MediaFile.t()) :: boolean()
  def absent?(%MediaFile{} = media_file) do
    if Storage.s3?(media_file) do
      object_absent?(media_file)
    else
      case MediaFile.absolute_path(media_file) do
        nil -> false
        path -> library_root_present?(media_file) and not File.exists?(path)
      end
    end
  end

  # A trashed-missing row is gone by definition. An active row is gone only if
  # its file is definitely not where it says (absent?/1), so a row is never
  # taken from a library that is merely unreachable.
  #
  # A row holding a copy of its bytes in the trash directory is never a
  # candidate: relinking it would orphan that copy. Relink.pair/2 refuses it
  # too; filtering here keeps it out of the pairing's ambiguity counts.
  defp file_gone?(%MediaFile{} = media_file) do
    not Relink.holds_trash_copy?(media_file) and gone_from_disk?(media_file)
  end

  defp gone_from_disk?(%MediaFile{trashed_reason: :missing, trashed_at: %DateTime{}}), do: true
  defp gone_from_disk?(%MediaFile{} = media_file), do: absent?(media_file)

  defp object_absent?(media_file) do
    with {:ok, source} <- Storage.source(media_file),
         {:error, %Storage.Error{kind: :not_found}} <- Storage.stat(source) do
      true
    else
      _ -> false
    end
  end

  # An unmounted share often leaves its mount point behind as an empty
  # directory, so an empty root is as undecidable as a missing one.
  defp library_root_present?(%MediaFile{library_path: %{path: root}}) when is_binary(root),
    do: match?({:ok, [_ | _]}, File.ls(root))

  defp library_root_present?(_), do: false
end
