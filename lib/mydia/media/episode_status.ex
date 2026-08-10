defmodule Mydia.Media.EpisodeStatus do
  @moduledoc """
  Provides utilities for determining and displaying episode availability status.

  Availability and monitoring are separate axes. This module answers only the first;
  the monitoring flag rides along on the returned `AvailabilityStatus` so the UI can
  render an unmonitored episode's real state at reduced weight.

  Status priority:
  1. Has media files → :downloaded
  2. Air date not set → :tba
  3. Air date in future → :upcoming
  4. Has active downloads → :downloading
  5. Otherwise → :missing
  """

  alias Mydia.Media.Episode
  alias Mydia.Media.AvailabilityStatus

  @doc """
  Determines the current availability of an episode, ignoring its downloads.
  """
  @spec get_episode_status(Episode.t()) :: AvailabilityStatus.t()
  def get_episode_status(%Episode{} = episode) do
    build(episode, state_without_downloads(episode))
  end

  defp state_without_downloads(%Episode{media_files: media_files}) when media_files != [],
    do: :downloaded

  defp state_without_downloads(%Episode{air_date: nil}), do: :tba

  defp state_without_downloads(%Episode{air_date: air_date}) do
    if Date.compare(air_date, Date.utc_today()) == :gt, do: :upcoming, else: :missing
  end

  @doc """
  Enhanced version that checks for active downloads.
  Pass the episode with preloaded downloads association.
  """
  @spec get_episode_status_with_downloads(Episode.t()) :: AvailabilityStatus.t()
  def get_episode_status_with_downloads(%Episode{} = episode) do
    build(episode, state_with_downloads(episode))
  end

  defp state_with_downloads(%Episode{media_files: media_files}) when media_files != [],
    do: :downloaded

  defp state_with_downloads(%Episode{air_date: nil}), do: :tba

  defp state_with_downloads(%Episode{air_date: air_date} = episode) do
    cond do
      Date.compare(air_date, Date.utc_today()) == :gt -> :upcoming
      downloading?(episode) -> :downloading
      true -> :missing
    end
  end

  defp downloading?(%Episode{downloads: downloads}) when is_list(downloads),
    do: Enum.any?(downloads, &occupying_download?/1)

  defp downloading?(_episode), do: false

  defp build(%Episode{} = episode, state) do
    %AvailabilityStatus{
      state: state,
      monitored: episode.monitored,
      file_count: file_count(episode)
    }
  end

  defp file_count(%Episode{media_files: media_files}) when is_list(media_files),
    do: length(media_files)

  defp file_count(_episode), do: 0

  # In-memory mirror of Mydia.Downloads.Download.occupying/1: a download counts as
  # still in flight toward import — and so keeps the episode out of :missing —
  # unless it has imported, the client download failed, or the import failed
  # terminally (no retry scheduled). This covers downloaded-but-awaiting-import
  # and import-retrying, which would otherwise read as :missing.
  #
  # Uses Map.get/2 because `downloads` may hold either plain Download structs or
  # enriched download maps (from list_downloads_with_status) that omit some
  # import_* keys; a missing key reads as nil (i.e. not yet imported/failed).
  defp occupying_download?(download) do
    is_nil(Map.get(download, :imported_at)) and is_nil(Map.get(download, :error_message)) and
      (is_nil(Map.get(download, :import_failed_at)) or
         not is_nil(Map.get(download, :import_next_retry_at)))
  end

  @doc """
  Returns detailed status information for display in tooltips.

  ## Examples

      iex> status_details(%Episode{monitored: true, media_files: [%{resolution: "1080p"}]})
      "Downloaded (1 file • 1080p)"
  """
  @spec status_details(Episode.t()) :: String.t()
  def status_details(%Episode{} = episode) do
    detail = availability_detail(episode)

    if episode.monitored, do: detail, else: detail <> " · Not monitored"
  end

  defp availability_detail(%Episode{media_files: media_files}) when media_files != [] do
    file_count = length(media_files)
    quality = get_best_quality(media_files)

    if quality do
      "Downloaded (#{file_count} file#{plural(file_count)} • #{quality})"
    else
      "Downloaded (#{file_count} file#{plural(file_count)})"
    end
  end

  defp availability_detail(%Episode{downloads: downloads} = episode) when is_list(downloads) do
    case Enum.filter(downloads, &occupying_download?/1) do
      [] ->
        air_date_detail(episode)

      [download | _] = active ->
        case get_download_progress(download) do
          nil -> "Downloading (#{length(active)} active)"
          progress -> "Downloading (#{round(progress)}%)"
        end
    end
  end

  defp availability_detail(%Episode{} = episode), do: air_date_detail(episode)

  defp air_date_detail(%Episode{air_date: nil}), do: "Air date to be announced"

  defp air_date_detail(%Episode{air_date: air_date}) do
    if Date.compare(air_date, Date.utc_today()) == :gt do
      format_upcoming_date(air_date)
    else
      "Missing"
    end
  end

  # Safely extracts progress from either a Download struct or enriched download map
  defp get_download_progress(download) when is_struct(download) do
    # Plain Download struct doesn't have progress field
    nil
  end

  defp get_download_progress(download) when is_map(download) do
    # Enriched download map from list_downloads_with_status has progress
    Map.get(download, :progress)
  end

  defp get_best_quality(media_files) do
    media_files
    |> Enum.map(& &1.resolution)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&resolution_priority/1, :desc)
    |> List.first()
  end

  defp resolution_priority("2160p"), do: 4
  defp resolution_priority("1080p"), do: 3
  defp resolution_priority("720p"), do: 2
  defp resolution_priority("480p"), do: 1
  defp resolution_priority(_), do: 0

  defp format_upcoming_date(date) do
    today = Date.utc_today()
    days_until = Date.diff(date, today)

    cond do
      days_until == 0 -> "Airs today"
      days_until == 1 -> "Airs tomorrow"
      days_until <= 7 -> "Airs in #{days_until} days"
      true -> "Airs #{Calendar.strftime(date, "%b %d, %Y")}"
    end
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"
end
