defmodule Mydia.Library.FileMove do
  @moduledoc """
  Moves one media file to a new place without ever leaving its row pointing
  at a file that is not there.

  Ecto has no filesystem transaction, so a move is three steps a caller runs
  in order, stopping at the first error:

    1. `place/3` copies or hardlinks the file to the destination (never
       renames it), so the source survives until the row has moved.
    2. `relink/6` re-reads the row in a transaction, aborts if it was trashed
       or moved meanwhile, adopts any duplicate row a concurrent scan created
       at the destination, and points the row at the new place.
    3. `cleanup_source/2` deletes the source, only after that commit.

  Used by `Mydia.Jobs.MediaRematch` and `Mydia.Jobs.LibraryMove`.
  """

  import Ecto.Query, only: [from: 2]

  alias Mydia.Library
  alias Mydia.Library.FileOrganizer
  alias Mydia.Library.MediaFile
  alias Mydia.Repo
  alias Mydia.Settings.LibraryPath

  @chunk 65_536
  # One ranged GET per chunk on S3.
  @stored_chunk 8 * 1024 * 1024

  @type place_result :: {:ok, :hardlink | :move | :copy | :skip | :exists} | {:error, term()}

  @doc """
  Places the file at `dest_path` inside `target`. `media_file` needs its
  `:library_path` preloaded. `opts` may carry `use_hardlinks: false` to force
  a copy.

  Returns `{:error, :source_missing}` when neither path exists,
  `{:error, {:path_escape, dest_path}}` when `dest_path` is outside `target`,
  and `{:error, :conflict}` when `dest_path` holds a file that is not ours.

  `{:ok, :exists}` means the destination already held our bytes (a link or
  copy left by an earlier failed attempt), so a retry after a failed
  `relink/6` succeeds. A file this function did not place is never removed
  or overwritten.
  """
  @spec place(MediaFile.t(), String.t(), LibraryPath.t(), keyword()) :: place_result()
  def place(%MediaFile{} = media_file, dest_path, %LibraryPath{} = target, opts \\ []) do
    source_path = MediaFile.storage_path(media_file)

    cond do
      is_nil(source_path) ->
        {:error, :no_source_path}

      not exists?(source_path) and not exists?(dest_path) ->
        {:error, :source_missing}

      true ->
        with :ok <- FileOrganizer.confine(dest_path, target.path) do
          place_checked(source_path, dest_path, target, media_file.size, opts)
        end
    end
  end

  # Ownership rules. An existing local destination is ours only when it is
  # the same file as the source (same device and inode: a hardlink we made in
  # an attempt whose relink then failed) or a byte-identical copy of a source
  # that still exists (a copy we finished before relink failed).
  #
  # Anything else belongs to someone, even when a row of this same item claims
  # it (an item can hold two files at one relative path in two libraries), and
  # is a conflict. A size match alone is never enough. Local copies are
  # published atomically (see FileOrganizer), so a truncated partial is never
  # at the destination, and FileOrganizer is never handed :expected_size for a
  # local path: that option deletes a destination of another size.
  #
  # S3 is left to FileOrganizer.place_via_storage: an object only appears once
  # complete, and one of a different size is refused as :destination_exists.
  # One of the same size is ours only when its bytes match the source's.
  defp place_checked(source_path, dest_path, target, size, opts) do
    cond do
      dest_path == source_path ->
        {:ok, :skip}

      Mydia.Storage.s3?(dest_path) or Mydia.Storage.s3?(source_path) ->
        place_stored(source_path, dest_path, target, [expected_size: size] ++ opts)

      not File.exists?(dest_path) ->
        place_file(source_path, dest_path, target, opts)

      ours?(source_path, dest_path) ->
        {:ok, :exists}

      true ->
        {:error, :conflict}
    end
  end

  # fallback: :copy (never rename) keeps the source until after the commit.
  defp place_file(source_path, dest_path, target, opts) do
    FileOrganizer.place_file(
      source_path,
      dest_path,
      [
        use_hardlinks: Keyword.get(opts, :use_hardlinks, true),
        fallback: :copy,
        confine_to: target.path
      ] ++ Keyword.take(opts, [:expected_size])
    )
  end

  defp place_stored(source_path, dest_path, target, opts) do
    case place_file(source_path, dest_path, target, opts) do
      {:ok, :exists} ->
        if identical_copy?(source_path, dest_path), do: {:ok, :exists}, else: {:error, :conflict}

      other ->
        other
    end
  end

  defp ours?(source_path, dest_path),
    do: same_file?(source_path, dest_path) or identical_copy?(source_path, dest_path)

  @doc """
  True when a media file row, trashed or not, sits at `relative_path` in the
  library `library_path_id`. `except_id` leaves one row out (the caller's own).
  """
  @spec claimed?(binary(), String.t(), binary() | nil) :: boolean()
  def claimed?(library_path_id, relative_path, except_id \\ nil) do
    query =
      from(f in MediaFile,
        where: f.library_path_id == ^library_path_id and f.relative_path == ^relative_path
      )

    query = if except_id, do: from(f in query, where: f.id != ^except_id), else: query
    Repo.exists?(query)
  end

  @doc "True when both local paths are the same file (device and inode): a hardlink."
  @spec same_file?(String.t(), String.t()) :: boolean()
  def same_file?(source_path, dest_path) do
    with {:ok, a} <- File.stat(source_path),
         {:ok, b} <- File.stat(dest_path) do
      a.inode == b.inode and a.major_device == b.major_device and
        a.minor_device == b.minor_device
    else
      _ -> false
    end
  end

  @doc """
  True when both paths exist with the same size and bytes. Read in chunks;
  meant for rare retry and cleanup paths. An `s3://` path is read through
  `Mydia.Storage`, so this downloads the object: never call it per file on a
  hot path.
  """
  @spec identical_copy?(String.t(), String.t()) :: boolean()
  def identical_copy?(source_path, dest_path),
    do: compare_copy(source_path, dest_path) == :same

  @doc """
  `identical_copy?/2` that tells a difference from a failure: `:same`,
  `:different` (a size or byte mismatch, or a path that is not there), or
  `{:error, reason}` when storage could not be read, so a caller can retry
  instead of deciding.
  """
  @spec compare_copy(String.t(), String.t()) :: :same | :different | {:error, term()}
  def compare_copy(source_path, dest_path) do
    if Mydia.Storage.s3?(source_path) or Mydia.Storage.s3?(dest_path),
      do: compare_stored(source_path, dest_path),
      else: compare_local(source_path, dest_path)
  end

  defp compare_local(source_path, dest_path) do
    with {:ok, a} <- File.stat(source_path),
         {:ok, b} <- File.stat(dest_path),
         true <- a.size == b.size,
         true <-
           Enum.zip(File.stream!(source_path, @chunk), File.stream!(dest_path, @chunk))
           |> Enum.all?(fn {x, y} -> x == y end) do
      :same
    else
      _ -> :different
    end
  end

  defp compare_stored(source_path, dest_path) do
    with {:ok, a} <- Mydia.Storage.at(source_path),
         {:ok, b} <- Mydia.Storage.at(dest_path),
         {:ok, %{size: size}} <- Mydia.Storage.stat(a),
         {:ok, %{size: ^size}} <- Mydia.Storage.stat(b) do
      same_ranges(a, b, 0, size)
    else
      {:ok, %{size: _other}} -> :different
      {:error, %Mydia.Storage.Error{kind: :not_found}} -> :different
      {:error, reason} -> {:error, reason}
    end
  end

  defp same_ranges(_a, _b, offset, size) when offset >= size, do: :same

  defp same_ranges(a, b, offset, size) do
    length = min(@stored_chunk, size - offset)

    case {Mydia.Storage.read_range(a, offset, length),
          Mydia.Storage.read_range(b, offset, length)} do
      {{:ok, same}, {:ok, same}} -> same_ranges(a, b, offset + length, size)
      {{:ok, _}, {:ok, _}} -> :different
      {{:error, reason}, _} -> {:error, reason}
      {_, {:error, reason}} -> {:error, reason}
    end
  end

  @doc """
  Points the row at `new_rel` in `target` inside one transaction.

  Aborts with `:media_file_gone`, `:media_file_trashed` or `:media_file_moved`
  when the row changed since `snapshot` was read. `extra_attrs` is merged into
  the update; `after_update` runs in the transaction and rolls it back on
  `{:error, reason}`.

  Call it only after `place/4` succeeded, and pass what it returned as
  `placed`. Another row at the destination is deleted as a duplicate of our
  bytes when `placed` says this attempt created the file there (a scan that
  raced the copy registered it). When the destination already held the bytes
  (`:exists`, `:skip`, or `nil`), a row there belonging to another item or
  episode is that item's record, and the relink aborts with `:conflict`.
  """
  @spec relink(
          MediaFile.t(),
          LibraryPath.t(),
          String.t(),
          map(),
          (MediaFile.t() -> {:ok, term()} | {:error, term()}),
          atom() | nil
        ) :: {:ok, MediaFile.t()} | {:error, term()}
  def relink(
        %MediaFile{} = snapshot,
        %LibraryPath{} = target,
        new_rel,
        extra_attrs,
        after_update,
        placed \\ nil
      ) do
    Repo.transaction(fn ->
      current = Repo.get(MediaFile, snapshot.id)

      cond do
        is_nil(current) -> Repo.rollback(:media_file_gone)
        not is_nil(current.trashed_at) -> Repo.rollback(:media_file_trashed)
        drifted?(current, snapshot) -> Repo.rollback(:media_file_moved)
        true -> apply_relink(current, target, new_rel, {extra_attrs, placed}, after_update)
      end
    end)
  end

  defp drifted?(current, snapshot) do
    current.relative_path != snapshot.relative_path or
      current.library_path_id != snapshot.library_path_id
  end

  defp apply_relink(current, target, new_rel, {extra_attrs, placed}, after_update) do
    attrs = Map.merge(%{relative_path: new_rel, library_path_id: target.id}, extra_attrs)

    with :ok <- adopt_destination_duplicate(target.id, new_rel, current, attrs, placed),
         {:ok, updated} <- update_row(current, attrs),
         {:ok, _} <- after_update.(updated) do
      updated
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_row(current, attrs) do
    case Library.update_media_file(current, attrs) do
      {:ok, _} = ok -> ok
      {:error, changeset} -> {:error, {:relink_failed, changeset}}
    end
  end

  @fresh_placements [:hardlink, :copy, :move]

  # A racing scan may have created a row at the destination path; adopt it
  # (delete the duplicate) so we do not leave two rows for one file. Only a
  # row that can describe nothing but our bytes is deleted: one registered
  # after this attempt created the file, or one with our own parent.
  # LibraryMove.plan/2 already skips a destination any other row claims, so
  # for a library move this only meets a row a scan created mid-move;
  # MediaRematch keeps its historical adopt-any rule for fresh placements.
  defp adopt_destination_duplicate(library_path_id, relative_path, current, attrs, placed) do
    case Library.get_media_file_by_relative_path(library_path_id, relative_path,
           include_trashed: true
         ) do
      nil ->
        :ok

      %MediaFile{id: id} when id == current.id ->
        :ok

      duplicate ->
        if placed in @fresh_placements or same_parent?(duplicate, current, attrs),
          do: delete_duplicate(duplicate),
          else: {:error, :conflict}
    end
  end

  defp same_parent?(duplicate, current, attrs) do
    episode_id = Map.get(attrs, :episode_id, current.episode_id)
    media_item_id = Map.get(attrs, :media_item_id, current.media_item_id)

    if episode_id,
      do: duplicate.episode_id == episode_id,
      else: is_nil(duplicate.episode_id) and duplicate.media_item_id == media_item_id
  end

  defp delete_duplicate(duplicate) do
    case Repo.delete(duplicate) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Deletes `source_path` after a committed relink. On S3 the delete is
  idempotent (a missing object is `:ok`), so it is never gated on an
  existence check: an outage there would skip the delete silently.
  """
  @spec cleanup_source(String.t() | nil, String.t()) :: :ok | {:error, term()}
  def cleanup_source(nil, _dest_path), do: :ok
  def cleanup_source(same, same), do: :ok

  def cleanup_source(source_path, _dest_path) do
    if Mydia.Storage.s3?(source_path) or File.exists?(source_path),
      do: remove(source_path),
      else: :ok
  end

  defp remove("s3://" <> _ = path), do: Mydia.Storage.delete_path(path)
  defp remove(path), do: File.rm(path)

  @spec exists?(String.t()) :: boolean()
  def exists?("s3://" <> _ = path), do: Mydia.Storage.path_exists?(path)
  def exists?(path), do: File.exists?(path)
end
