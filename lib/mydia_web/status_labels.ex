defmodule MydiaWeb.StatusLabels do
  @moduledoc """
  Translated display labels for fixed vocabularies owned by the domain layer.

  The domain (`Mydia.Media.AvailabilityStatus`, `Mydia.Media.MediaCategory`,
  `Mydia.Downloads.Client.FailureCategory`) keeps the English text and never
  depends on Gettext. This module translates by key on the web side and falls
  back to the domain function for a value it does not know, so a new domain
  value still renders (in English) until it is added here.
  """

  use Gettext, backend: MydiaWeb.Gettext

  alias Mydia.Downloads.Client.FailureCategory
  alias Mydia.Health.Rollup
  alias Mydia.Indexers.CardigannSummary
  alias Mydia.Media.AvailabilityStatus
  alias Mydia.Media.ContentRating
  alias Mydia.Media.Episode
  alias Mydia.Media.MediaCategory
  alias Mydia.Plugins.PageWrites

  @doc """
  Badge tooltip for an availability status, with the "Not monitored" suffix
  for an unmonitored item.
  """
  @spec availability(AvailabilityStatus.t()) :: String.t()
  def availability(%AvailabilityStatus{monitored: true} = status), do: availability_state(status)

  def availability(%AvailabilityStatus{monitored: false} = status) do
    pgettext("availability", "%{status} · Not monitored", status: availability_state(status))
  end

  defp availability_state(%AvailabilityStatus{state: :downloaded}),
    do: pgettext("availability", "Downloaded")

  defp availability_state(%AvailabilityStatus{state: :downloading}),
    do: pgettext("availability", "Downloading")

  defp availability_state(%AvailabilityStatus{state: :missing}),
    do: pgettext("availability", "Missing")

  defp availability_state(%AvailabilityStatus{state: :partial}),
    do: pgettext("availability", "Partial")

  defp availability_state(%AvailabilityStatus{state: :upcoming}),
    do: pgettext("availability", "Upcoming")

  defp availability_state(%AvailabilityStatus{state: :tba}), do: pgettext("availability", "TBA")

  defp availability_state(%AvailabilityStatus{} = status),
    do: AvailabilityStatus.label(%{status | monitored: true})

  @doc """
  Tooltip line for an episode: availability plus file count, quality, download
  progress or air date. Mirrors `Mydia.Media.EpisodeStatus.status_details/1`.
  """
  @spec episode_detail(Episode.t()) :: String.t()
  def episode_detail(%Episode{} = episode) do
    detail = episode_availability_detail(episode)

    if episode.monitored do
      detail
    else
      pgettext("availability", "%{status} · Not monitored", status: detail)
    end
  end

  defp episode_availability_detail(%Episode{media_files: media_files})
       when media_files != [] do
    count = length(media_files)

    case best_quality(media_files) do
      nil ->
        ngettext("Downloaded (%{count} file)", "Downloaded (%{count} files)", count)

      quality ->
        ngettext(
          "Downloaded (%{count} file • %{quality})",
          "Downloaded (%{count} files • %{quality})",
          count,
          quality: quality
        )
    end
  end

  defp episode_availability_detail(%Episode{downloads: downloads} = episode)
       when is_list(downloads) do
    case Enum.filter(downloads, &occupying_download?/1) do
      [] ->
        air_date_detail(episode)

      [download | _] = active ->
        case download_progress(download) do
          nil ->
            gettext("Downloading (%{count} active)", count: length(active))

          progress ->
            gettext("Downloading (%{percent}%)", percent: round(progress))
        end
    end
  end

  defp episode_availability_detail(%Episode{} = episode), do: air_date_detail(episode)

  defp air_date_detail(%Episode{air_date: nil}), do: gettext("Air date to be announced")

  defp air_date_detail(%Episode{air_date: air_date}) do
    if Date.compare(air_date, Date.utc_today()) == :gt do
      upcoming_date(air_date)
    else
      pgettext("availability", "Missing")
    end
  end

  defp upcoming_date(date) do
    days_until = Date.diff(date, Date.utc_today())

    cond do
      days_until == 0 ->
        gettext("Airs today")

      days_until == 1 ->
        gettext("Airs tomorrow")

      days_until <= 7 ->
        ngettext("Airs in %{count} day", "Airs in %{count} days", days_until)

      true ->
        gettext("Airs %{date}",
          date: Calendar.strftime(date, "%b %d, %Y", MydiaWeb.DateNames.strftime_opts())
        )
    end
  end

  # Mirrors the private predicate in Mydia.Media.EpisodeStatus: a download that
  # has not imported, errored, or failed its import terminally still occupies
  # the episode. Plain Download structs and enriched maps both pass through.
  defp occupying_download?(download) do
    is_nil(Map.get(download, :imported_at)) and is_nil(Map.get(download, :error_message)) and
      (is_nil(Map.get(download, :import_failed_at)) or
         not is_nil(Map.get(download, :import_next_retry_at)))
  end

  defp download_progress(download) when is_struct(download), do: nil
  defp download_progress(download) when is_map(download), do: Map.get(download, :progress)

  defp best_quality(media_files) do
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

  @doc "Summary text for a health rollup (\"2/3 healthy\")."
  @spec rollup(Rollup.t()) :: String.t()
  def rollup(%Rollup{state: :none}), do: ""
  def rollup(%Rollup{state: :checking}), do: gettext("Checking…")

  def rollup(%Rollup{healthy: healthy, total: total, unknown: unknown}) when unknown > 0 do
    gettext("%{healthy}/%{total} healthy, %{unknown} checking",
      healthy: healthy,
      total: total,
      unknown: unknown
    )
  end

  def rollup(%Rollup{healthy: healthy, total: total}) do
    gettext("%{healthy}/%{total} healthy", healthy: healthy, total: total)
  end

  @doc "Name of the indexer engine serving searches."
  @spec cardigann_engine(CardigannSummary.engine()) :: String.t()
  def cardigann_engine(:builtin), do: gettext("Built-in")
  def cardigann_engine(:prowlarr), do: gettext("Prowlarr-based")
  def cardigann_engine(other), do: to_string(other)

  @doc "One-line Cardigann summary (\"Cardigann: Built-in · 2/5\")."
  @spec cardigann(CardigannSummary.t()) :: String.t()
  def cardigann(%CardigannSummary{engine: engine, enabled: enabled, installed: installed}) do
    gettext("Cardigann: %{engine} · %{enabled}/%{installed}",
      engine: cardigann_engine(engine),
      enabled: enabled,
      installed: installed
    )
  end

  @doc """
  The `{label, age}` ladder an admin picks a content limit from. Only the
  zero rung carries words; the rest are ages like "12+".
  """
  @spec content_rating_thresholds() :: [{String.t(), non_neg_integer()}]
  def content_rating_thresholds do
    Enum.map(ContentRating.thresholds(), fn
      {_label, 0} -> {gettext("All ages"), 0}
      {label, age} -> {label, age}
    end)
  end

  @doc "Label for a plugin page write surface, shown in confirmations and grants."
  @spec page_write_surface(String.t()) :: String.t()
  def page_write_surface("playback:watched"), do: gettext("Watch history")
  def page_write_surface("collections:favorite"), do: gettext("Favorites")
  def page_write_surface("collections:write"), do: gettext("Collections")
  def page_write_surface("media:add"), do: gettext("Adding media")
  def page_write_surface(other), do: PageWrites.surface_label(other)

  @doc "Display name of a media category."
  @spec media_category(MediaCategory.t()) :: String.t()
  def media_category(:movie), do: pgettext("media category", "Movie")
  def media_category(:anime_movie), do: pgettext("media category", "Anime Movie")
  def media_category(:cartoon_movie), do: pgettext("media category", "Cartoon Movie")
  def media_category(:tv_show), do: pgettext("media category", "TV Show")
  def media_category(:anime_series), do: pgettext("media category", "Anime Series")
  def media_category(:cartoon_series), do: pgettext("media category", "Cartoon Series")
  def media_category(other), do: to_string(other)

  @doc """
  Phrase for why a download client reported a failure, from a category atom or
  the slug stored on the blacklist row.
  """
  @spec failure_category(FailureCategory.t() | String.t() | nil) :: String.t()
  def failure_category(category) when category in [nil, "client_reported_failure"],
    do: pgettext("failure reason", "client reported failure")

  def failure_category(category) when category in [:no_peers, "no_peers"],
    do: pgettext("failure reason", "no peers")

  def failure_category(category) when category in [:missing_files, "missing_files"],
    do: pgettext("failure reason", "missing files")

  def failure_category(category) when category in [:rejected_content, "rejected_content"],
    do: pgettext("failure reason", "rejected content")

  def failure_category(category) when category in [:provider_error, "provider_error"],
    do: pgettext("failure reason", "provider error")

  def failure_category(other), do: FailureCategory.label(other)
end
