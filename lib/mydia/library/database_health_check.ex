defmodule Mydia.Library.DatabaseHealthCheck do
  @moduledoc """
  Startup health check that detects database integrity issues and automatically
  triggers library re-scans when needed.

  Runs on application startup to detect:
  1. Stuck media files: no `media_item_id`, no `episode_id`, in a standard
     (non-specialized) library, AND carrying no match candidate. The candidate
     exclusion is the load-bearing half. The import coordinator commits
     orphaned rows as its first phase and can legitimately leave thousands of
     them queued in the review inbox; those are pending work, not damage, and
     counting them here would queue a re-scan against a healthy library. See
     `count_orphaned_files/0`.
  2. Media files with relative_path but missing library_path_id

  When issues are detected above a threshold, a library re-scan is queued as a
  background job to attempt automatic repair.

  ## Configuration

  The auto-repair behavior can be configured via (in priority order):

  1. **Environment variables** (highest priority):
     - `DATABASE_AUTO_REPAIR` - Set to "true" or "false"
     - `DATABASE_AUTO_REPAIR_THRESHOLD` - Number of issues to trigger repair

  2. **Admin UI**: Settings > General > Library section

  3. **Application config**:

         config :mydia,
           database_auto_repair: false,
           database_auto_repair_threshold: 10

  4. **Defaults**: enabled=true, threshold=10

  ## Performance

  Uses lightweight count queries that don't load actual records. The health
  check itself completes quickly and doesn't block application startup.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Mydia.Repo
  alias Mydia.Settings
  alias Mydia.Library.MatchCandidate
  alias Mydia.Library.MediaFile
  alias Mydia.Settings.LibraryPath

  @default_threshold 10

  @doc """
  Runs the database health check and queues a library re-scan if issues are found.

  Returns `:ok` on completion (regardless of whether issues were found).

  This function is called during application startup and should never raise
  exceptions to avoid blocking the application.
  """
  def run do
    start_time = System.monotonic_time(:millisecond)

    try do
      # Skip if auto-repair is disabled
      if auto_repair_enabled?() do
        issues = detect_issues()
        handle_issues(issues)
      else
        Logger.debug("[DatabaseHealthCheck] Auto-repair disabled, skipping health check")
      end

      elapsed = System.monotonic_time(:millisecond) - start_time
      Logger.debug("[DatabaseHealthCheck] Completed in #{elapsed}ms")

      :ok
    rescue
      error ->
        Logger.error("[DatabaseHealthCheck] Failed: #{inspect(error)}")
        Logger.error(Exception.format(:error, error, __STACKTRACE__))
        :ok
    end
  end

  @doc """
  Detects database integrity issues without triggering any repairs.

  Returns a map with issue counts:

      %{
        orphaned_files: 15,
        missing_library_path: 2,
        total_issues: 17
      }
  """
  def detect_issues do
    orphaned_count = count_orphaned_files()
    missing_library_path_count = count_files_missing_library_path()

    %{
      orphaned_files: orphaned_count,
      missing_library_path: missing_library_path_count,
      total_issues: orphaned_count + missing_library_path_count
    }
  end

  @doc """
  Counts orphaned media files in standard (non-specialized) libraries.

  Orphaned files are those with no `media_item_id` and no `episode_id`.
  Files in specialized libraries (music, books, adult) are excluded as they
  don't require parent associations.

  Files that already hold a match candidate are excluded too. A candidate
  means the file is queued in the import inbox for review, not stuck: the
  import coordinator writes orphaned rows as its first phase, and a scan can
  legitimately leave thousands of them sitting there awaiting a decision.
  Without this exclusion, that queued work reads as database damage.
  """
  def count_orphaned_files do
    standard_types = [:movies, :series, :mixed]

    from(mf in MediaFile,
      join: lp in LibraryPath,
      on: mf.library_path_id == lp.id,
      left_join: c in MatchCandidate,
      on: c.media_file_id == mf.id,
      where: is_nil(mf.media_item_id) and is_nil(mf.episode_id),
      where: lp.type in ^standard_types,
      where: is_nil(c.id),
      select: count(mf.id)
    )
    |> Repo.one()
  end

  @doc """
  Counts media files that have `relative_path` but are missing `library_path_id`.

  This indicates an incomplete migration or data corruption.
  """
  def count_files_missing_library_path do
    from(mf in MediaFile,
      where: not is_nil(mf.relative_path) and is_nil(mf.library_path_id),
      select: count(mf.id)
    )
    |> Repo.one()
  end

  ## Private Functions

  defp auto_repair_enabled? do
    # Priority: ENV > Database > Application config > Default
    case System.get_env("DATABASE_AUTO_REPAIR") do
      nil ->
        case Settings.get_config_setting_by_key("library.auto_repair_enabled") do
          nil ->
            Application.get_env(:mydia, :database_auto_repair, true)

          setting ->
            Settings.parse_setting_boolean(setting.value)
        end

      value ->
        Settings.parse_setting_boolean(value)
    end
  end

  defp get_threshold do
    # Priority: ENV > Database > Application config > Default
    case System.get_env("DATABASE_AUTO_REPAIR_THRESHOLD") do
      nil ->
        case Settings.get_config_setting_by_key("library.auto_repair_threshold") do
          nil ->
            Application.get_env(:mydia, :database_auto_repair_threshold, @default_threshold)

          setting ->
            case Integer.parse(setting.value) do
              {int, ""} -> int
              _ -> @default_threshold
            end
        end

      value ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> @default_threshold
        end
    end
  end

  defp handle_issues(%{total_issues: 0}) do
    Logger.debug("[DatabaseHealthCheck] No issues detected")
    :ok
  end

  defp handle_issues(%{total_issues: total} = issues) when total > 0 do
    threshold = get_threshold()

    log_detected_issues(issues)

    if total >= threshold do
      queue_library_rescan(issues)
    else
      Logger.info(
        "[DatabaseHealthCheck] Issues below threshold (#{total} < #{threshold}), skipping auto-repair"
      )
    end

    :ok
  end

  defp log_detected_issues(issues) do
    parts = []

    parts =
      if issues.orphaned_files > 0 do
        ["#{issues.orphaned_files} orphaned file(s)" | parts]
      else
        parts
      end

    parts =
      if issues.missing_library_path > 0 do
        ["#{issues.missing_library_path} file(s) missing library path" | parts]
      else
        parts
      end

    message = Enum.join(Enum.reverse(parts), ", ")
    Logger.warning("[DatabaseHealthCheck] Detected issues: #{message}")
  end

  defp queue_library_rescan(issues) do
    # This runs on every boot, and self-hosted restarts cluster (everyone pulls a
    # new image at once), so the repair scan is jittered rather than immediate.
    delay_seconds = Mydia.Jobs.LibraryScanner.jitter_seconds()

    Logger.info(
      "[DatabaseHealthCheck] Queuing library re-scan to repair #{issues.total_issues} issue(s) in #{delay_seconds}s"
    )

    case Mydia.Library.trigger_full_library_scan(schedule_in: delay_seconds) do
      {:ok, job} ->
        Logger.info("[DatabaseHealthCheck] Library re-scan queued", job_id: job.id)

      {:error, reason} ->
        Logger.error("[DatabaseHealthCheck] Failed to queue library re-scan: #{inspect(reason)}")
    end
  end
end
