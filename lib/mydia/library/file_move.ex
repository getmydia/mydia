defmodule Mydia.Library.FileMove do
  @moduledoc """
  Moves one media file to a new place without ever leaving its row pointing
  at a file that is not there.

  Ecto has no filesystem transaction, so a move is three steps a caller runs
  in order, stopping at the first error:

    1. `place/3` copies or hardlinks the file to the destination (never
       renames it), so the source survives until the row has moved.
    2. `relink/5` re-reads the row in a transaction, aborts if it was trashed
       or moved meanwhile, adopts any duplicate row a concurrent scan created
       at the destination, and points the row at the new place.
    3. `cleanup_source/2` deletes the source, only after that commit.

  Used by `Mydia.Jobs.MediaRematch` and `Mydia.Jobs.LibraryMove`.
  """

  alias Mydia.Library
  alias Mydia.Library.FileOrganizer
  alias Mydia.Library.MediaFile
  alias Mydia.Repo
  alias Mydia.Settings.LibraryPath

  @type place_result :: {:ok, :hardlink | :move | :copy | :skip | :exists} | {:error, term()}

  @doc """
  Places the file at `dest_path` inside `target`. `media_file` needs its
  `:library_path` preloaded.

  Returns `{:error, :source_missing}` when neither path exists and
  `{:error, :conflict}` when `dest_path` exists but no row claims it. A file
  this function did not place is never removed or overwritten.
  """
  @spec place(MediaFile.t(), String.t(), LibraryPath.t()) :: place_result()
  def place(%MediaFile{} = media_file, dest_path, %LibraryPath{} = target) do
    source_path = MediaFile.storage_path(media_file)

    cond do
      is_nil(source_path) -> {:error, :no_source_path}
      not exists?(source_path) and not exists?(dest_path) -> {:error, :source_missing}
      untracked_destination?(source_path, dest_path, target) -> {:error, :conflict}
      true -> place_file(source_path, dest_path, target, media_file.size)
    end
  end

  # fallback: :copy (never rename) keeps the source until after the commit.
  defp place_file(source_path, dest_path, target, size) do
    FileOrganizer.place_file(source_path, dest_path,
      use_hardlinks: true,
      fallback: :copy,
      confine_to: target.path,
      expected_size: size
    )
  end

  # A destination that exists is ours to replace only when a row claims it:
  # this file's own (a retry), or a duplicate a scan created there, which
  # relink/5 adopts. Anything else belongs to someone, and is never touched.
  defp untracked_destination?(source_path, dest_path, target) do
    dest_path != source_path and exists?(dest_path) and
      is_nil(
        Library.get_media_file_by_relative_path(
          target.id,
          Path.relative_to(dest_path, target.path),
          include_trashed: true
        )
      )
  end

  @doc """
  Points the row at `new_rel` in `target` inside one transaction.

  Aborts with `:media_file_gone`, `:media_file_trashed` or `:media_file_moved`
  when the row changed since `snapshot` was read. `extra_attrs` is merged into
  the update; `after_update` runs in the transaction and rolls it back on
  `{:error, reason}`.
  """
  @spec relink(
          MediaFile.t(),
          LibraryPath.t(),
          String.t(),
          map(),
          (MediaFile.t() -> {:ok, term()} | {:error, term()})
        ) :: {:ok, MediaFile.t()} | {:error, term()}
  def relink(%MediaFile{} = snapshot, %LibraryPath{} = target, new_rel, extra_attrs, after_update) do
    Repo.transaction(fn ->
      current = Repo.get(MediaFile, snapshot.id)

      cond do
        is_nil(current) -> Repo.rollback(:media_file_gone)
        not is_nil(current.trashed_at) -> Repo.rollback(:media_file_trashed)
        drifted?(current, snapshot) -> Repo.rollback(:media_file_moved)
        true -> apply_relink(current, target, new_rel, extra_attrs, after_update)
      end
    end)
  end

  defp drifted?(current, snapshot) do
    current.relative_path != snapshot.relative_path or
      current.library_path_id != snapshot.library_path_id
  end

  defp apply_relink(current, target, new_rel, extra_attrs, after_update) do
    # A racing scan may have created a row at the destination path; adopt it
    # (delete the duplicate) so we do not leave two rows for one file.
    adopt_destination_duplicate(target.id, new_rel, current.id)
    attrs = Map.merge(%{relative_path: new_rel, library_path_id: target.id}, extra_attrs)

    with {:ok, updated} <- update_row(current, attrs),
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

  defp adopt_destination_duplicate(library_path_id, relative_path, keep_id) do
    case Library.get_media_file_by_relative_path(library_path_id, relative_path,
           include_trashed: true
         ) do
      %MediaFile{id: ^keep_id} -> :ok
      %MediaFile{} = duplicate -> Repo.delete(duplicate)
      nil -> :ok
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
