defmodule Mydia.Media.EpisodeStatus do
  @moduledoc """
  Provides utilities for determining and displaying episode availability status.

  Status priority (matching calendar view logic):
  1. Not monitored → :not_monitored
  2. Has media files → :downloaded
  3. Air date in future → :upcoming
  4. Has active downloads → :downloading
  5. Otherwise → :missing
  """

  alias Mydia.Media.Episode

  @type status ::
          :downloaded | :downloading | :missing | :upcoming | :not_monitored | :tba | :partial

  @doc """
  Determines the current status of an episode based on its attributes.

  Returns one of: :downloaded, :downloading, :missing, :upcoming, :not_monitored, :tba, :partial

  ## Examples

      iex> get_episode_status(%Episode{monitored: false})
      :not_monitored

      iex> get_episode_status(%Episode{monitored: true, media_files: [%MediaFile{}]})
      :downloaded

      iex> get_episode_status(%Episode{monitored: true, air_date: ~D[2099-12-31]})
      :upcoming

      iex> get_episode_status(%Episode{monitored: true, air_date: nil})
      :tba
  """
  @spec get_episode_status(Episode.t()) :: status()
  def get_episode_status(%Episode{monitored: false}), do: :not_monitored

  def get_episode_status(%Episode{media_files: media_files}) when media_files != [],
    do: :downloaded

  def get_episode_status(%Episode{air_date: air_date}) when not is_nil(air_date) do
    today = Date.utc_today()

    if Date.compare(air_date, today) == :gt do
      :upcoming
    else
      check_downloading_or_missing()
    end
  end

  def get_episode_status(%Episode{air_date: nil}), do: :tba

  defp check_downloading_or_missing do
    # This will be enhanced when we pass downloads data
    # For now, return :missing as the default for aired episodes
    :missing
  end

  @doc """
  Enhanced version that checks for active downloads.
  Pass the episode with preloaded downloads association.
  """
  @spec get_episode_status_with_downloads(Episode.t()) :: status()
  def get_episode_status_with_downloads(%Episode{monitored: false}), do: :not_monitored

  def get_episode_status_with_downloads(%Episode{media_files: media_files})
      when media_files != [],
      do: :downloaded

  def get_episode_status_with_downloads(%Episode{air_date: air_date} = episode)
      when not is_nil(air_date) do
    today = Date.utc_today()

    if Date.compare(air_date, today) == :gt do
      :upcoming
    else
      check_downloads(episode)
    end
  end

  def get_episode_status_with_downloads(%Episode{air_date: nil}), do: :tba

  defp check_downloads(%Episode{downloads: downloads}) when is_list(downloads) do
    if Enum.any?(downloads, &occupying_download?/1), do: :downloading, else: :missing
  end

  defp check_downloads(_episode), do: :missing

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
  Returns DaisyUI badge color classes for a given status.

  ## Examples

      iex> status_color(:downloaded)
      "badge-success"

      iex> status_color(:downloading)
      "badge-info"
  """
  @spec status_color(status()) :: String.t()
  def status_color(:downloaded), do: "badge-success"
  def status_color(:downloading), do: "badge-info"
  def status_color(:missing), do: "badge-error"
  def status_color(:not_monitored), do: "badge-ghost"
  def status_color(:upcoming), do: "badge-outline"
  def status_color(:tba), do: "badge-warning"
  def status_color(:partial), do: "badge-warning"

  @doc """
  Returns HeroIcon name for a given status (for accessibility).

  ## Examples

      iex: status_icon(:downloaded)
      "hero-check-circle"

      iex: status_icon(:downloading)
      "hero-arrow-down-tray"
  """
  @spec status_icon(status()) :: String.t()
  def status_icon(:downloaded), do: "hero-check-circle"
  def status_icon(:downloading), do: "hero-arrow-down-tray"
  def status_icon(:missing), do: "hero-exclamation-circle"
  def status_icon(:not_monitored), do: "hero-eye-slash"
  def status_icon(:upcoming), do: "hero-clock"
  def status_icon(:tba), do: "hero-question-mark-circle"
  def status_icon(:partial), do: "hero-minus-circle"

  @doc """
  Returns human-readable label for a given status.

  ## Examples

      iex> status_label(:downloaded)
      "Downloaded"

      iex> status_label(:not_monitored)
      "Not Monitored"
  """
  @spec status_label(status()) :: String.t()
  def status_label(:downloaded), do: "Downloaded"
  def status_label(:downloading), do: "Downloading"
  def status_label(:missing), do: "Missing"
  def status_label(:not_monitored), do: "Not Monitored"
  def status_label(:upcoming), do: "Upcoming"
  def status_label(:tba), do: "TBA"
  def status_label(:partial), do: "Partial"

  @doc """
  Returns detailed status information for display in tooltips.

  ## Examples

      iex> status_details(%Episode{monitored: true, media_files: [%{resolution: "1080p"}]})
      "Downloaded (1 file)"
  """
  @spec status_details(Episode.t()) :: String.t()
  def status_details(%Episode{media_files: media_files})
      when media_files != [] do
    file_count = length(media_files)
    quality = get_best_quality(media_files)

    if quality do
      "Downloaded (#{file_count} file#{plural(file_count)} • #{quality})"
    else
      "Downloaded (#{file_count} file#{plural(file_count)})"
    end
  end

  def status_details(%Episode{downloads: downloads} = episode) when is_list(downloads) do
    active_downloads = Enum.filter(downloads, &occupying_download?/1)

    case length(active_downloads) do
      0 ->
        cond do
          !episode.monitored ->
            "Not Monitored"

          is_nil(episode.air_date) ->
            "Air date to be announced"

          episode.air_date && Date.compare(episode.air_date, Date.utc_today()) == :gt ->
            format_upcoming_date(episode.air_date)

          true ->
            "Missing"
        end

      count ->
        download = hd(active_downloads)

        # Handle both plain Download structs and enriched download maps
        progress = get_download_progress(download)

        if progress do
          "Downloading (#{round(progress)}%)"
        else
          "Downloading (#{count} active)"
        end
    end
  end

  def status_details(%Episode{air_date: air_date, monitored: monitored}) do
    cond do
      !monitored ->
        "Not Monitored"

      is_nil(air_date) ->
        "Air date to be announced"

      air_date && Date.compare(air_date, Date.utc_today()) == :gt ->
        format_upcoming_date(air_date)

      true ->
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
