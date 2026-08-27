defmodule MydiaWeb.Schema.Resolvers.SubtitleSettingsResolver do
  @moduledoc """
  Resolvers for stored subtitle timing corrections.
  """

  alias Mydia.Subtitles.TrackSettings
  alias MydiaWeb.Formatters

  @doc "Every stored correction for a media file."
  def list(_root, %{media_file_id: media_file_id}, _info) do
    settings =
      media_file_id
      |> TrackSettings.offsets_for_media_file()
      |> Enum.map(fn {track_ref, offset_ms} ->
        %{track_ref: track_ref, offset_ms: offset_ms}
      end)
      |> Enum.sort_by(& &1.track_ref)

    {:ok, settings}
  end

  @doc "Stores a correction, replacing any previous value for that track."
  def set_offset(
        _root,
        %{media_file_id: media_file_id, track_ref: track_ref, offset_ms: offset_ms},
        _info
      ) do
    case TrackSettings.set_offset(media_file_id, track_ref, offset_ms) do
      {:ok, setting} ->
        {:ok, %{track_ref: setting.track_ref, offset_ms: setting.offset_ms}}

      {:error, changeset} ->
        {:error, Formatters.format_changeset_errors(changeset)}
    end
  end
end
