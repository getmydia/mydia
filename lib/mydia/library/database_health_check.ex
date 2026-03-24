defmodule Mydia.Library.DatabaseHealthCheck do
  @moduledoc """
  Startup health check that detects database integrity issues and automatically
  triggers library re-scans when needed.

  Runs on application startup to detect:
  1. Media files with relative_path but missing library_path_id

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
  alias Mydia.Library.MediaFile

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
        missing_library_path: 2,
        total_issues: 2
      }
  """
  def detect_issues do
    missing_library_path_count = count_files_missing_library_path()

    %{
      missing_library_path: missing_library_path_count,
      total_issues: missing_library_path_count
    }
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
            parse_boolean_value(setting.value)
        end

      value ->
        parse_boolean_value(value)
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

  defp parse_boolean_value("true"), do: true
  defp parse_boolean_value("1"), do: true
  defp parse_boolean_value("yes"), do: true
  defp parse_boolean_value(_), do: false

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
      if issues.missing_library_path > 0 do
        ["#{issues.missing_library_path} file(s) missing library path" | parts]
      else
        parts
      end

    message = Enum.join(Enum.reverse(parts), ", ")
    Logger.warning("[DatabaseHealthCheck] Detected issues: #{message}")
  end

  defp queue_library_rescan(issues) do
    Logger.info(
      "[DatabaseHealthCheck] Queuing library re-scan to repair #{issues.total_issues} issue(s)"
    )

    case Mydia.Library.trigger_full_library_scan() do
      {:ok, job} ->
        Logger.info("[DatabaseHealthCheck] Library re-scan queued", job_id: job.id)

      {:error, reason} ->
        Logger.error("[DatabaseHealthCheck] Failed to queue library re-scan: #{inspect(reason)}")
    end
  end
end
