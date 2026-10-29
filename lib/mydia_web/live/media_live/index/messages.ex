defmodule MydiaWeb.MediaLive.Index.Messages do
  @moduledoc """
  Translated flash text and labels for the media library listing.
  """
  use Gettext, backend: MydiaWeb.Gettext

  alias Mydia.Media.AvailabilityStatus

  def batch_monitored_message(count, true),
    do: ngettext("%{count} item set to monitored", "%{count} items set to monitored", count)

  def batch_monitored_message(count, false),
    do: ngettext("%{count} item set to unmonitored", "%{count} items set to unmonitored", count)

  def auto_search_flash(0, 0), do: gettext("Nothing to search")

  def auto_search_flash(0, 1),
    do: gettext("Nothing to search. The selected item does not need a search.")

  def auto_search_flash(0, skipped) do
    gettext("Nothing to search. None of the %{skipped} selected items need a search.",
      skipped: skipped
    )
  end

  def auto_search_flash(queued, 0) do
    ngettext("Queued %{count} search", "Queued %{count} searches", queued)
  end

  def auto_search_flash(queued, 1) do
    ngettext(
      "Queued %{count} search, skipped 1 that does not need one",
      "Queued %{count} searches, skipped 1 that does not need one",
      queued
    )
  end

  def auto_search_flash(queued, skipped) do
    ngettext(
      "Queued %{count} search, skipped %{skipped} that do not need one",
      "Queued %{count} searches, skipped %{skipped} that do not need one",
      queued,
      skipped: skipped
    )
  end

  def format_episode_count(%AvailabilityStatus{downloaded: downloaded, total: total})
      when is_integer(downloaded) and is_integer(total),
      do: gettext("%{downloaded}/%{total} episodes", downloaded: downloaded, total: total)

  def format_episode_count(_), do: nil

  @doc false
  # `auto_linked` is a subset of the files a scan touched, so it is appended as
  # detail and kept out of the change total. It is also counted on its own,
  # because the orphan branch links existing files: a scan can auto-import
  # without any on-disk change at all, and reporting "No changes detected"
  # there would hide the exact work the flag was turned on for.
  @spec scan_completed_message(map()) :: String.t()
  def scan_completed_message(%{
        new_files: new_files,
        modified_files: modified_files,
        deleted_files: deleted_files,
        auto_linked: auto_linked
      }) do
    parts = []

    parts =
      if new_files > 0,
        do: [gettext("%{count} new", count: new_files) | parts],
        else: parts

    parts =
      if modified_files > 0,
        do: [gettext("%{count} modified", count: modified_files) | parts],
        else: parts

    parts =
      if deleted_files > 0,
        do: [gettext("%{count} removed", count: deleted_files) | parts],
        else: parts

    parts =
      if auto_linked > 0,
        do: parts ++ [gettext("%{count} imported automatically", count: auto_linked)],
        else: parts

    if parts == [] do
      gettext("Library scan completed: No changes detected")
    else
      gettext("Library scan completed: %{changes}", changes: Enum.join(parts, ", "))
    end
  end
end
