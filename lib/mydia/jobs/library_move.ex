defmodule Mydia.Jobs.LibraryMove do
  @moduledoc """
  Moves a media item's files into the library `Mydia.Library.LibraryMove.enqueue/3`
  pointed it at.

  Each file goes through `LibraryMove.FileStep` (place, relink, delete the
  source, carry sidecars), so a row never points at a missing file. Then
  `LibraryMove.Leftovers` carries the rest of each old folder (artwork,
  `Subs/`) after the item and prunes what is empty. A source folder is never
  removed wholesale.

  A file that cannot move for a permanent reason (a foreign file at the
  destination, a missing source, a row changed meanwhile) is skipped. Any
  other failure returns `{:error, {:transient, n}}` and Oban retries. A retry
  first sweeps the sources recorded at enqueue (`LibraryMove.Sources`) to
  finish files whose relink committed, then re-plans, so files already moved
  are not touched again.

  The event is recorded on success, on cancel and on the last attempt (even
  when that attempt raises), with counts taken from where the files are now.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [
      period: :infinity,
      keys: [:media_item_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  require Logger

  alias Mydia.Accounts.Scope
  alias Mydia.Library.ItemFolders
  alias Mydia.Library.LibraryMove
  alias Mydia.Library.LibraryMove.FileStep
  alias Mydia.Library.LibraryMove.Leftovers
  alias Mydia.Library.LibraryMove.Sources
  alias Mydia.Media
  alias Mydia.Media.MediaItem
  alias Mydia.MediaServer.Notifier, as: MediaServerNotifier
  alias Mydia.Repo
  alias Mydia.Settings.LibraryPath

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"media_item_id" => item_id} = args} = job) do
    case {Repo.get(MediaItem, item_id), Repo.get(LibraryPath, args["target_library_path_id"])} do
      {nil, _} ->
        Logger.info("Library move skipped: media item no longer exists", media_item_id: item_id)
        :ok

      {item, %LibraryPath{disabled: false} = target} ->
        run_recording(job, item, target)

      {item, missing_or_disabled} ->
        cancel(item, missing_or_disabled, args)
    end
  end

  # The target went away after enqueue: undo the retarget unless someone has
  # pointed the item elsewhere since. Scope.system/0 is the scope for jobs.
  # Files an earlier attempt already moved stay in the target; the log line
  # and the event's "moved" count say how many.
  defp cancel(item, target, args) do
    target_id = args["target_library_path_id"]
    in_target = Enum.count(LibraryMove.item_files(item.id), &(&1.library_path_id == target_id))

    Logger.warning("Library move cancelled: target library unavailable",
      media_item_id: item.id,
      files_already_in_target: in_target
    )

    if item.library_path_id == target_id do
      Media.update_media_item(
        Scope.system(),
        item,
        %{library_path_id: args["from_library_path_id"]},
        reason: "Library move cancelled",
        actor_type: :job,
        actor_id: "library_move"
      )
    end

    LibraryMove.record_event(item, target, args["actor_id"], failed: true)
    {:cancel, :target_unavailable}
  end

  defp run_recording(job, item, target) do
    run(job, item, target)
  rescue
    error ->
      if final?(job), do: LibraryMove.record_event(item, target, job.args["actor_id"])
      reraise error, __STACKTRACE__
  end

  defp run(job, item, target) do
    sources = Map.get(job.args, "sources", [])
    swept_failures = Sources.sweep(sources, target)

    {:ok, moves} = LibraryMove.plan(item, target)

    folders =
      ItemFolders.folders_for(Enum.map(moves, & &1.media_file) ++ Sources.old_files(sources))

    {results, left_behind} = moves |> Enum.map(&FileStep.run(&1, target, final?(job))) |> unzip()

    Leftovers.carry(folders, item, target, left_behind)
    MediaServerNotifier.notify_all(path: target.path)
    finish(job, item, target, swept_failures + Enum.count(results, &FileStep.transient?/1))
  end

  defp unzip(pairs) do
    {results, left} = Enum.unzip(pairs)
    {results, List.flatten(left)}
  end

  defp finish(job, item, target, 0) do
    LibraryMove.record_event(item, target, job.args["actor_id"])
    :ok
  end

  defp finish(job, item, target, transient) do
    if final?(job), do: LibraryMove.record_event(item, target, job.args["actor_id"])
    {:error, {:transient, transient}}
  end

  defp final?(%Oban.Job{attempt: attempt, max_attempts: max}), do: attempt >= max
end
