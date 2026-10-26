defmodule MydiaWeb.AdminImportListsLive.Labels do
  @moduledoc """
  Translated display labels for `Mydia.ImportLists.ImportList` values.

  The domain keeps the English text and never depends on Gettext. This module
  translates by key on the web side and falls back to the domain function for a
  value it does not know.
  """

  use Gettext, backend: MydiaWeb.Gettext

  alias Mydia.ImportLists.ImportList

  @doc "Display name of a list type (`\"tmdb_trending\"` and friends)."
  @spec type_label(String.t()) :: String.t()
  def type_label("tmdb_trending"), do: gettext("TMDB Trending")
  def type_label("tmdb_popular"), do: gettext("TMDB Popular")
  def type_label("tmdb_upcoming"), do: gettext("TMDB Upcoming")
  def type_label("tmdb_now_playing"), do: gettext("TMDB Now Playing")
  def type_label("tmdb_on_the_air"), do: gettext("TMDB On The Air")
  def type_label("tmdb_airing_today"), do: gettext("TMDB Airing Today")
  def type_label("tmdb_list"), do: gettext("TMDB List")
  def type_label("custom_url"), do: gettext("Custom URL")
  def type_label(other), do: gettext_unknown(ImportList.type_label(other))

  @doc "Display text of a sync interval in minutes."
  @spec sync_interval_label(integer()) :: String.t()
  def sync_interval_label(60), do: ngettext("%{count} hour", "%{count} hours", 1)
  def sync_interval_label(360), do: ngettext("%{count} hour", "%{count} hours", 6)
  def sync_interval_label(720), do: ngettext("%{count} hour", "%{count} hours", 12)
  def sync_interval_label(1440), do: ngettext("%{count} hour", "%{count} hours", 24)
  def sync_interval_label(other), do: gettext_unknown(ImportList.sync_interval_label(other))

  @doc "Label of the config field a list type needs, or nil."
  @spec config_field_label(String.t()) :: String.t() | nil
  def config_field_label("tmdb_list"), do: gettext("TMDB List ID")
  def config_field_label("custom_url"), do: gettext("Feed URL")
  def config_field_label(other), do: ImportList.config_field_label(other)

  @doc "Placeholder of the config field a list type needs, or nil."
  @spec config_field_placeholder(String.t()) :: String.t() | nil
  def config_field_placeholder("tmdb_list"), do: gettext("e.g., 12345 or full URL")

  def config_field_placeholder("custom_url"),
    do: gettext("e.g., https://example.com/feed.json")

  def config_field_placeholder(other), do: ImportList.config_field_placeholder(other)

  # The domain returns "Unknown" for values it does not know.
  defp gettext_unknown("Unknown"), do: gettext("Unknown")
  defp gettext_unknown(label), do: label
end
