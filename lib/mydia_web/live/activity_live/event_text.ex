defmodule MydiaWeb.ActivityLive.EventText do
  @moduledoc """
  Translated event titles for the activity feed and the per-media timeline.

  `Mydia.Events.Presentation` keeps the English title and the contextual detail
  (which is mostly the event's own data) and never depends on Gettext. This
  module translates the title by event type, one clause per registered type,
  and falls back to the title the domain computed (a humanized type key for an
  unregistered one).
  """

  use Gettext, backend: MydiaWeb.Gettext

  alias Mydia.Events.Event
  alias Mydia.Events.Presentation

  @doc "The translated title of an event."
  @spec title(Event.t()) :: String.t()
  def title(%Event{type: type} = event), do: title(type, Presentation.for_event(event).title)

  @doc "The translated title for `type`, or `fallback` when the type has none."
  @spec title(String.t(), String.t()) :: String.t()
  def title("media_item.added", _fallback), do: gettext("Added to library")
  def title("media_item.updated", _fallback), do: pgettext("event title", "Updated")
  def title("media_item.removed", _fallback), do: gettext("Removed from library")
  def title("media_item.monitoring_changed", _fallback), do: gettext("Monitoring changed")
  def title("media_item.episodes_refreshed", _fallback), do: gettext("Episodes refreshed")

  def title("media_item.episode_titles_updated", _fallback),
    do: gettext("Episode titles updated")

  def title("media_item.duplicate_provider_id", _fallback),
    do: gettext("Duplicate provider id skipped")

  def title("media_file.imported", _fallback), do: gettext("File imported")
  def title("media_file.upgraded", _fallback), do: gettext("File upgraded")
  def title("media_file.upgrade_rejected", _fallback), do: gettext("Upgrade rejected")
  def title("media_file.pruned", _fallback), do: gettext("Duplicate pruned")
  def title("media_file.returned_to_review", _fallback), do: gettext("Returned to review")
  def title("media_file.prune_undone", _fallback), do: gettext("Duplicate prune undone")
  def title("download.initiated", _fallback), do: gettext("Download started")
  def title("download.adopted", _fallback), do: gettext("Adopted from download client")
  def title("download.completed", _fallback), do: gettext("Download completed")
  def title("download.failed", _fallback), do: gettext("Download failed")
  def title("download.cancelled", _fallback), do: gettext("Download cancelled")
  def title("download.paused", _fallback), do: gettext("Download paused")
  def title("download.resumed", _fallback), do: gettext("Download resumed")
  def title("download.stalled", _fallback), do: gettext("Download stalled")
  def title("download.unstalled", _fallback), do: gettext("Download recovered")
  def title("download.auto_reject_suppressed", _fallback), do: gettext("Auto-reject suppressed")
  def title("download.cleared", _fallback), do: gettext("Download cleared")
  def title("job.executed", _fallback), do: gettext("Job executed")
  def title("job.failed", _fallback), do: gettext("Job failed")
  def title("search.started", _fallback), do: gettext("Search started")
  def title("search.completed", _fallback), do: gettext("Search completed")
  def title("search.no_results", _fallback), do: gettext("No results")
  def title("search.filtered_out", _fallback), do: gettext("All results filtered out")
  def title("search.deferred", _fallback), do: gettext("Grab delayed")
  def title("search.identity_shadow", _fallback), do: gettext("Identity check disagreed")
  def title("search.error", _fallback), do: gettext("Search failed")
  def title("search.backoff_applied", _fallback), do: gettext("Search backoff applied")
  def title("search.backoff_reset", _fallback), do: gettext("Search backoff cleared")
  def title("plugin.http_request", _fallback), do: gettext("Plugin request")
  def title("plugin.update_available", _fallback), do: gettext("Plugin update available")
  def title("playback.started", _fallback), do: gettext("Playback started")
  def title("playback.progressed", _fallback), do: gettext("Playback progressed")
  def title("playback.paused", _fallback), do: gettext("Playback paused")
  def title("playback.finished", _fallback), do: gettext("Playback finished")
  def title("playback.unwatched", _fallback), do: gettext("Marked unwatched")
  def title(_type, fallback), do: fallback

  @doc "Timeline text for an event that has no contextual detail."
  @spec no_detail() :: String.t()
  def no_detail, do: gettext("Event occurred")

  @doc "Translated name of a changed `media_item.updated` field."
  @spec field_label(term()) :: String.t()
  def field_label(field) when is_atom(field) and not is_nil(field),
    do: field_label(Atom.to_string(field))

  def field_label("title"), do: pgettext("changed field", "Title")
  def field_label("original_title"), do: gettext("Original Title")
  def field_label("year"), do: pgettext("changed field", "Year")
  def field_label("monitored"), do: pgettext("changed field", "Monitoring")
  def field_label("monitor_new_seasons"), do: gettext("New season monitoring")
  def field_label("category"), do: pgettext("changed field", "Category")
  def field_label("category_override"), do: gettext("Category override")
  def field_label("tmdb_id"), do: gettext("TMDB ID")
  def field_label("tvdb_id"), do: gettext("TVDB ID")
  def field_label("overview"), do: pgettext("changed field", "Description")
  def field_label("poster"), do: pgettext("changed field", "Poster")
  def field_label("backdrop"), do: pgettext("changed field", "Backdrop")
  def field_label("tagline"), do: pgettext("changed field", "Tagline")
  def field_label("rating"), do: pgettext("changed field", "Rating")
  def field_label("runtime"), do: pgettext("changed field", "Runtime")
  def field_label("genres"), do: pgettext("changed field", "Genres")
  def field_label("cast"), do: pgettext("changed field", "Cast")
  def field_label("crew"), do: pgettext("changed field", "Crew")
  def field_label(other), do: Presentation.field_label(other)
end
