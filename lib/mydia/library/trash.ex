defmodule Mydia.Library.Trash do
  @moduledoc """
  Deleting, trashing, restoring and purging media files, including the trash
  state recorded on each row.
  """

  import Ecto.Query, warn: false
  import Mydia.QueryHelpers
  require Logger
  alias Mydia.Repo
  alias Mydia.Library.{MediaFile, MediaFiles, TrashStore}
  alias Mydia.Library.Structs.FileMetadata

  @doc """
  Deletes a media file record, optionally removing the file from disk.

  When `delete_files: true`, the database record is deleted first and only then
  is the physical file (and its NFO sidecar) removed from disk. This ordering is
  deliberate: if the record delete fails the disk is never touched, so nothing is
  lost; and a disk-removal failure after a successful record delete is reported
  via `{:ok, media_file, :file_delete_failed}` (an orphaned file is recoverable,
  an orphaned record pointing at a missing file is not). The file path is
  resolved from the in-memory struct, which is preloaded before the delete so it
  stays available afterwards.

  When `delete_files: false` (the default), only the database record is removed
  and the file is left on disk. This preserves the original arity-1 behavior for
  existing callers.
  """
  @spec delete_media_file(MediaFile.t(), keyword()) ::
          {:ok, MediaFile.t()}
          | {:ok, MediaFile.t(), :file_delete_failed}
          | {:error, Ecto.Changeset.t()}
          | {:error, Mydia.Storage.Error.t()}
  def delete_media_file(%MediaFile{} = media_file, opts \\ []) do
    delete_files = Keyword.get(opts, :delete_files, false)

    # Preload the path source before deleting the row so the file is still
    # resolvable from the in-memory struct after the record is gone.
    media_file =
      if delete_files, do: Repo.preload(media_file, :library_path), else: media_file

    case Repo.delete(media_file) do
      {:ok, deleted} when delete_files ->
        case delete_media_file_from_disk(media_file) do
          :ok -> {:ok, deleted}
          {:error, _reason} -> {:ok, deleted, :file_delete_failed}
        end

      {:ok, deleted} ->
        {:ok, deleted}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Moves a media file to trash: the file leaves the library path for the trash
  directory, and `trashed_at` is stamped on the row.

  Trashed files are excluded from all queries by default and are permanently
  deleted after the configured retention period (default 30 days).

  The file has to physically move, not just get a timestamp. Trashed rows are
  invisible to `list_media_files/1`, so a file left sitting on the library path
  is seen by the next scan as a *new* file, matched back to the trashed row by
  relative path, and restored - which silently reverted every automatic quality
  upgrade and resurrected every release rejected for lying about its contents.
  See `Mydia.Library.TrashStore` for where the trash lives and why.

  A file that is already gone from disk stays a normal outcome: that is the
  original reason this function exists (marking what a scan found missing).
  That case is recorded on the row as `"trashed_missing"`, which is what stops
  `TrashCleanup` from later deleting a file that has since come back at the
  library path - an unmounted share that a scan read as a deleted library, for
  instance. See `Mydia.Library.TrashStore.discard/2`.

  Returns `{:error, reason}` without touching the row when a file that *is*
  present could not be moved. A row marked trashed while its file sits in the
  library is precisely the inconsistency this move exists to remove, so the two
  are kept in step or neither changes.

  ## Options

  Passed straight through to `Mydia.Library.TrashStore.store/2`; see its docs.
  Notably `:move` (default `true`) - `move: false` refuses to move a file that
  is present on disk instead of trashing it, leaving the row untouched. The
  three re-scan functions in this module pass it: a file the diff called
  missing but that has since reappeared must never be moved out of the
  library.

    * `:reason` - why this file is being trashed, one of `:missing`,
      `:upgraded`, `:upgrade_rejected`, `:pruned` or `:manual`. Optional;
      omitting it leaves `trashed_reason` nil, which the trash page renders as
      "Unknown". Every caller in this codebase passes one.
  """
  @spec trash_media_file(MediaFile.t(), keyword()) ::
          {:ok, MediaFile.t()} | {:error, Ecto.Changeset.t()} | {:error, term()}
  # Besides the errors above, an S3 outage returns
  # `{:error, {:trash_move_failed, %Mydia.Storage.Error{}}}`.
  def trash_media_file(%MediaFile{} = media_file, opts \\ []) do
    media_file
    |> Repo.preload(:library_path)
    |> do_trash_media_file(opts)
  end

  defp do_trash_media_file(media_file, opts) do
    case TrashStore.store(media_file, opts) do
      {:ok, outcome} ->
        media_file
        |> Ecto.Changeset.change(
          trashed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          trashed_reason: Keyword.get(opts, :reason),
          metadata: put_trash_state(media_file.metadata, outcome)
        )
        |> Repo.update()
        |> case do
          {:ok, trashed} ->
            {:ok, trashed}

          {:error, changeset} ->
            # The bytes already moved but the row did not. Put them back
            # rather than leave an active row pointing at an empty path.
            _ = TrashStore.restore(media_file, moved_path(outcome))
            {:error, changeset}
        end

      {:error, reason} ->
        {:error, {:trash_move_failed, reason}}
    end
  end

  @doc """
  Restores a trashed media file: the file moves back to its library path and
  `trashed_at` is cleared.

  A trashed copy that is missing from the trash directory is not an error - the
  row is restored anyway, exactly as it was before trashing moved files at all.

  When the library path is already occupied the trashed copy is deliberately
  left where it is rather than clobbering what is there, and the row keeps
  pointing at it so those bytes stay reclaimable instead of becoming an
  untracked file under `.mydia-trash/`.

  The retained case returns `{:ok, media_file, :trash_copy_retained}` rather
  than a plain `{:ok, media_file}`, because a caller has to tell the operator
  that two copies now exist and only one of them is the library's. This
  mirrors `delete_media_file/2`, which already signals a partial success the
  same way.
  """
  @spec restore_media_file(MediaFile.t()) ::
          {:ok, MediaFile.t()}
          | {:ok, MediaFile.t(), :trash_copy_retained}
          | {:error, Ecto.Changeset.t()}
          | {:error, term()}
  def restore_media_file(%MediaFile{} = media_file) do
    media_file = Repo.preload(media_file, :library_path)

    case TrashStore.restore(media_file, trashed_path(media_file)) do
      :ok ->
        media_file
        |> Ecto.Changeset.change(
          trashed_at: nil,
          trashed_reason: nil,
          metadata: drop_trash_state(media_file.metadata)
        )
        |> Repo.update()

      {:ok, :trash_copy_retained} ->
        media_file
        |> Ecto.Changeset.change(trashed_at: nil, trashed_reason: nil)
        |> Repo.update()
        |> case do
          {:ok, restored} -> {:ok, restored, :trash_copy_retained}
          {:error, changeset} -> {:error, changeset}
        end

      {:error, reason} ->
        Logger.error("Could not restore a trashed media file",
          media_file_id: media_file.id,
          reason: inspect(reason)
        )

        {:error, {:trash_restore_failed, reason}}
    end
  end

  @doc """
  Permanently deletes all media files that have been trashed for longer than `days`,
  including the bytes behind them.

  Returns `{:ok, count}` with the number of permanently deleted files.

  Deleting from disk is the other half of
  [#295](https://github.com/getmydia/mydia/issues/295): the purge used to drop
  the row and leave the file forever, so trash retention never reclaimed any
  space.

  A row whose bytes could not be deleted is **kept**, and its count is not
  included in the return value. Dropping it would orphan the file: nothing
  points at a path under `.mydia-trash/<id>/` once its row is gone, so no
  later run would retry the delete and the space would never come back.
  Keeping the row means the next purge tries again, which is the right
  response to the transient failures that cause this - a read-only mount, a
  permissions blip, an I/O error. Rows whose file was already gone still
  purge normally; a missing file is a reached goal state, not a failure.
  """
  @spec purge_old_trashed_media_files(integer()) :: {:ok, non_neg_integer()}
  def purge_old_trashed_media_files(days \\ 30) do
    cutoff = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-days, :day)

    expired =
      from(f in MediaFile,
        where: not is_nil(f.trashed_at) and f.trashed_at <= ^cutoff,
        preload: :library_path
      )
      |> Repo.all()

    {discarded, retained} =
      Enum.split_with(expired, &(TrashStore.discard(&1, trash_state(&1)) == :ok))

    if retained != [] do
      Logger.warning(
        "Kept trashed media file rows whose bytes could not be deleted; the next purge will " <>
          "retry them. Dropping the rows would leave the files on disk with nothing tracking " <>
          "them.",
        count: length(retained),
        media_file_ids: Enum.map(retained, & &1.id)
      )
    end

    ids = Enum.map(discarded, & &1.id)

    {count, _} =
      from(f in MediaFile,
        where:
          f.id in ^ids and not is_nil(f.trashed_at) and
            f.trashed_at <= ^cutoff
      )
      |> Repo.delete_all()

    {:ok, count}
  end

  @doc """
  Lists trashed media files for the operator-facing trash page.

  Newest first, because the thing an operator wants to undo is almost always
  the thing that just happened.

  ## Options

    * `:reason` - restrict to one `trashed_reason`. `nil` (the default) returns
      every trashed row regardless of reason. To select rows whose reason is
      itself unknown, pass `:unknown`; a literal `nil` cannot mean both "no
      filter" and "filter to no reason".
    * `:limit`, `:offset` - pagination.
    * `:preload` - passed to `Mydia.QueryHelpers.maybe_preload/2`.
  """
  @spec list_trashed_media_files(keyword()) :: [MediaFile.t()]
  def list_trashed_media_files(opts \\ []) do
    MediaFile
    |> where([f], not is_nil(f.trashed_at))
    |> filter_by_trashed_reason(Keyword.get(opts, :reason))
    |> order_by([f], desc: f.trashed_at, desc: f.id)
    |> maybe_limit(Keyword.get(opts, :limit))
    |> maybe_offset(Keyword.get(opts, :offset))
    |> maybe_preload(opts[:preload])
    |> Repo.all()
  end

  defp filter_by_trashed_reason(query, nil), do: query

  defp filter_by_trashed_reason(query, :unknown),
    do: where(query, [f], is_nil(f.trashed_reason))

  defp filter_by_trashed_reason(query, reason) when is_atom(reason),
    do: where(query, [f], f.trashed_reason == ^reason)

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, n) when is_integer(n), do: limit(query, ^n)

  defp maybe_offset(query, nil), do: query
  defp maybe_offset(query, n) when is_integer(n), do: offset(query, ^n)

  @doc """
  Counts trashed media files grouped by reason, for the filter chips.

  The map is keyed by the `trashed_reason` atom, with `nil` holding rows
  trashed before the column existed. A reason with no rows is absent from the
  map rather than present with a zero.
  """
  @spec count_trashed_media_files() :: %{optional(atom()) => non_neg_integer()}
  def count_trashed_media_files do
    MediaFile
    |> where([f], not is_nil(f.trashed_at))
    |> group_by([f], f.trashed_reason)
    |> select([f], {f.trashed_reason, count(f.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Count and total bytes of everything in the trash.

  One aggregate over `media_files`, with no filesystem access at all: this
  runs on every render of the trash page, and a disconnected NAS mount must
  not be able to hang it. Bytes nothing accounts for are a separate,
  operator-triggered concern; see `Mydia.Library.TrashStore.audit/0`.
  """
  @spec trashed_summary() :: %{count: non_neg_integer(), bytes: non_neg_integer()}
  def trashed_summary do
    {count, bytes} =
      MediaFile
      |> where([f], not is_nil(f.trashed_at))
      |> select([f], {count(f.id), sum(f.size)})
      |> Repo.one()

    %{count: count || 0, bytes: MediaFiles.to_integer(bytes)}
  end

  @doc """
  Permanently deletes one trashed media file: its bytes and then its row.

  The same pair `purge_old_trashed_media_files/1` runs, for a single row the
  operator picked by hand. `TrashStore.discard/2` decides what may be deleted
  from the trash state recorded on the row, which is why this must never do
  its own `File.rm/1`: a row trashed while its file was already missing may
  have a live file at its library path today.

  Returns `{:error, :not_trashed}` rather than deleting an active row.
  """
  @spec purge_media_file(MediaFile.t()) :: :ok | {:error, term()}
  def purge_media_file(%MediaFile{trashed_at: nil}), do: {:error, :not_trashed}

  def purge_media_file(%MediaFile{} = media_file) do
    media_file = Repo.preload(media_file, :library_path)

    with :ok <- TrashStore.discard(media_file, trash_state(media_file)) do
      delete_if_still_trashed(media_file)
    end
  end

  # The clause above only sees the `trashed_at` the struct was loaded with,
  # and `Repo.delete/1` matches on the primary key alone, so a restore that
  # landed in between - another tab, another operator - would have its now
  # active row deleted out from under it. Deleting under the same
  # `trashed_at IS NOT NULL` guard `purge_old_trashed_media_files/1` already
  # uses makes losing that race a refusal instead.
  defp delete_if_still_trashed(%MediaFile{id: id}) do
    from(f in MediaFile, where: f.id == ^id and not is_nil(f.trashed_at))
    |> Repo.delete_all()
    |> case do
      {1, _} -> :ok
      {0, _} -> {:error, :not_trashed}
    end
  end

  @doc """
  Fetches one trashed media file by id, or nil.

  Returns nil for an active row as well as a missing one: every caller is a
  trash page action, and acting on a row somebody restored in another tab is
  exactly the case this must refuse.
  """
  @spec get_trashed_media_file(binary(), keyword()) :: MediaFile.t() | nil
  def get_trashed_media_file(id, opts \\ []) do
    MediaFile
    |> where([f], f.id == ^id and not is_nil(f.trashed_at))
    |> maybe_preload(opts[:preload])
    |> Repo.one()
  end

  # How a row came to be trashed, recorded on the row itself. Three states,
  # and `TrashStore.discard/2` treats all three differently:
  #
  #   * "trashed_path" - the bytes were moved there. Recorded rather than
  #     recomputed so restore and purge do not depend on the trash directory
  #     configuration still resolving the same way later.
  #   * "trashed_missing" - there was nothing on disk to move. Critically,
  #     this is *not* the same as a legacy row even though both leave
  #     "trashed_path" unset: the file may well be present at the library
  #     path now (an unmounted share that came back), and deleting it there
  #     would be silent data loss. See TrashStore.discard/2.
  #   * neither key - a row trashed before TrashStore existed. Its file is
  #     still at the library path and the purge deletes it there (#295).
  defp trash_state(%MediaFile{} = media_file) do
    cond do
      path = trashed_path(media_file) -> {:moved, path}
      trashed_missing?(media_file) -> :missing
      true -> :legacy
    end
  end

  defp trashed_path(%MediaFile{metadata: %FileMetadata{extra: extra}}) when is_map(extra) do
    case extra["trashed_path"] do
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  defp trashed_path(%MediaFile{}), do: nil

  defp trashed_missing?(%MediaFile{metadata: %FileMetadata{extra: extra}}) when is_map(extra),
    do: extra["trashed_missing"] == true

  defp trashed_missing?(%MediaFile{}), do: false

  defp moved_path({:moved, path}), do: path
  defp moved_path(:missing), do: nil

  defp put_trash_state(metadata, {:moved, path}) when is_binary(path) do
    metadata
    |> drop_trash_state()
    |> then(&%{&1 | extra: Map.put(&1.extra, "trashed_path", path)})
  end

  defp put_trash_state(metadata, :missing) do
    metadata
    |> drop_trash_state()
    |> then(&%{&1 | extra: Map.put(&1.extra, "trashed_missing", true)})
  end

  defp drop_trash_state(nil), do: FileMetadata.empty()

  defp drop_trash_state(%FileMetadata{} = metadata) do
    extra =
      (metadata.extra || %{})
      |> Map.delete("trashed_path")
      |> Map.delete("trashed_missing")

    %{metadata | extra: extra}
  end

  @doc """
  Deletes the physical file from disk for a media file record.

  Returns `:ok` if the file was successfully deleted or doesn't exist,
  `{:error, reason}` if deletion failed.

  This function should be called before deleting the database record
  to ensure the file path is available.

  The library_path association must be preloaded.
  """
  @spec delete_media_file_from_disk(MediaFile.t()) :: :ok | {:error, term()}
  def delete_media_file_from_disk(%MediaFile{} = media_file) do
    media_file = Repo.preload(media_file, :library_path)

    case MediaFile.storage_path(media_file) do
      nil ->
        Logger.error("Cannot delete media file from disk - path could not be resolved",
          media_file_id: media_file.id
        )

        {:error, :path_not_resolved}

      path ->
        delete_path_from_disk(path)
    end
  end

  @doc """
  Deletes one file and its NFO sidecar from disk by absolute path.

  Returns `:ok` when the file was removed or was already absent, and
  `{:error, reason}` when a file that is present could not be removed. A
  sidecar that cannot be removed is logged by
  `Mydia.Metadata.NfoWriter.delete_nfo_for_file/1` and does not fail the call.

  Import candidates have no `MediaFile` to resolve a path from, which is why
  this takes the path itself.
  """
  @spec delete_path_from_disk(String.t()) :: :ok | {:error, term()}
  # `File.rm/1` is called directly rather than behind a `File.exists?/1` check,
  # so a file removed by someone else between the two is still an absent file
  # (`:enoent`) and not a failure. The sidecar is left alone in that case: this
  # call removed nothing, and a same-named `.nfo` can belong to another copy of
  # the episode (`Episode.mp4` beside a vanished `Episode.mkv`).
  def delete_path_from_disk("s3://" <> _ = path) do
    with {:ok, source} <- Mydia.Storage.at(path) do
      case Mydia.Storage.stat(source) do
        # Removed nothing, so the sidecar is left alone, as for a local :enoent.
        {:error, %Mydia.Storage.Error{kind: :not_found}} ->
          Logger.debug("Media file already doesn't exist in storage", path: path)
          :ok

        {:error, _} = error ->
          error

        {:ok, _} ->
          with :ok <- Mydia.Storage.delete(source) do
            Logger.info("Deleted media file from storage", path: path)
            Mydia.Metadata.NfoWriter.delete_nfo_for_file(path)
            :ok
          end
      end
    end
  end

  def delete_path_from_disk(absolute_path) when is_binary(absolute_path) do
    case File.rm(absolute_path) do
      :ok ->
        Logger.info("Deleted media file from disk", path: absolute_path)
        Mydia.Metadata.NfoWriter.delete_nfo_for_file(absolute_path)
        :ok

      {:error, :enoent} ->
        Logger.debug("Media file already doesn't exist on disk", path: absolute_path)
        :ok

      {:error, reason} ->
        Logger.error("Failed to delete media file from disk",
          path: absolute_path,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end
end
