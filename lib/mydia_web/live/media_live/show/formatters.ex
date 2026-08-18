defmodule MydiaWeb.MediaLive.Show.Formatters do
  @moduledoc """
  Formatting functions for the MediaLive.Show page.
  Handles formatting of file sizes, dates, times, download statuses, and quality information.
  """

  alias Mydia.Indexers.SearchResult

  def format_file_size(nil), do: "N/A"

  def format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776, 2)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  def format_date(nil), do: "N/A"

  def format_date(%Date{} = date) do
    Calendar.strftime(date, "%b %d, %Y")
  end

  def format_download_status("pending"), do: "Queued"
  def format_download_status("downloading"), do: "Downloading"
  def format_download_status("seeding"), do: "Seeding"
  def format_download_status("checking"), do: "Checking"
  def format_download_status("paused"), do: "Paused"
  def format_download_status("completed"), do: "Completed"
  def format_download_status("failed"), do: "Failed"
  def format_download_status("cancelled"), do: "Cancelled"
  def format_download_status("missing"), do: "Missing"
  def format_download_status("grabbing"), do: "Grabbing…"
  def format_download_status(_), do: "Unknown"

  def format_relative_time(timestamp) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, timestamp, :second)

    cond do
      diff < 60 -> "Just now"
      diff < 3600 -> "#{div(diff, 60)} minutes ago"
      diff < 86400 -> "#{div(diff, 3600)} hours ago"
      diff < 2_592_000 -> "#{div(diff, 86400)} days ago"
      diff < 31_536_000 -> "#{div(diff, 2_592_000)} months ago"
      true -> "#{div(diff, 31_536_000)} years ago"
    end
  end

  def format_absolute_time(timestamp) do
    Calendar.strftime(timestamp, "%b %d, %Y at %I:%M %p")
  end

  def format_download_quality(nil), do: "Unknown"

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
      "" -> "Unknown"
      description -> description
    end
  end

  def format_download_quality(_), do: "Unknown"

  def format_search_size(%SearchResult{} = result) do
    SearchResult.format_size(result)
  end

  def format_search_date(nil), do: "Unknown"

  def format_search_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y")
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
  def format_season_ordering_counts([single]), do: "one season of #{single}"

  def format_season_ordering_counts(counts) do
    "#{season_count_word(length(counts))} seasons of #{join_with_and(counts)}"
  end

  defp join_with_and([last]), do: to_string(last)

  defp join_with_and(counts) do
    {init, [last]} = Enum.split(counts, -1)
    Enum.join(init, ", ") <> " and #{last}"
  end

  defp season_count_word(2), do: "two"
  defp season_count_word(3), do: "three"
  defp season_count_word(4), do: "four"
  defp season_count_word(5), do: "five"
  defp season_count_word(6), do: "six"
  defp season_count_word(n), do: to_string(n)
end
