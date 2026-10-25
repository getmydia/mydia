defmodule MydiaWeb.MediaLive.Show.Formatters do
  @moduledoc """
  Formatting functions for the MediaLive.Show page.
  Handles formatting of dates, times, download statuses, and quality
  information. File sizes go through `MydiaWeb.Formatters.format_file_size/1`.
  """

  use Gettext, backend: MydiaWeb.Gettext

  alias Mydia.Indexers.SearchResult
  alias MydiaWeb.DateTimeFormat

  def format_date(nil), do: gettext("N/A")

  def format_date(%Date{} = date) do
    Calendar.strftime(date, "%b %d, %Y")
  end

  def format_download_status("pending"), do: pgettext("download", "Queued")
  def format_download_status("downloading"), do: pgettext("download", "Downloading")
  def format_download_status("seeding"), do: pgettext("download", "Seeding")
  def format_download_status("checking"), do: pgettext("download", "Checking")
  def format_download_status("paused"), do: pgettext("download", "Paused")
  def format_download_status("completed"), do: pgettext("download", "Completed")
  def format_download_status("failed"), do: pgettext("download", "Failed")
  def format_download_status("cancelled"), do: pgettext("download", "Cancelled")
  def format_download_status("missing"), do: pgettext("download", "Missing")
  def format_download_status("grabbing"), do: pgettext("download", "Grabbing…")
  def format_download_status(_), do: gettext("Unknown")

  @doc """
  A compact relative time for the History rail: "5h", "2d", "7mo".

  Compact because the label shares a baseline with the event title inside a
  20rem column: a prose form like "3 hours ago" wraps there, and that wrap is
  what made each row 156px tall.
  """
  def format_relative_time_short(timestamp) do
    diff = DateTime.diff(DateTime.utc_now(), timestamp, :second)

    cond do
      diff < 60 -> pgettext("relative time", "now")
      diff < 3600 -> gettext("%{count}m", count: div(diff, 60))
      diff < 86_400 -> gettext("%{count}h", count: div(diff, 3600))
      diff < 2_592_000 -> gettext("%{count}d", count: div(diff, 86_400))
      diff < 31_536_000 -> gettext("%{count}mo", count: div(diff, 2_592_000))
      true -> gettext("%{count}y", count: div(diff, 31_536_000))
    end
  end

  def format_absolute_time(timestamp, %Mydia.TimeDisplay{} = display) do
    DateTimeFormat.format(timestamp, :datetime, display)
  end

  def format_download_quality(nil), do: gettext("Unknown")

  def format_download_quality(quality) when is_map(quality) do
    # Build a concise quality description from the quality map
    parts =
      [
        quality["resolution"] || quality[:resolution],
        quality["source"] || quality[:source],
        (quality["hdr"] || quality[:hdr]) && "HDR"
      ]
      |> Enum.filter(& &1)

    case Enum.join(parts, " ") do
      "" -> gettext("Unknown")
      description -> description
    end
  end

  def format_download_quality(_), do: gettext("Unknown")

  def format_search_size(%SearchResult{} = result) do
    SearchResult.format_size(result)
  end

  def format_search_date(nil, %Mydia.TimeDisplay{}), do: gettext("Unknown")

  def format_search_date(%DateTime{} = dt, %Mydia.TimeDisplay{} = display) do
    DateTimeFormat.format(dt, :date, display)
  end

  def format_metadata_for_display(event) do
    metadata = event.metadata || %{}

    case event.type do
      type when type in ["download.initiated", "download.completed"] ->
        quality = get_quality_from_metadata(metadata)

        %{
          quality: quality,
          indexer: metadata["indexer"]
        }

      "download.failed" ->
        %{
          error: metadata["error_message"]
        }

      "media_file.imported" ->
        %{
          resolution: metadata["resolution"],
          codec: metadata["codec"],
          size: metadata["size"]
        }

      _ ->
        nil
    end
  end

  # Helper to extract quality from metadata (could be nested in download metadata)
  defp get_quality_from_metadata(metadata) do
    metadata["quality"] || get_in(metadata, ["download_metadata", "quality"])
  end

  # Format episode number as S01E05
  def format_episode_number(episode) do
    "S#{String.pad_leading(to_string(episode.season_number), 2, "0")}E#{String.pad_leading(to_string(episode.episode_number), 2, "0")}"
  end

  @doc """
  Names an alternative season ordering's per-season episode counts in
  prose, e.g. `[51, 51, 52, 16]` -> `"four seasons of 51, 51, 52 and 16"`.
  Used by the season-order suggestion banner to name the concrete
  alternative TVDB offers, rather than an abstract choice.
  """
  def format_season_ordering_counts([single]),
    do: gettext("one season of %{counts}", counts: single)

  def format_season_ordering_counts(counts) do
    joined = join_with_and(counts)

    case length(counts) do
      2 -> gettext("two seasons of %{counts}", counts: joined)
      3 -> gettext("three seasons of %{counts}", counts: joined)
      4 -> gettext("four seasons of %{counts}", counts: joined)
      5 -> gettext("five seasons of %{counts}", counts: joined)
      6 -> gettext("six seasons of %{counts}", counts: joined)
      n -> gettext("%{count} seasons of %{counts}", count: n, counts: joined)
    end
  end

  defp join_with_and([last]), do: to_string(last)

  defp join_with_and(counts) do
    {init, [last]} = Enum.split(counts, -1)
    gettext("%{init} and %{last}", init: Enum.join(init, ", "), last: last)
  end
end
