defmodule Mydia.Jobs.MediaImport.Failure do
  @moduledoc false

  require Logger
  alias Mydia.Downloads
  alias Mydia.Downloads.Download
  alias Mydia.Jobs.MediaImport
  alias Mydia.Library.PathMapping

  # Exponential backoff schedule in seconds
  # 1 min, 5 min, 15 min, 1 hour, 4 hours, 12 hours, 24 hours, then 24 hours indefinitely
  @backoff_schedule [60, 300, 900, 3600, 14_400, 43_200, 86_400]

  # Snooze settings for waiting on incomplete downloads
  # 5 minutes between snoozes, max 12 snoozes (1 hour total)
  @snooze_interval_seconds 300
  @max_snooze_count 12

  @doc false
  def handle_incomplete_download(download, args, attempt, raw_args) do
    download_id = download.id
    snooze_count = args.snooze_count

    if snooze_count >= @max_snooze_count do
      # Hit max snooze count - mark as failed so it appears in Issues tab
      Logger.warning(
        "Download not completed after #{snooze_count} snoozes (~1 hour), marking as failed",
        download_id: download_id,
        snooze_count: snooze_count
      )

      handle_import_failure(download, :download_not_completed, attempt)
      {:error, :download_not_completed}
    else
      Logger.info("Download not completed, scheduling retry import job",
        download_id: download_id,
        snooze_count: snooze_count + 1,
        max_snooze_count: @max_snooze_count,
        next_check_in_seconds: @snooze_interval_seconds
      )

      # Schedule a new job with incremented snooze count
      # We can't use {:snooze, seconds} because it doesn't update args
      schedule_snooze_retry(download_id, snooze_count + 1, raw_args)
      {:ok, :waiting_for_completion}
    end
  end

  # Calculate exponential backoff based on attempt number
  @doc false
  def calculate_backoff(attempt) do
    # Attempt is 1-indexed, but we want 0-indexed for the schedule
    index = attempt - 1

    # For attempts within our schedule, use the configured value
    if index < length(@backoff_schedule) do
      Enum.at(@backoff_schedule, index)
    else
      # For attempts beyond our schedule, use the last value (24 hours)
      List.last(@backoff_schedule)
    end
  end

  # Update download record with retry metadata after a failed attempt.
  # When `terminal?: true` is passed, clears `import_next_retry_at` so the
  # UI can show "gave up" instead of advertising a retry that will never fire.
  @doc false
  def handle_import_failure(download, reason, attempt, opts \\ []) do
    terminal? = Keyword.get(opts, :terminal?, false)

    next_retry_at =
      if terminal? do
        nil
      else
        DateTime.add(DateTime.utc_now(), calculate_backoff(attempt), :second)
      end

    error_message = format_import_error(reason, download)
    import_failed_at = download.import_failed_at || DateTime.utc_now()

    attrs =
      %{
        import_retry_count: attempt,
        import_last_error: error_message,
        import_failure_reason: failure_reason_tag(reason),
        import_reported_path: failure_reported_path(reason),
        import_next_retry_at: next_retry_at,
        import_failed_at: import_failed_at
      }
      |> Map.merge(path_mapping_attrs(reason))

    case update_retry_metadata(download, attrs) do
      {:ok, _updated} ->
        if terminal? do
          Logger.warning("Import failed terminally — no further retries",
            download_id: download.id,
            attempt: attempt,
            reason: error_message
          )
        else
          Logger.warning("Import failed, will retry",
            download_id: download.id,
            attempt: attempt,
            reason: error_message,
            next_retry_at: next_retry_at
          )
        end

        :ok

      {:error, changeset} ->
        Logger.error("Failed to update retry metadata",
          download_id: download.id,
          errors: inspect(changeset.errors)
        )

        :ok

      :not_found ->
        # The row this whole job is about was deleted while the job was
        # running (e.g. an operator dismissed it mid-import). `Repo.update/1`
        # raises `Ecto.StaleEntryError` when the struct's primary key no
        # longer matches any row — there is no retry metadata left to
        # attach it to, and the job already self-heals next attempt via
        # `fetch_download/1`'s `:not_found` guard, so skip rather than crash.
        Logger.info("Skipping retry-metadata update: download row no longer exists",
          download_id: download.id
        )

        :ok
    end
  end

  defp update_retry_metadata(download, attrs) do
    Downloads.update_download(download, attrs)
  rescue
    Ecto.StaleEntryError -> :not_found
  end

  # Structured failure classification persisted alongside the human message, so
  # the Issues tab can filter (e.g. on "path_mapping_mismatch") without parsing
  # prose.
  defp failure_reason_tag({tag, _path}) when is_atom(tag), do: Atom.to_string(tag)
  defp failure_reason_tag(tag) when is_atom(tag), do: Atom.to_string(tag)
  defp failure_reason_tag(_), do: nil

  # The client-reported path Mydia could not see, persisted for path-bearing
  # failures so the Issues tab can compute a mapping suggestion later.
  #
  # {:partial_import, reason} is explicitly not path-bearing: its second element
  # is an underlying failure reason, which can itself be a string. Letting it
  # fall through would feed prose to the Issues tab's path-mapping suggester.
  defp failure_reported_path({:partial_import, _reason}), do: nil
  defp failure_reported_path({_tag, path}) when is_binary(path), do: path
  defp failure_reported_path(_), do: nil

  # A mount mismatch searches for the directory Mydia can see once, here in the
  # background job, so the Issues tab only reads the result (#1315). Any other
  # failure drops a suggestion an earlier mismatch left behind.
  defp path_mapping_attrs({:path_mapping_mismatch, path}) when is_binary(path),
    do: PathMapping.suggestion_attrs(path)

  defp path_mapping_attrs(_reason), do: Download.cleared_path_mapping_attrs()

  # Format error messages with actionable context for users
  defp format_import_error(:no_client, download) do
    client_name = download.download_client || "Unknown"

    "Download client '#{client_name}' not found in settings. " <>
      "Check Settings → Download Clients and verify the client is configured."
  end

  defp format_import_error(:client_error, download) do
    client_name = download.download_client || "Unknown"

    "Cannot connect to download client '#{client_name}'. " <>
      "Check that the client is running and accessible from the server."
  end

  defp format_import_error(:no_files, _download) do
    "No files found in download location. " <>
      "The download may have been moved, deleted, or is still extracting. " <>
      "Import will retry automatically."
  end

  defp format_import_error({:too_many_conflicts, path}, _download) do
    "Too many different files want the same library filename: #{path}. " <>
      "The download probably contains several releases parsed as the same " <>
      "episode. Check its contents before retrying."
  end

  defp format_import_error({:scoped_files_missing, count}, download) do
    client_name = download.download_client || "the download client"

    "#{client_name} listed #{count} file(s) for this download, but none of them " <>
      "exist where Mydia looked. The client's paths likely differ from Mydia's " <>
      "view of the same volume — add a path mapping or fix the mount."
  end

  defp format_import_error({:save_path_is_download_root, path}, download) do
    client_name = download.download_client || "The download client"

    "#{client_name} reports this download's location as its own download root " <>
      "(#{path}) instead of a folder for this release. Importing from there " <>
      "would pull in every other download in that directory, so it was refused. " <>
      "Enable per-torrent subfolders in the client, or clear the client's " <>
      "download directory setting in Settings → Download Clients if it is wrong."
  end

  defp format_import_error({:path_mapping_mismatch, path}, _download) do
    "Mydia can't access the download path: #{path}. " <>
      "This usually means the download client's volume isn't mounted into the " <>
      "Mydia container at the same path. Add a path mapping or fix the mount."
  end

  defp format_import_error({:path_not_found, path}, _download) do
    "Download path not found: #{path}. " <>
      "The download may have been moved, deleted, or not yet available."
  end

  defp format_import_error({:path_not_accessible, path}, _download) do
    "Download path is not accessible: #{path}. " <>
      "Check filesystem permissions and path accessibility."
  end

  defp format_import_error({:destination_not_accessible, path}, _download) do
    "Could not create the library destination directory: #{path}. " <>
      "Check filesystem permissions and available disk space on the library volume. " <>
      "Import will retry automatically once the path is writable."
  end

  defp format_import_error(:no_library_path, download) do
    media_type = get_media_type_name(download)

    "No library configured for #{media_type}. " <>
      "Add a compatible library in Settings → Libraries."
  end

  defp format_import_error(:no_importable_files, download) do
    media_type = get_media_type_name(download)

    "No importable files found for #{media_type}. " <>
      "The download may contain only non-media files (samples, NFO, etc.)."
  end

  defp format_import_error(:partial_import, _download) do
    "Some files could not be imported. " <>
      "Check library path permissions and available disk space."
  end

  defp format_import_error({:partial_import, inner_reason}, _download) do
    "Some files could not be imported. " <>
      "First error: #{format_error_detail(inner_reason)}"
  end

  defp format_import_error({:import_exception, message}, _download) do
    "Unexpected error during import: #{first_line(message)}. " <>
      "Import will retry automatically."
  end

  defp format_import_error(:download_not_completed, download) do
    client_name = download.download_client || "Unknown"

    "Download not yet complete in '#{client_name}' after waiting ~1 hour. " <>
      "Check the download client for errors or stalled downloads."
  end

  defp format_import_error(:library_type_mismatch, download) do
    media_type = get_media_type_name(download)

    "Cannot import #{media_type} to the configured library. " <>
      "The library type doesn't match the media type (e.g., trying to add movies to a TV library)."
  end

  defp format_import_error(:database_error, _download) do
    "Database error while creating file records. " <>
      "This may be a temporary issue. Import will retry automatically."
  end

  defp format_import_error(reason, _download) when is_atom(reason) do
    # Fallback for unknown atom errors
    reason |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp format_import_error(reason, _download) when is_binary(reason) do
    reason
  end

  defp format_import_error(reason, _download) do
    inspect(reason)
  end

  # Renders the underlying per-file failure reason compactly for inclusion in
  # user-facing messages.
  defp format_error_detail({:import_exception, message}), do: first_line(message)

  defp format_error_detail(reason) when is_atom(reason) do
    reason |> Atom.to_string() |> String.replace("_", " ")
  end

  defp format_error_detail(reason) when is_binary(reason), do: first_line(reason)

  defp format_error_detail(reason), do: inspect(reason)

  # Exception messages can be huge — an Ecto error embeds the whole query — and
  # these end up in `import_last_error`, which the UI renders inline. Keep the
  # first non-empty line. Falls back to a placeholder rather than crashing: this
  # runs inside failure reporting, where raising would lose the original error
  # and leave the download with no message at all.
  defp first_line(message) when is_binary(message) do
    message
    |> String.split("\n", trim: true)
    |> Enum.find_value("(no details)", fn line ->
      trimmed = String.trim(line)
      trimmed != "" and trimmed
    end)
  end

  defp first_line(message), do: inspect(message)

  # Helper to get a human-readable media type name
  defp get_media_type_name(download) do
    cond do
      download.episode && download.media_item ->
        "TV show episode"

      download.media_item && download.media_item.type == "movie" ->
        "movie"

      download.media_item && download.media_item.type == "tv_show" ->
        "TV show"

      true ->
        "media"
    end
  end

  # Clear retry metadata after successful import
  @doc false
  def clear_retry_metadata(download) do
    # Only clear if there was a previous failure
    if download.import_failed_at do
      attrs = %{
        import_retry_count: 0,
        import_last_error: nil,
        import_next_retry_at: nil,
        import_failed_at: nil
      }

      case Downloads.update_download(download, attrs) do
        {:ok, _updated} ->
          Logger.info("Import succeeded after #{download.import_retry_count} retries",
            download_id: download.id
          )

          :ok

        {:error, changeset} ->
          Logger.warning("Failed to clear retry metadata",
            download_id: download.id,
            errors: inspect(changeset.errors)
          )

          :ok
      end
    end
  end

  # Schedule a retry job when download is not yet completed
  # Uses a new job with updated snooze_count to track how long we've been waiting
  defp schedule_snooze_retry(download_id, new_snooze_count, original_args) do
    scheduled_at = DateTime.add(DateTime.utc_now(), @snooze_interval_seconds, :second)

    # Preserve original args but update snooze_count
    new_args =
      original_args
      |> Map.put("snooze_count", new_snooze_count)

    # This job is currently :executing (schedule_snooze_retry/3 only runs from
    # inside perform/1), so the unique states are narrowed to drop :executing
    # here — otherwise Oban would see this insert as colliding with its own
    # still-running parent and silently discard the snooze. See the `unique`
    # comment on `use Oban.Worker` in `Mydia.Jobs.MediaImport` for the full
    # policy this overrides.
    changeset =
      MediaImport.new(new_args,
        scheduled_at: scheduled_at,
        unique: [states: [:suspended, :available, :scheduled, :retryable]]
      )

    # Use Oban.insert if available, otherwise fall back to Repo.insert for testing
    result =
      try do
        Oban.insert(changeset)
      rescue
        RuntimeError ->
          # In testing mode without running Oban, insert directly via Repo
          Mydia.Repo.insert(changeset)
      end

    case result do
      {:ok, job} ->
        Logger.debug("Scheduled snooze retry job",
          download_id: download_id,
          job_id: job.id,
          snooze_count: new_snooze_count,
          scheduled_at: scheduled_at
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule snooze retry job",
          download_id: download_id,
          reason: inspect(reason)
        )

        :error
    end
  end
end
