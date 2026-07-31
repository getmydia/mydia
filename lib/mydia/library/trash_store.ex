defmodule Mydia.Library.TrashStore do
  @moduledoc """
  Moves trashed media off the library path and back.

  ## Why the file moves at all

  `Mydia.Library.trash_media_file/1` used to only stamp `trashed_at` and leave
  the file exactly where it was. Trashed rows are excluded from
  `Mydia.Library.list_media_files/1`, so the next library scan saw a path on
  disk with no active row behind it, classified it as a **new** file, looked
  the path up with `include_trashed: true`, found the trashed row and restored
  it. Every automatic quality upgrade was undone by the following scan, and a
  file rejected for lying about its contents came back as a playable file.
  Taking the file off the library path is what makes the soft delete stick.

  ## Where the trash lives

  By default, a `.mydia-trash` directory **beside** the library path root:
  a library at `/media/movies` trashes into `/media/.mydia-trash`. Two
  properties drive that choice.

    * It is outside the library path, so `Mydia.Library.Scanner` never walks
      it. (As a second line of defence the scanner also skips any directory
      named `.mydia-trash`, which covers nested layouts where one library path
      happens to contain another library's parent directory.)
    * It is almost always on the same filesystem as the media, so the move is
      an atomic `rename(2)` rather than a byte-for-byte copy of a 60 GB remux.

  Set `MYDIA_TRASH_DIR` (or `config :mydia, :trash_dir, "/path"`) to collect
  every library's trash in one directory instead. If you do, pick a directory
  that is outside all of your library paths and on the same filesystem as your
  media: a trash root on another mount forces a copy-then-delete, which this
  module will still perform, but slowly and with a loud warning.

  Inside the root each file gets its own directory named after the media file
  id (`<root>/<media_file_id>/<basename>`), so two files with the same basename
  never collide and the original filename stays readable to an operator looking
  through the trash.

  The absolute path a file was moved to is recorded on the row itself, under
  `metadata.extra["trashed_path"]`, so restore and purge do not depend on the
  configuration still resolving to the same directory later. Rows trashed
  before this module existed carry no such key: those files are still sitting
  at their library path, which is where `restore/2` and `discard/2` look when
  the key is missing.
  """

  require Logger

  alias Mydia.Library.MediaFile

  @dir_name ".mydia-trash"

  @doc """
  The directory name used for the default, per-library trash root.

  Read by `Mydia.Library.Scanner` so a trash directory that ends up inside a
  library path anyway (nested library layouts) is still never scanned.
  """
  @spec dir_name() :: String.t()
  def dir_name, do: @dir_name

  @doc """
  Moves `media_file`'s file out of the library and into the trash directory.

  Returns `{:ok, absolute_trash_path}` on success, or `{:ok, nil}` when there
  was nothing to move: the path could not be resolved (no library path) or the
  file is already gone from disk. A missing file is the *original* reason
  `trash_media_file/1` exists (marking what a scan found missing), so it stays
  a normal outcome rather than an error.

  Returns `{:error, reason}` when a file that is present could not be moved.
  The caller must not mark the row trashed in that case.
  """
  @spec store(MediaFile.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def store(%MediaFile{} = media_file) do
    case MediaFile.absolute_path(media_file) do
      nil ->
        {:ok, nil}

      source ->
        if File.exists?(source) do
          do_store(media_file, source)
        else
          {:ok, nil}
        end
    end
  end

  @doc """
  Moves a trashed file back to its library path.

  `trash_path` is the recorded `metadata.extra["trashed_path"]`, or nil for a
  row that was never moved (trashed before this module existed, or trashed
  while its file was already missing).

  A file that is absent from the trash directory is not an error: the row can
  still be restored, it simply has no bytes behind it, exactly as before this
  module existed. Neither is a destination that is already occupied - that
  means something has since put a file back at the original path, and
  clobbering it would be worse than leaving a copy in the trash.
  """
  @spec restore(MediaFile.t(), String.t() | nil) :: :ok | {:error, term()}
  def restore(%MediaFile{}, nil), do: :ok

  def restore(%MediaFile{} = media_file, trash_path) when is_binary(trash_path) do
    destination = MediaFile.absolute_path(media_file)

    cond do
      not File.exists?(trash_path) ->
        Logger.warning("Restoring a media file whose trashed copy is gone from disk",
          media_file_id: media_file.id,
          trashed_path: trash_path
        )

        :ok

      is_nil(destination) ->
        Logger.error("Cannot restore a trashed media file: its library path no longer resolves",
          media_file_id: media_file.id,
          trashed_path: trash_path
        )

        {:error, :path_not_resolved}

      File.exists?(destination) ->
        Logger.warning(
          "Restoring a media file whose library path is already occupied; leaving the trashed " <>
            "copy in place rather than overwriting what is there",
          media_file_id: media_file.id,
          trashed_path: trash_path,
          path: destination
        )

        :ok

      true ->
        move_back(media_file, trash_path, destination)
    end
  end

  @doc """
  Permanently deletes the bytes behind a trashed row.

  Deletes the trashed copy when `trash_path` is set, and otherwise the file at
  the library path - which is where rows trashed before this module existed
  still have theirs. That second case is the other half of
  [#295](https://github.com/getmydia/mydia/issues/295): the purge used to drop
  the row and leave the file on disk forever.
  """
  @spec discard(MediaFile.t(), String.t() | nil) :: :ok
  def discard(%MediaFile{} = media_file, trash_path) do
    library_path = MediaFile.absolute_path(media_file)

    if is_binary(trash_path) do
      delete_file(media_file, trash_path)
      prune_container(trash_path)
    end

    # The NFO sidecar is never moved into the trash (the scanner does not index
    # it, so it cannot resurrect anything), but it must not outlive the media
    # file it describes. For a legacy row this also deletes the media file
    # itself, still sitting where it always was.
    if is_binary(library_path) do
      if is_nil(trash_path), do: delete_file(media_file, library_path)
      Mydia.Metadata.NfoWriter.delete_nfo_for_file(library_path)
    end

    :ok
  end

  @doc """
  The trash root for a media file's library path.

  Exposed for operator-facing surfaces and tests; `store/1` resolves it itself.
  """
  @spec root_for(MediaFile.t()) :: String.t() | nil
  def root_for(%MediaFile{library_path: %{path: path}}) when is_binary(path) do
    case Application.get_env(:mydia, :trash_dir) do
      configured when is_binary(configured) and configured != "" ->
        configured

      _ ->
        path
        |> Path.expand()
        |> Path.dirname()
        |> Path.join(@dir_name)
    end
  end

  def root_for(%MediaFile{}), do: nil

  defp do_store(media_file, source) do
    destination = Path.join([root_for(media_file), media_file.id, Path.basename(source)])

    case move(source, destination) do
      :ok ->
        Logger.info("Moved a media file into the trash directory",
          media_file_id: media_file.id,
          from: source,
          to: destination
        )

        {:ok, destination}

      {:error, reason} = error ->
        Logger.error(
          "Could not move a media file into the trash directory; leaving it in the library",
          media_file_id: media_file.id,
          from: source,
          to: destination,
          reason: inspect(reason)
        )

        error
    end
  end

  defp move_back(media_file, trash_path, destination) do
    case move(trash_path, destination) do
      :ok ->
        prune_container(trash_path)

        Logger.info("Restored a media file from the trash directory",
          media_file_id: media_file.id,
          from: trash_path,
          to: destination
        )

        :ok

      {:error, reason} = error ->
        Logger.error("Could not restore a media file from the trash directory",
          media_file_id: media_file.id,
          from: trash_path,
          to: destination,
          reason: inspect(reason)
        )

        error
    end
  end

  # An atomic rename is the whole point: media files are large and a partially
  # copied one is worse than one that never moved. `File.rename/2` only fails
  # with :exdev when source and destination are on different filesystems, which
  # is the single case worth degrading for.
  defp move(source, destination) do
    with :ok <- File.mkdir_p(Path.dirname(destination)) do
      case File.rename(source, destination) do
        :ok -> :ok
        {:error, :exdev} -> copy_across_filesystems(source, destination)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp copy_across_filesystems(source, destination) do
    Logger.warning(
      "Trash directory is on a different filesystem than the media file, so the file has to be " <>
        "copied instead of renamed. This is slow for large media and doubles the space needed " <>
        "while it runs. Point MYDIA_TRASH_DIR at a directory on the same filesystem as the " <>
        "library to avoid it.",
      from: source,
      to: destination
    )

    with :ok <- File.cp(source, destination),
         :ok <- File.rm(source) do
      :ok
    else
      {:error, reason} ->
        # Either the copy failed part-way or the original could not be removed.
        # Both leave the original in place, so drop whatever reached the other
        # side and report the move as failed rather than leaving two copies.
        _ = File.rm(destination)
        {:error, {:cross_filesystem_move_failed, reason}}
    end
  end

  defp delete_file(media_file, path) do
    case File.rm(path) do
      :ok ->
        Logger.info("Permanently deleted a trashed media file",
          media_file_id: media_file.id,
          path: path
        )

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.error("Could not permanently delete a trashed media file",
          media_file_id: media_file.id,
          path: path,
          reason: inspect(reason)
        )
    end
  end

  # The per-file container directory only ever holds the one file, so removing
  # it once that file is gone keeps the trash root tidy. rmdir refuses on a
  # non-empty directory, which is exactly the guard we want.
  defp prune_container(trash_path) do
    _ = File.rmdir(Path.dirname(trash_path))
    :ok
  end
end
