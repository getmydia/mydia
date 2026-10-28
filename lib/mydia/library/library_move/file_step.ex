defmodule Mydia.Library.LibraryMove.FileStep do
  @moduledoc """
  Moves one planned file for `Mydia.Jobs.LibraryMove`: place, relink, then
  `finish_source/4` (delete the source, carry its sidecars and their
  `subtitles` rows).

  Results: `:moved`, `:skipped_conflict`, `:skipped_missing`, or
  `{:error, reason}`. `transient?/1` says which errors Oban should retry.
  """

  import Ecto.Query, only: [from: 2]
  require Logger

  alias Mydia.Library.FileMove
  alias Mydia.Library.FileOrganizer
  alias Mydia.Library.LibraryMove.Move
  alias Mydia.Library.LibraryMove.Sidecars
  alias Mydia.Library.MediaFile
  alias Mydia.Repo
  alias Mydia.Settings.LibraryPath
  alias Mydia.Subtitles.Subtitle

  @permanent [
    :conflict,
    :source_missing,
    :no_source_path,
    :media_file_moved,
    :media_file_trashed,
    :media_file_gone
  ]
  @row_lost [:media_file_moved, :media_file_trashed, :media_file_gone]

  @type result :: :moved | :skipped_conflict | :skipped_missing | {:error, term()}

  @doc """
  Moves one file. A move the plan marked as a conflict is skipped untouched.
  On the last attempt (`final?`) a copy left by a failed relink is discarded
  whatever the reason, so no unclaimed copy stays behind. Returns the result
  and the sidecar paths left at the source.
  """
  @spec run(Move.t(), LibraryPath.t(), boolean()) :: {result(), [String.t()]}
  def run(%Move{conflict: true}, %LibraryPath{}, _final?), do: {:skipped_conflict, []}

  def run(%Move{} = move, %LibraryPath{} = target, final?) do
    # Ownership is decided among the source folder's rows, which this file
    # leaves once relinked. A folder that cannot be listed stops the move
    # before anything is placed, and the job retries.
    with {:ok, sidecars} <- list_sidecars(move.media_file),
         {:ok, placed} <- FileMove.place(move.media_file, move.dest_path, target),
         {:ok, _} <-
           FileMove.relink(move.media_file, target, move.dest_rel, %{}, &{:ok, &1}, placed) do
      finish_source(move.media_file, move.dest_path, target, sidecars)
    else
      {:error, {:sidecars_unlisted, _}} = error -> {error, []}
      {:error, reason} -> {failed(move, target, reason, final?), []}
    end
  end

  defp list_sidecars(media_file) do
    case Sidecars.for(media_file) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:sidecars_unlisted, reason}}
    end
  end

  # An S3 object of another size at the destination is somebody's file.
  defp failed(_move, _target, :conflict, _final?), do: :skipped_conflict
  defp failed(_move, _target, {:destination_exists, _}, _final?), do: :skipped_conflict
  defp failed(_move, _target, :source_missing, _final?), do: :skipped_missing
  defp failed(move, target, reason, final?), do: discard_partial(move, target, reason, final?)

  @spec transient?(result()) :: boolean()
  def transient?({:error, {:path_escape, _}}), do: false
  def transient?({:error, {:relink_failed, %Ecto.Changeset{}}}), do: false
  def transient?({:error, reason}), do: reason not in @permanent
  def transient?(_result), do: false

  @doc """
  After a committed relink: deletes the source, then moves `sidecars` and
  points their `subtitles` rows at the new place. `old` is the file as it
  was before the relink (its old row, or an unsaved struct for that
  location). A source a row claims again (a scan re-registered it in the
  meantime) is kept, with its sidecars. A failed delete is transient, so a
  retry's sweep finishes it. Returns the result and the sidecars left at the
  source.
  """
  @spec finish_source(MediaFile.t(), String.t(), LibraryPath.t(), [String.t()]) ::
          {result(), [String.t()]}
  def finish_source(%MediaFile{} = old, dest, target, sidecars) do
    source = MediaFile.storage_path(old)

    if FileMove.claimed?(old.library_path_id, old.relative_path, old.id) do
      Logger.info("Library move kept a source: a row claims it again", source: source)
      {:moved, sidecars}
    else
      delete_source(source, dest, old.id, target, sidecars)
    end
  end

  @doc """
  `finish_source/4` for a retry's sweep, with the sidecars listed now. A
  folder that cannot be listed is a transient error.
  """
  @spec finish_swept(MediaFile.t(), String.t(), LibraryPath.t()) :: {result(), [String.t()]}
  def finish_swept(%MediaFile{} = old, dest, target) do
    case list_sidecars(old) do
      {:ok, sidecars} -> finish_source(old, dest, target, sidecars)
      error -> {error, []}
    end
  end

  defp delete_source(source, dest, media_file_id, target, sidecars) do
    case FileMove.cleanup_source(source, dest) do
      :ok ->
        {:moved, move_sidecars(sidecars, source, dest, media_file_id, target)}

      {:error, reason} ->
        Logger.warning("Library move could not delete a source",
          source: source,
          reason: inspect(reason)
        )

        {{:error, {:cleanup_failed, reason}}, []}
    end
  end

  # Best effort: a sidecar that cannot move never fails its video. A row is
  # rewritten only once its file has moved, so a skipped or failed sidecar
  # keeps its row and file together at the source.
  defp move_sidecars(sidecars, source, dest, media_file_id, target) do
    repoint_moved_rows(media_file_id, source, dest)

    Enum.reject(sidecars, fn sidecar ->
      to = Sidecars.dest_for(sidecar, source, dest)
      moved? = move_sidecar(sidecar, to, target) == :ok
      if moved?, do: rewrite_subtitle_rows(media_file_id, sidecar, to)
      moved?
    end)
  end

  defp move_sidecar(sidecar, dest, target) do
    if FileMove.exists?(dest) do
      Logger.warning("Library move left a sidecar behind: destination exists", sidecar: sidecar)
      :skipped
    else
      case FileOrganizer.place_file(sidecar, dest,
             use_hardlinks: true,
             remove_source_after_hardlink: true,
             fallback: :move,
             confine_to: target.path
           ) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("Sidecar move failed", sidecar: sidecar, reason: inspect(reason))
          :failed
      end
    end
  end

  # A crash between a sidecar's move and its row rewrite leaves the row at a
  # source path that is gone. The retry's sweep comes back through here and
  # points such a row at the sidecar's destination, once that exists.
  defp repoint_moved_rows(media_file_id, source, dest) do
    dir = Path.dirname(source)

    from(s in Subtitle, where: s.media_file_id == ^media_file_id, select: s.file_path)
    |> Repo.all()
    |> Enum.filter(&(is_binary(&1) and Path.dirname(&1) == dir))
    |> Enum.each(fn path ->
      to = Sidecars.dest_for(path, source, dest)

      if not FileMove.exists?(path) and FileMove.exists?(to),
        do: rewrite_subtitle_rows(media_file_id, path, to)
    end)
  end

  defp rewrite_subtitle_rows(media_file_id, from_path, to_path) do
    from(s in Subtitle, where: s.media_file_id == ^media_file_id and s.file_path == ^from_path)
    |> Repo.update_all(set: [file_path: to_path])
  end

  @doc false
  # When place/4 succeeded and relink/6 did not, the destination holds our
  # copy. Before the last attempt it stays on a transient failure: the retry's
  # place/4 adopts it. It is deleted only when the row will never relink there
  # (moved, trashed or deleted meanwhile) or this is the last attempt, and
  # only when no row claims the destination and it is a separate,
  # byte-identical copy of a source that still exists. A destination with the source's inode may be a
  # link the user made, and one without a surviving source is the only copy
  # of the bytes; both are kept. Public for its tests only.
  @spec discard_partial(Move.t(), LibraryPath.t(), term(), boolean()) :: {:error, term()}
  def discard_partial(move, target, reason, final?) do
    if (final? or reason in @row_lost) and discardable?(move, target) do
      Logger.info("Library move removed an unclaimed copy", dest: move.dest_path)
      File.rm(move.dest_path)
    end

    {:error, reason}
  end

  defp discardable?(%Move{source_path: source, dest_path: dest} = move, target) do
    not Mydia.Storage.s3?(dest) and not Mydia.Storage.s3?(source) and source != dest and
      File.exists?(dest) and File.exists?(source) and not FileMove.same_file?(source, dest) and
      not FileMove.claimed?(target.id, move.dest_rel) and FileMove.identical_copy?(source, dest)
  end
end
