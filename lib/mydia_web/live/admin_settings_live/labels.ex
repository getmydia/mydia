defmodule MydiaWeb.AdminSettingsLive.Labels do
  @moduledoc """
  Translated labels for the settings page.

  The page keys settings and categories by their English names (they are
  matched in events and `phx-value-*` attributes), so display text goes through
  these functions instead of the data. Config keys and env var names are data
  and stay untranslated.
  """
  use Gettext, backend: MydiaWeb.Gettext

  @doc "The heading of a settings category."
  def category(name)
  def category("Server"), do: gettext("Server")
  def category("Database"), do: gettext("Database")
  def category("Authentication"), do: gettext("Authentication")
  def category("Media"), do: gettext("Media")
  def category("Downloads"), do: gettext("Downloads")
  def category("Streaming"), do: gettext("Streaming")
  def category("Crash Reporting"), do: gettext("Crash Reporting")
  def category("Feedback"), do: gettext("Feedback")
  def category("Notifications"), do: gettext("Notifications")
  def category("Library"), do: gettext("Library")
  def category("Updates"), do: gettext("Updates")
  def category(name), do: name

  @doc "The label of the setting with config key `key`."
  def label(key)
  def label("server.port"), do: gettext("Port")
  def label("server.host"), do: gettext("Host")
  def label("server.url_scheme"), do: gettext("URL Scheme")
  def label("server.url_host"), do: gettext("URL Host")
  def label("database.path"), do: gettext("Database Path")
  def label("database.pool_size"), do: gettext("Pool Size")
  def label("auth.local_enabled"), do: gettext("Local Auth Enabled")
  def label("auth.oidc_enabled"), do: gettext("OIDC Enabled")
  def label("media.movies_path"), do: gettext("Movies Path")
  def label("media.tv_path"), do: gettext("TV Path")
  def label("downloads.monitor_interval_minutes"), do: gettext("Monitor Interval (minutes)")
  def label("downloads.min_seeders"), do: gettext("Minimum Seeders (automatic search)")
  def label("streaming.max_transcode_height"), do: gettext("Max Transcode Height")
  def label("crash_reporting.enabled"), do: gettext("Share Crashes with Developers")
  def label("feedback.enabled"), do: gettext("Show Send feedback button")
  def label("update_check.enabled"), do: gettext("Check for updates")
  def label("library.auto_repair_enabled"), do: gettext("Auto-Repair Database Issues")
  def label("library.auto_repair_threshold"), do: gettext("Auto-Repair Threshold")
  def label(key), do: key

  @doc "The help text of the setting with config key `key`, or nil."
  def description(key)

  def description("downloads.min_seeders"),
    do:
      gettext(
        "Minimum seeders a result must report for automatic searches to consider it. This is a hard filter applied before ranking, so a torrent below it is removed rather than demoted. Manual searches have their own control, and Usenet results report no seeders at all and are exempt. 0, the default, filters nothing. Careful above 0: some indexers report 0 when they mean \"unknown\" rather than \"dead\", so a floor can silently empty their results."
      )

  def description("streaming.max_transcode_height"),
    do:
      gettext(
        "Ceiling in pixels on the output height of any transcode, for example 720. Empty means no ceiling and a transcode keeps the source resolution, which a small server may not sustain in realtime for a 4K file. Never upscales, and never applies when the file is streamed without re-encoding."
      )

  def description("update_check.enabled"),
    do:
      gettext(
        "Shortly after startup and once a week, ask the metadata relay whether a newer Mydia release exists, and show it on the System page. The check sends a random install ID, the Mydia version, the CPU architecture and the database type. That also lets the developers count active installs and decide which versions and platforms to prioritise. Nothing about your library, accounts or network is sent, and the relay does not store your address."
      )

  def description("library.auto_repair_enabled"),
    do:
      gettext(
        "Automatically queue a library re-scan on startup when database issues (orphaned files) are detected"
      )

  def description("library.auto_repair_threshold"),
    do: gettext("Minimum number of issues required to trigger auto-repair")

  def description(_key), do: nil

  @doc "The placeholder of an empty setting input; nil for none."
  def placeholder("streaming.max_transcode_height"), do: gettext("no limit")
  def placeholder(_key), do: nil
end
