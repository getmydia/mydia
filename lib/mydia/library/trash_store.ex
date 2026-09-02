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

  import Ecto.Query

  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Repo

  @dir_name ".mydia-trash"

  # A container younger than this might be a trash still in flight:
  # `trash_media_file/2` moves the bytes before it stamps `trashed_at`, so
  # there is a window where a perfectly healthy trash looks exactly like an
  # orphan. An hour is far longer than any single rename(2), and a genuinely
  # orphaned container is not going anywhere.
  @sweep_min_age_seconds 3600

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

  ## Options

    * `:move` - defaults to `true`. With `move: false`, a present file is
      never touched: `do_store/2` (the actual `File.rename/2`/`File.cp/2`)
      is never called, and the function returns `{:error, :file_present}`
      instead. An absent file still returns `{:ok, :missing}`, exactly as
      with the default.

      This exists for callers that only ever want to record a file as
      missing, never move bytes - a re-scan's "this row's file is gone"
      path, in particular. `Library.reject_files_still_on_disk/1` already
      checks `File.exists?` before a re-scan calls this, but that check and
      this one happen at different times; a file that reappears on disk in
      between (a reconnecting mount, a concurrent import) must not be moved
      into the trash out from under whatever put it there. `move: false`
      makes that structurally impossible rather than merely unlikely: there
      is no code path from "file present" to a move.
  """
  @spec store(MediaFile.t(), keyword()) ::
          {:ok, {:moved, String.t()} | :missing} | {:error, term()}
  def store(%MediaFile{} = media_file, opts \\ []) do
    move? = Keyword.get(opts, :move, true)

    case MediaFile.absolute_path(media_file) do
      nil ->
        {:ok, :missing}

      source ->
        cond do
          not File.exists?(source) -> {:ok, :missing}
          move? -> do_store(media_file, source)
          true -> {:error, :file_present}
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

  @doc """
  Reports trash containers that nothing will ever purge on its own.

  Every `<root>/<id>` directory falls into one of three states:

    * **tracked** - a row with that id has `trashed_at` set and its recorded
      trashed path lies in this container, so `Mydia.Jobs.TrashCleanup` will
      purge it on schedule. Not reported. A trashed row whose recorded path
      lies in a *different* container is orphaned instead: the purge deletes
      the recorded path, never `<root>/<id>`, so this container would survive
      it. A trashed row with no recorded path at all stays tracked, because
      the bytes move before `trashed_at` is stamped and sweeping a trash still
      in flight would delete a file inside its retention window.
    * **retained** - the row exists and is *not* trashed, but still carries
      `metadata.extra["trashed_path"]` pointing into this container. This is
      `restore/2` refusing to clobber an occupied library path: it keeps the
      trashed copy and logs "remove it by hand". Nothing else ever will.
    * **orphaned** - no row with that id at all, or a row that neither is
      trashed nor points here. Debris from a failed purge, a deleted row, or
      an operator moving things around.

  Walks the filesystem, so it is called from a `Task` on operator demand
  rather than on a render path: a disconnected NAS mount would otherwise hang
  the page.
  """
  @spec audit() :: %{retained: [map()], orphaned: [map()]}
  def audit do
    containers = Enum.flat_map(roots(), &containers_in/1)
    ids = Enum.map(containers, & &1.id)

    rows =
      from(f in MediaFile, where: f.id in ^ids, select: {f.id, f.trashed_at, f.metadata})
      |> Repo.all()
      |> Map.new(fn {id, trashed_at, metadata} -> {id, {trashed_at, metadata}} end)

    containers
    |> Enum.reduce(%{retained: [], orphaned: []}, fn container, acc ->
      case classify(container, Map.get(rows, container.id)) do
        :tracked ->
          acc

        state when state in [:retained, :orphaned] ->
          entry = %{
            path: container.path,
            media_file_id: if(state == :retained, do: container.id, else: nil),
            bytes: container.bytes
          }

          Map.update!(acc, state, &[entry | &1])
      end
    end)
    |> Map.new(fn {k, v} -> {k, Enum.reverse(v)} end)
  end

  # No row: debris. Row with trashed_at: TrashCleanup owns it, but only the
  # container its recorded path points into - purging deletes that path, not
  # `<root>/<id>`, so a trashed row pointing at a different container leaves
  # this one behind forever. Row without trashed_at, but still pointing here:
  # restore/2 kept the copy deliberately.
  defp classify(_container, nil), do: :orphaned

  defp classify(container, {%DateTime{}, metadata}) do
    case trashed_path_in(metadata) do
      # Deliberately asymmetric with the untrashed clause below. A trashed row
      # with no recorded path is a row mid-trash (the bytes move before
      # `trashed_at` is stamped) or one trashed before the path was recorded,
      # and calling either orphaned would offer the operator a Sweep button
      # that permanently deletes files still inside their retention window.
      # Leaving unpurgeable bytes on disk is the cheaper mistake.
      path when is_binary(path) ->
        if Path.dirname(path) == container.path, do: :tracked, else: :orphaned

      _ ->
        :tracked
    end
  end

  defp classify(container, {nil, metadata}) do
    case trashed_path_in(metadata) do
      path when is_binary(path) ->
        if Path.dirname(path) == container.path, do: :retained, else: :orphaned

      _ ->
        :orphaned
    end
  end

  defp trashed_path_in(%FileMetadata{extra: extra}) when is_map(extra),
    do: extra["trashed_path"]

  defp trashed_path_in(_), do: nil

  # Every distinct trash root across all library paths. A single configured
  # MYDIA_TRASH_DIR collapses to one; the default puts one beside each
  # library path, and two libraries on the same mount share theirs.
  defp roots do
    case Application.get_env(:mydia, :trash_dir) do
      configured when is_binary(configured) and configured != "" ->
        [configured]

      _ ->
        from(lp in Mydia.Settings.LibraryPath, select: lp.path)
        |> Repo.all()
        |> Enum.map(&default_root/1)
        |> Enum.uniq()
    end
  end

  defp containers_in(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.map(fn path ->
          %{id: Path.basename(path), path: path, bytes: bytes_in(path)}
        end)

      # A root that does not exist yet is the normal state of a fresh install,
      # not an error. An unreadable one is logged and skipped rather than
      # crashing an operator-triggered audit.
      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("Could not list a trash root during audit",
          root: root,
          reason: inspect(reason)
        )

        []
    end
  end

  defp bytes_in(path) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(path, &1))
        |> Enum.map(fn entry ->
          case File.stat(entry) do
            {:ok, %{size: size, type: :regular}} -> size
            _ -> 0
          end
        end)
        |> Enum.sum()

      _ ->
        0
    end
  end

  @doc """
  Permanently deletes the containers `audit/0` returned.

  Takes entries rather than re-deriving them, so the operator deletes exactly
  what they were shown. Containers younger than an hour are skipped: see
  `@sweep_min_age_seconds`.
  """
  @spec sweep([map()]) :: %{
          swept: non_neg_integer(),
          bytes: non_neg_integer(),
          skipped: non_neg_integer()
        }
  def sweep(entries) when is_list(entries) do
    cutoff = System.os_time(:second) - @sweep_min_age_seconds

    Enum.reduce(entries, %{swept: 0, bytes: 0, skipped: 0}, fn entry, acc ->
      if old_enough?(entry.path, cutoff) do
        case File.rm_rf(entry.path) do
          {:ok, _} ->
            %{acc | swept: acc.swept + 1, bytes: acc.bytes + entry.bytes}

          {:error, reason, _} ->
            Logger.error("Could not sweep a trash container",
              path: entry.path,
              reason: inspect(reason)
            )

            %{acc | skipped: acc.skipped + 1}
        end
      else
        %{acc | skipped: acc.skipped + 1}
      end
    end)
  end

  defp old_enough?(path, cutoff) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime <= cutoff
      _ -> false
    end
  end
end
