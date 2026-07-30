defmodule Mydia.Jobs.LibraryScanScheduler do
  @moduledoc """
  Fixed-interval tick that enqueues library scans for paths that are due.

  Oban's crontab is compile-time, so rather than a per-path schedule this single
  worker runs every 15 minutes and checks each library path's `scan_interval`
  against its `last_scan_at`, enqueueing `LibraryScanner` for the ones that are due.

  Automatic scanning is opt-in: a `NULL` `scan_interval` means manual only, which is
  the default for every path. This preserves the intent of 03df95b5 (2025-11-20),
  which removed LibraryScanner from the crontab so users would not get unwanted
  automatic processing of new files.

  The scheduler queries `library_paths` directly rather than
  `Settings.list_library_paths/1`. The latter merges in runtime structs with synthesized
  `runtime::` ids whose `last_scan_at` is hardcoded to nil and which cannot be written
  to, so they would appear perpetually due and rescan on every tick. Env and YAML paths
  do not need that merge anyway: `LibraryPathSync.sync_from_runtime_config/0` persists
  them as real rows on every boot.

  One job is enqueued per due path rather than a single scan-all, so a slow library
  cannot starve the others and each path's `last_scan_at` stays accurate. `LibraryScanner`
  is unique over Oban's incomplete states with `period: :infinity`, so a path that
  already has a scan waiting, running, or retrying is not enqueued again by a later
  tick; the uniqueness stops applying once that scan finishes.

  Each enqueue carries a random delay of up to 30 minutes
  (`LibraryScanner.jitter_seconds/0`) via `schedule_in`, so instances whose ticks
  land on the same quarter hour do not hit the metadata relay together. The job
  waits in Oban's `:scheduled` state, so it holds no `:media` queue slot meanwhile.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1

  import Ecto.Query

  require Logger

  alias Mydia.Jobs.LibraryScanner
  alias Mydia.Repo
  alias Mydia.Settings.LibraryPath

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    tick(DateTime.utc_now(), &enqueue_scan/1)
  end

  @doc """
  Runs one scheduler tick at `now`, passing each due library path to `enqueuer`
  (a 1-arity function; its return value is ignored). Exposed so due-selection can be
  tested without inserting Oban jobs or touching the filesystem.
  """
  @spec tick(DateTime.t(), (LibraryPath.t() -> any())) :: :ok
  def tick(now, enqueuer) do
    due = due_paths(now)

    if due != [] do
      Logger.info("[LibraryScanScheduler] #{length(due)} library path(s) due for scan")
    end

    Enum.each(due, enqueuer)

    :ok
  end

  @doc """
  Returns the library paths whose automatic scan is due at `now`.
  """
  @spec due_paths(DateTime.t()) :: [LibraryPath.t()]
  def due_paths(now) do
    LibraryPath
    |> where([lp], lp.disabled == false)
    |> where([lp], lp.monitored == true and not is_nil(lp.scan_interval))
    |> Repo.all()
    |> Enum.filter(&due?(&1, now))
  end

  # A path that has never been scanned is due immediately.
  defp due?(%LibraryPath{last_scan_at: nil}, _now), do: true

  defp due?(%LibraryPath{} = library_path, now) do
    DateTime.diff(now, library_path.last_scan_at, :second) >= library_path.scan_interval
  end

  defp enqueue_scan(%LibraryPath{} = library_path) do
    changeset =
      LibraryScanner.new(%{library_path_id: library_path.id},
        schedule_in: LibraryScanner.jitter_seconds()
      )

    case Oban.insert(changeset) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("[LibraryScanScheduler] failed to enqueue scan",
          library_path_id: library_path.id,
          error: inspect(reason)
        )

        :error
    end
  end
end
