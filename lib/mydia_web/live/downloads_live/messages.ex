defmodule MydiaWeb.DownloadsLive.Messages do
  @moduledoc """
  Translated flash text, error messages and row labels for the Downloads page.
  """

  use Gettext, backend: MydiaWeb.Gettext

  import MydiaWeb.DownloadsLive.Format, only: [format_relative_time: 2]

  def batch_message(:retried, count, 0),
    do: ngettext("%{count} retried", "%{count} retried", count)

  def batch_message(:retried, count, skipped),
    do:
      ngettext(
        "%{count} retried, %{skipped} skipped",
        "%{count} retried, %{skipped} skipped",
        count,
        skipped: skipped
      )

  def batch_message(:dismissed, count, 0),
    do: ngettext("%{count} dismissed", "%{count} dismissed", count)

  def batch_message(:dismissed, count, skipped),
    do:
      ngettext(
        "%{count} dismissed, %{skipped} skipped",
        "%{count} dismissed, %{skipped} skipped",
        count,
        skipped: skipped
      )

  def mapping_error_message(changeset) do
    case changeset.errors[:remote_prefix] do
      {_msg, [{:constraint, :unique} | _]} ->
        gettext("A mapping for this path already exists. Edit it on the Path Mappings page.")

      _ ->
        reason =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
          |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)

        gettext("Couldn't add the mapping: %{reason}", reason: reason)
    end
  end

  def friendly_rematch_error(:not_imported), do: gettext("This download hasn't imported yet.")

  def friendly_rematch_error(reason) when reason in [:not_single_target, :multiple_files],
    do: gettext("This download has multiple files; per-file re-match isn't supported yet.")

  def friendly_rematch_error(:no_imported_file),
    do: gettext("Couldn't find the imported file for this download.")

  def friendly_rematch_error(:no_library_path),
    do: gettext("No matching library is configured for that title's type.")

  def friendly_rematch_error(:library_type_mismatch),
    do: gettext("That title's type doesn't match an available library.")

  def friendly_rematch_error(_), do: gettext("Re-match failed.")

  def import_issue_label(:failed), do: gettext("Import failed")
  def import_issue_label(:retrying), do: gettext("Import retrying")

  def status_age(%DateTime{} = as_of, display) do
    seconds = max(DateTime.diff(DateTime.utc_now(), as_of, :second), 0)

    if seconds < 60,
      do: gettext("%{count}s ago", count: seconds),
      else: format_relative_time(as_of, display)
  end

  def get_episode_details(download) do
    cond do
      # Download has a specific episode association
      is_map(download.episode) ->
        episode_id = format_episode_identifier(download.episode)
        episode_title = download.episode.title

        if episode_title do
          "#{episode_id} - #{episode_title}"
        else
          episode_id
        end

      # Download is for a TV show but no episode (likely season pack or series)
      is_map(download.media_item) && download.media_item.type == "tv_show" ->
        extract_season_info_from_title(download.title)

      true ->
        nil
    end
  end

  defp extract_season_info_from_title(title) do
    cond do
      # Match S01, S02, etc. (most common format)
      Regex.match?(~r/\.S(\d{1,2})(?:\.|E|$)/i, title) ->
        [_, season] = Regex.run(~r/\.S(\d{1,2})(?:\.|E|$)/i, title)
        pgettext("tv", "Season %{season}", season: String.to_integer(season))

      # Match "Season 1", "Season 01", etc.
      Regex.match?(~r/Season[\s\.]+(\d{1,2})/i, title) ->
        [_, season] = Regex.run(~r/Season[\s\.]+(\d{1,2})/i, title)
        pgettext("tv", "Season %{season}", season: String.to_integer(season))

      # If title has "Complete" or "Series" - likely full series pack
      Regex.match?(~r/(Complete|Series|Collection)/i, title) ->
        gettext("Complete Series")

      # Fallback
      true ->
        nil
    end
  end

  defp format_episode_identifier(episode) do
    season = String.pad_leading("#{episode.season_number}", 2, "0")
    episode_num = String.pad_leading("#{episode.episode_number}", 2, "0")
    "S#{season}E#{episode_num}"
  end
end
