defmodule MydiaWeb.DashboardLive.Text do
  @moduledoc """
  Display text helpers for the dashboard: byte sizes, episode lines and request errors.
  """

  use Gettext, backend: MydiaWeb.Gettext

  alias Mydia.Media
  alias MydiaWeb.Live.Helpers.MediaAddHelpers

  def format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"

  def format_bytes(bytes) when bytes < 1024 * 1024 do
    kb = bytes / 1024
    "#{Float.round(kb, 1)} KB"
  end

  def format_bytes(bytes) when bytes < 1024 * 1024 * 1024 do
    mb = bytes / (1024 * 1024)
    "#{Float.round(mb, 1)} MB"
  end

  def format_bytes(bytes) when bytes < 1024 * 1024 * 1024 * 1024 do
    gb = bytes / (1024 * 1024 * 1024)
    "#{Float.round(gb, 1)} GB"
  end

  def format_bytes(bytes) do
    tb = bytes / (1024 * 1024 * 1024 * 1024)
    "#{Float.round(tb, 2)} TB"
  end

  # "S01E02 - Episode title" for the Your Activity lists.
  def episode_line(episode) do
    gettext("S%{season}E%{episode} - %{title}",
      season: String.pad_leading(to_string(episode.season_number), 2, "0"),
      episode: String.pad_leading(to_string(episode.episode_number), 2, "0"),
      title: episode.title
    )
  end

  def request_error_message(:duplicate_media),
    do: gettext("That title is already in the library.")

  def request_error_message(:duplicate_request),
    do: gettext("Someone has already requested that title.")

  def request_error_message(:restricted), do: Media.restricted_message()

  def request_error_message(%Ecto.Changeset{} = changeset),
    do:
      gettext("Could not submit the request: %{reason}",
        reason: MediaAddHelpers.format_changeset_errors(changeset)
      )

  def request_error_message(_), do: gettext("Could not submit the request. Please try again.")
end
