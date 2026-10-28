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

  import Ecto.Query, only: [from: 2]

  alias Mydia.Library
  alias Mydia.Library.FileOrganizer
  alias Mydia.Library.MediaFile
  alias Mydia.Repo
  alias Mydia.Settings.LibraryPath

  @chunk 65_536

  @type place_result :: {:ok, :hardlink | :move | :copy | :skip | :exists} | {:error, term()}

  @doc """
  Places the file at `dest_path` inside `target`. `media_file` needs its
  `:library_path` preloaded. `opts` may carry `use_hardlinks: false` to force
  a copy.

  Returns `{:error, :source_missing}` when neither path exists,
  `{:error, {:path_escape, dest_path}}` when `dest_path` is outside `target`,
  and `{:error, :conflict}` when `dest_path` holds a file that is not ours.

  A copy left by an earlier failed attempt is adopted (see the ownership rules
  below), so a retry after a failed `relink/5` succeeds. A file this function
  did not place is never removed or overwritten.
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
        with :ok <- FileOrganizer.confine(dest_path, target.path),
             false <- foreign_destination?(source_path, dest_path, target) do
          place_file(source_path, dest_path, target, media_file.size, opts)
        else
          true -> {:error, :conflict}
          {:error, _} = error -> error
        end
    end
  end

  # fallback: :copy (never rename) keeps the source until after the commit.
  defp place_file(source_path, dest_path, target, size, opts) do
    FileOrganizer.place_file(source_path, dest_path,
      use_hardlinks: Keyword.get(opts, :use_hardlinks, true),
      fallback: :copy,
      confine_to: target.path,
      expected_size: size
    )
  end

  # Ownership rules. An existing destination is ours, and place_file may
  # adopt or replace it, when any of these holds:
  #
  #   * a row claims it (trashed or not): this file's own (a retry), or a
  #     duplicate a scan created there, which relink/5 adopts;
  #   * it is the same file as the source (same device and inode): a hardlink
  #     we made in an attempt whose relink then failed;
  #   * the source still exists and the destination is byte-identical to it:
  #     a copy we finished before relink failed.
  #
  # Anything else belongs to someone, and is a conflict. A size match alone is
  # never enough: that would adopt a foreign file and then delete the source.
  # Local copies are published atomically (see FileOrganizer), so a truncated
  # partial is never at the destination.
  #
  # S3 is left to FileOrganizer.place_via_storage: an object only appears once
  # complete, and one of a different size is refused as :destination_exists.
  # A foreign same-size object there would be adopted; that is accepted.
  defp foreign_destination?(source_path, dest_path, target) do
    cond do
      dest_path == source_path -> false
      Mydia.Storage.s3?(dest_path) or Mydia.Storage.s3?(source_path) -> false
      not File.exists?(dest_path) -> false
      true -> not ours?(source_path, dest_path, target)
    end
  end

  defp ours?(source_path, dest_path, target) do
    row_claims?(dest_path, target) or same_file?(source_path, dest_path) or
      identical_copy?(source_path, dest_path)
  end

  defp row_claims?(dest_path, target) do
    rel = Path.relative_to(dest_path, target.path)

    Repo.exists?(
      from(f in MediaFile, where: f.library_path_id == ^target.id and f.relative_path == ^rel)
    )
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
  True when both local paths exist with the same size and bytes. Streamed in
  chunks; meant for rare retry and cleanup paths.
  """
  @spec identical_copy?(String.t(), String.t()) :: boolean()
  def identical_copy?(source_path, dest_path) do
    with {:ok, a} <- File.stat(source_path),
         {:ok, b} <- File.stat(dest_path) do
      a.size == b.size and
        Enum.zip(File.stream!(source_path, @chunk), File.stream!(dest_path, @chunk))
        |> Enum.all?(fn {x, y} -> x == y end)
    else
      _ -> false
    end
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
