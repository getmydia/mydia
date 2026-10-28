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
  Moves one file. On the last attempt (`final?`) a copy left by a failed
  relink is discarded whatever the reason, so no unclaimed copy stays behind.
  Returns the result and the sidecar paths left at the source.
  """
  @spec run(Move.t(), LibraryPath.t(), boolean()) :: {result(), [String.t()]}
  def run(%Move{} = move, %LibraryPath{} = target, final?) do
    with {:ok, _action} <- FileMove.place(move.media_file, move.dest_path, target),
         {:ok, _} <- FileMove.relink(move.media_file, target, move.dest_rel, %{}, &{:ok, &1}) do
      finish_source(move.source_path, move.dest_path, move.media_file.id, target)
    else
      {:error, :conflict} -> {:skipped_conflict, []}
      {:error, :source_missing} -> {:skipped_missing, []}
      {:error, reason} -> {discard_partial(move, target, reason, final?), []}
    end
  end

  @spec transient?(result()) :: boolean()
  def transient?({:error, {:path_escape, _}}), do: false
  def transient?({:error, {:relink_failed, %Ecto.Changeset{}}}), do: false
  def transient?({:error, reason}), do: reason not in @permanent
  def transient?(_result), do: false

  @doc """
  After a committed relink: deletes the source, then moves its sidecars and
  points their `subtitles` rows at the new place. A failed delete is
  transient, so a retry's sweep finishes it. Returns the result and the
  sidecars left at the source.
  """
  @spec finish_source(String.t(), String.t(), binary(), LibraryPath.t()) ::
          {result(), [String.t()]}
  def finish_source(source, dest, media_file_id, target) do
    case FileMove.cleanup_source(source, dest) do
      :ok ->
        {:moved, move_sidecars(source, dest, media_file_id, target)}

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
  defp move_sidecars(source, dest, media_file_id, target) do
    source
    |> Sidecars.for()
    |> Enum.reject(fn sidecar ->
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

  defp rewrite_subtitle_rows(media_file_id, from_path, to_path) do
    from(s in Subtitle, where: s.media_file_id == ^media_file_id and s.file_path == ^from_path)
    |> Repo.update_all(set: [file_path: to_path])
  end

  # When place/3 succeeded and relink/5 did not, the destination holds our
  # copy. Before the last attempt it stays on a transient failure: the retry's
  # place/3 adopts it. It is deleted only when the row will never relink there
  # (moved, trashed or deleted meanwhile) or this is the last attempt, and
  # only when no row claims the destination and it is a separate copy of a
  # source that still exists. A destination with the source's inode may be a
  # link the user made, and one without a surviving source is the only copy
  # of the bytes; both are kept.
  defp discard_partial(move, target, reason, final?) do
    if (final? or reason in @row_lost) and discardable?(move, target) do
      Logger.info("Library move removed an unclaimed copy", dest: move.dest_path)
      File.rm(move.dest_path)
    end

    {:error, reason}
  end

  defp discardable?(%Move{source_path: source, dest_path: dest} = move, target) do
    not Mydia.Storage.s3?(dest) and not Mydia.Storage.s3?(source) and source != dest and
      File.exists?(dest) and File.exists?(source) and not FileMove.same_file?(source, dest) and
      not FileMove.claimed?(target.id, move.dest_rel)
  end
end
