defmodule Mydia.Jobs.LibraryMove do
  @moduledoc """
  Moves a media item's files into the library `Mydia.Library.LibraryMove.enqueue/3`
  pointed it at.

  Each file goes through `Mydia.Library.FileMove` (place, relink, then delete
  the source), so a row never points at a missing file. Sidecars (subtitles,
  NFO) follow their video, and `subtitles` rows are rewritten in the relink
  transaction. The item's old folders are removed afterwards when nothing
  else lives in them.

  A file that cannot move for a permanent reason (a foreign file at the
  destination, a missing source, a row changed meanwhile) is skipped. Any
  other failure returns `{:error, {:transient, n}}` and Oban retries; a retry
  re-plans, so files already moved are not touched again. The event is
  recorded once: when no transient failure is left, or on the last attempt.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [
      period: :infinity,
      keys: [:media_item_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query, only: [from: 2]
  require Logger

  alias Mydia.Library.FileMove
  alias Mydia.Library.FileOrganizer
  alias Mydia.Library.ItemFolders
  alias Mydia.Library.LibraryMove
  alias Mydia.Library.LibraryMove.Move
  alias Mydia.Library.LibraryMove.Sidecars
  alias Mydia.Library.MediaFile
  alias Mydia.Media.MediaItem
  alias Mydia.MediaServer.Notifier, as: MediaServerNotifier
  alias Mydia.Repo
  alias Mydia.Settings.LibraryPath
  alias Mydia.Subtitles.Subtitle

  @permanent [
    :conflict,
    :source_missing,
    :media_file_moved,
    :media_file_trashed,
    :media_file_gone
  ]
  @row_lost [:media_file_moved, :media_file_trashed, :media_file_gone]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"media_item_id" => item_id} = args} = job) do
    actor_id = args["actor_id"]

    case {Repo.get(MediaItem, item_id), Repo.get(LibraryPath, args["target_library_path_id"])} do
      {nil, _} ->
        Logger.info("Library move skipped: media item no longer exists", media_item_id: item_id)
        :ok

      {item, %LibraryPath{disabled: false} = target} ->
        run(job, item, target, actor_id)

      {item, _missing_or_disabled} ->
        LibraryMove.record_event(item, nil, [{:error, :target_unavailable}], actor_id)
        {:cancel, :target_unavailable}
    end
  end

  defp run(job, item, target, actor_id) do
    {:ok, moves} = LibraryMove.plan(item, target)
    folders = ItemFolders.folders_for(Enum.map(moves, & &1.media_file))
    results = Enum.map(moves, &move_one(&1, target))

    Enum.each(folders, &ItemFolders.finish/1)
    MediaServerNotifier.notify_all(path: target.path)

    case Enum.count(results, &transient?/1) do
      0 ->
        LibraryMove.record_event(item, target, results, actor_id)
        :ok

      n ->
        if job.attempt >= job.max_attempts,
          do: LibraryMove.record_event(item, target, results, actor_id)

        {:error, {:transient, n}}
    end
  end

  defp transient?({:error, {:path_escape, _}}), do: false
  defp transient?({:error, reason}), do: reason not in @permanent
  defp transient?(_result), do: false

  defp move_one(%Move{} = move, target) do
    with {:ok, _action} <- FileMove.place(move.media_file, move.dest_path, target),
         {:ok, _} <-
           FileMove.relink(move.media_file, target, move.dest_rel, %{}, fn updated ->
             rewrite_subtitles(updated, move)
           end) do
      _ = FileMove.cleanup_source(move.source_path, move.dest_path)
      move_sidecars(move, target)
      :moved
    else
      {:error, :conflict} -> :skipped_conflict
      {:error, :source_missing} -> :skipped_missing
      {:error, reason} -> discard_partial(move, target, reason)
    end
  end

  # Subtitle rows naming a sidecar of this video follow it. The sidecar files
  # themselves move after the commit, in move_sidecars/2.
  defp rewrite_subtitles(updated, move) do
    count =
      from(s in Subtitle, where: s.media_file_id == ^updated.id)
      |> Repo.all()
      |> Enum.filter(&sidecar_of?(&1.file_path, move.source_path))
      |> Enum.map(&rewrite_subtitle(&1, move))
      |> Enum.sum()

    {:ok, count}
  end

  defp sidecar_of?(nil, _source), do: false

  defp sidecar_of?(path, source) do
    Path.dirname(path) == Path.dirname(source) and
      String.starts_with?(Path.basename(path), Path.rootname(Path.basename(source)) <> ".")
  end

  defp rewrite_subtitle(subtitle, move) do
    dest = Sidecars.dest_for(subtitle.file_path, move.source_path, move.dest_path)

    {count, _} =
      from(s in Subtitle, where: s.id == ^subtitle.id) |> Repo.update_all(set: [file_path: dest])

    count
  end

  # Best effort: a sidecar that cannot move never fails its video. An existing
  # file at the sidecar's destination is someone else's and is left alone.
  defp move_sidecars(move, target) do
    for sidecar <- Sidecars.for(move.source_path) do
      dest = Sidecars.dest_for(sidecar, move.source_path, move.dest_path)
      move_sidecar(sidecar, dest, target)
    end

    :ok
  end

  defp move_sidecar(sidecar, dest, target) do
    if FileMove.exists?(dest) do
      Logger.warning("Library move left a sidecar behind: destination exists", sidecar: sidecar)
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
      end
    end
  end

  # When place/3 succeeded and relink/5 did not, the destination holds our
  # copy. On a transient failure it stays: the retry's place/3 adopts it. It is
  # deleted only when this row will never relink there (it was moved, trashed
  # or deleted meanwhile), no row claims the destination, and the destination
  # is a separate copy of a source that still exists. A destination with the
  # source's inode may be a link the user made, and one without a surviving
  # source is the only copy of the bytes; both are kept.
  defp discard_partial(move, target, reason) do
    if reason in @row_lost and discardable?(move, target) do
      Logger.info("Library move removed an unclaimed copy", dest: move.dest_path)
      File.rm(move.dest_path)
    end

    {:error, reason}
  end

  defp discardable?(%Move{source_path: source, dest_path: dest} = move, target) do
    not Mydia.Storage.s3?(dest) and not Mydia.Storage.s3?(source) and source != dest and
      File.exists?(dest) and File.exists?(source) and not same_inode?(source, dest) and
      not claimed?(target, move.dest_rel)
  end

  defp same_inode?(a, b) do
    with {:ok, sa} <- File.stat(a), {:ok, sb} <- File.stat(b) do
      sa.inode == sb.inode and sa.major_device == sb.major_device
    else
      _ -> true
    end
  end

  defp claimed?(target, rel) do
    Repo.exists?(
      from(f in MediaFile, where: f.library_path_id == ^target.id and f.relative_path == ^rel)
    )
  end
end
