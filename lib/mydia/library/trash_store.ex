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
    * It is on the same filesystem as the media, so the move is an atomic
      `rename(2)` rather than a byte-for-byte copy of a 60 GB remux.

  When the sibling cannot deliver the second property the trash goes *inside*
  the library path instead, at `<library>/.mydia-trash`, where the scanner's
  skip is what keeps it invisible. `default_root/1` covers the two cases: a
  library path that is a mount root (`/media`, `/data` - routine in Docker,
  where the parent is the container's writable layer and may be read-only),
  and a library path that is a mount below a directory on another filesystem
  (a NAS share at `/mnt/media`, with `/mnt` on the system disk).

  Set `MYDIA_TRASH_DIR` (or `config :mydia, :trash_dir, "/path"`) to collect
  every library's trash in one directory instead. If you do, pick a directory
  that is outside all of your library paths and on the same filesystem as your
  media: a trash root on another mount forces a copy-then-delete, which this
  module will still perform, but slowly and with a loud warning.

  Inside the root each file gets its own directory named after the media file
  id (`<root>/<media_file_id>/<basename>`), so two files with the same basename
  never collide and the original filename stays readable to an operator looking
  through the trash.

  ## What the row records

  Trashing writes one of two markers into `metadata.extra`, and `discard/2`
  needs the distinction to avoid deleting live media:

    * `"trashed_path"` - the absolute path the bytes were moved to, so restore
      and purge do not depend on the configuration still resolving to the same
      directory later.
    * `"trashed_missing"` - there was nothing on disk to move. That is a
      normal outcome (it is what a scan does when it finds a file gone), but
      it must not be confused with a row trashed before this module existed:
      those still have their file at the library path and the purge deletes it
      there, whereas a trashed-missing row may well have a live file at that
      path again. See `discard/2`.

  Rows trashed before this module existed carry neither key.
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

  Returns `{:ok, {:moved, absolute_trash_path}}` on success, or
  `{:ok, :missing}` when there was nothing to move: the path could not be
  resolved (no library path) or the file is already gone from disk. A missing
  file is the *original* reason `trash_media_file/1` exists (marking what a
  scan found missing), so it stays a normal outcome rather than an error.

  The caller must persist the difference between those two outcomes. A row
  trashed while its file was missing looks identical on disk to a row trashed
  before this module existed, and `discard/2` treats those two very
  differently - see its doc.

  Returns `{:error, reason}` when a file that is present could not be moved.
  The caller must not mark the row trashed in that case.
  """
  @spec store(MediaFile.t()) :: {:ok, {:moved, String.t()} | :missing} | {:error, term()}
  def store(%MediaFile{} = media_file) do
    case MediaFile.absolute_path(media_file) do
      nil ->
        {:ok, :missing}

      source ->
        if File.exists?(source) do
          do_store(media_file, source)
        else
          {:ok, :missing}
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
  clobbering it would be worse than leaving a copy in the trash. That case
  returns `{:ok, :trash_copy_retained}`, and the caller must keep the recorded
  trash path on the row: an untracked file under `.mydia-trash/<id>/` is one
  nothing can ever restore or purge.
  """
  @spec restore(MediaFile.t(), String.t() | nil) ::
          :ok | {:ok, :trash_copy_retained} | {:error, term()}
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
        Logger.error(
          "Restoring a media file whose library path is already occupied; leaving the trashed " <>
            "copy in place rather than overwriting what is there. The trashed copy stays " <>
            "referenced by the row so it remains recoverable, but nothing will delete it " <>
            "automatically - remove it by hand once you have decided which copy you want.",
          media_file_id: media_file.id,
          trashed_path: trash_path,
          path: destination
        )

        {:ok, :trash_copy_retained}

      true ->
        move_back(media_file, trash_path, destination)
    end
  end

  @doc """
  Permanently deletes the bytes behind a trashed row.

  Which bytes those are depends on how the row came to be trashed, and getting
  this wrong destroys libraries:

    * `{:moved, trash_path}` - the file is in the trash directory. Delete it,
      and the NFO sidecar left behind at the library path with it.
    * `:missing` - the row was trashed while its file was already gone from
      disk. **Nothing at the library path may be touched.** The dominant
      producer of these is `Mydia.Jobs.LibraryScanner`'s `deleted_files`
      batch, which marks every row in a library deleted when a network share
      is unmounted mid-scan. If the share comes back and no rescan runs - and
      the rescan that would restore those rows is opt-in per library path -
      deleting at the library path here would silently erase the entire
      library thirty days later.
    * `:legacy` - the row carries neither marker. Delete at the library path.
      This is the other half of
      [#295](https://github.com/getmydia/mydia/issues/295): the purge used to
      drop the row and leave the file on disk forever.

      It does **not** follow that the file is still there, and this clause
      must not be read as asserting it. Rows written before the markers
      existed are exactly the ones the `:missing` case above describes -
      predominantly unmount-shaped scan trashes, not deliberate deletes - and
      nothing at rest distinguishes them. That is why
      `20260731120000_mark_existing_trashed_files_as_missing.exs` stamps every
      pre-existing trashed row as `:missing` on upgrade, which leaves this
      clause reachable only for a row written by something that bypassed
      `Mydia.Library.trash_media_file/1` entirely. Nothing in this codebase
      does. Space reclamation therefore applies to files trashed after the
      upgrade, not to the backlog.

  The caller distinguishes `:missing` from `:legacy` by the marker
  `trash_media_file/1` records; they are indistinguishable from disk alone.

  ## Why the return value matters

  Returns `:ok` only when nothing is left on disk - either the bytes were
  deleted or there were none to delete. `{:error, reason}` means the file is
  still there (a permissions blip, a read-only mount, an I/O error).

  The caller must keep the row when this returns an error. Dropping it would
  orphan the bytes: a file under `.mydia-trash/<id>/` with no row pointing at
  it is one nothing can ever restore or purge, so the space is never reclaimed
  and no later run retries the delete. Keeping the row means the next purge
  tries again, which is right for exactly the transient failures that produce
  this.
  """
  @spec discard(MediaFile.t(), {:moved, String.t()} | :missing | :legacy) ::
          :ok | {:error, term()}
  def discard(%MediaFile{} = media_file, {:moved, trash_path}) when is_binary(trash_path) do
    result = delete_file(media_file, trash_path)
    prune_container(trash_path)

    # The NFO sidecar is never moved into the trash (the scanner does not index
    # it, so it cannot resurrect anything), but it must not outlive the media
    # file it describes. Only worth removing once the media file itself is
    # gone: on a failed delete the row survives and the file it describes is
    # still on disk.
    with :ok <- result do
      case MediaFile.absolute_path(media_file) do
        nil -> :ok
        library_path -> Mydia.Metadata.NfoWriter.delete_nfo_for_file(library_path)
      end

      :ok
    end
  end

  def discard(%MediaFile{} = media_file, :missing) do
    Logger.debug(
      "Purging a media file that was already missing from disk when it was trashed; " <>
        "leaving the library path untouched",
      media_file_id: media_file.id
    )

    :ok
  end

  def discard(%MediaFile{} = media_file, :legacy) do
    case MediaFile.absolute_path(media_file) do
      nil ->
        :ok

      library_path ->
        with :ok <- delete_file(media_file, library_path) do
          Mydia.Metadata.NfoWriter.delete_nfo_for_file(library_path)
          :ok
        end
    end
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
        default_root(path)
    end
  end

  def root_for(%MediaFile{}), do: nil

  # Sibling of the library path when that is actually usable, otherwise inside
  # the library path.
  #
  # The sibling is preferred because it is outside the library, so the scanner
  # never walks it even without the `.mydia-trash` skip. But it is only better
  # when it is on the same filesystem, which is what makes the move an atomic
  # rename instead of a copy of a 60 GB remux. Two cases where it is not:
  #
  #   * the library path is a mount root - `/media` or `/data`, both routine
  #     in Docker - so the parent is `/`, i.e. the container's writable layer.
  #     Different filesystem at best; on a read-only rootfs every trash fails
  #     outright and `finalize_upgrade/1` retries until Oban discards it.
  #   * the library path is a mount below a directory on another filesystem,
  #     e.g. a NAS share at `/mnt/media` with `/mnt` on the system disk.
  #
  # Falling inside the library keeps the same-filesystem guarantee, and the
  # scanner's `.mydia-trash` skip is what keeps it from being rescanned.
  defp default_root(path) do
    expanded = Path.expand(path)
    parent = Path.dirname(expanded)

    if usable_sibling?(expanded, parent) do
      Path.join(parent, @dir_name)
    else
      Path.join(expanded, @dir_name)
    end
  end

  defp usable_sibling?(expanded, parent) do
    parent != expanded and parent != "/" and same_filesystem?(expanded, parent)
  end

  # `File.Stat.major_device` is st_dev on Unix, so two paths sharing it share a
  # filesystem. An unreadable path answers "no", which lands on the safe
  # inside-the-library branch.
  defp same_filesystem?(a, b) do
    match?(
      {{:ok, %File.Stat{major_device: device}}, {:ok, %File.Stat{major_device: device}}},
      {File.stat(a), File.stat(b)}
    )
  end

  defp do_store(media_file, source) do
    destination = Path.join([root_for(media_file), media_file.id, Path.basename(source)])

    case move(source, destination) do
      :ok ->
        Logger.info("Moved a media file into the trash directory",
          media_file_id: media_file.id,
          from: source,
          to: destination
        )

        {:ok, {:moved, destination}}

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

    case File.cp(source, destination) do
      :ok ->
        remove_source_after_copy(source, destination)

      {:error, reason} ->
        # The copy failed part-way. The original is still in place, so drop
        # whatever reached the other side and report the move as failed rather
        # than leaving a truncated file in the trash.
        _ = File.rm(destination)
        {:error, {:cross_filesystem_move_failed, reason}}
    end
  end

  # Completes a cross-filesystem move by removing the source now that the copy
  # landed.
  #
  # Public only so the `:enoent` branch can be tested directly: forcing a real
  # cross-filesystem move needs a second mount, but this is the one function in
  # the trash path that can delete the copy that just succeeded.
  @doc false
  @spec remove_source_after_copy(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_source_after_copy(source, destination) do
    case File.rm(source) do
      :ok ->
        :ok

      # Something else removed the source while we were copying. The goal
      # state - bytes at the destination, nothing at the library path - has
      # been reached, so removing the destination here would destroy the only
      # copy left.
      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        # The original is still there, so we would otherwise be leaving two
        # copies and reporting success.
        _ = File.rm(destination)
        {:error, {:cross_filesystem_move_failed, reason}}
    end
  end

  # `:enoent` is success: the goal state is "no bytes at this path", and
  # something else having already removed them reaches it just as well.
  defp delete_file(media_file, path) do
    case File.rm(path) do
      :ok ->
        Logger.info("Permanently deleted a trashed media file",
          media_file_id: media_file.id,
          path: path
        )

        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Could not permanently delete a trashed media file; keeping its row so the next " <>
            "purge retries rather than orphaning the bytes",
          media_file_id: media_file.id,
          path: path,
          reason: inspect(reason)
        )

        {:error, reason}
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
