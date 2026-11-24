defmodule MydiaWeb.Schema.Resolvers.SubtitleSettingsResolver do
  @moduledoc """
  Resolvers for stored subtitle timing corrections.

  A correction is stored per file and track, not per user, so writing one
  changes playback for every viewer. Writing therefore takes a role that can
  update media, the same rule `MediaLive.Show` applies to its offset controls.
  A view-only player still nudges locally; only its Save is refused. Both
  fields also take only a file the caller's scope can see, and answer for a
  hidden file exactly as for a missing one.
  """

  alias Mydia.Accounts.Authorization
  alias Mydia.Media
  alias Mydia.Subtitles.TrackSettings
  alias MydiaWeb.Formatters

  @doc "Every stored correction for a media file."
  def list(_root, %{media_file_id: media_file_id}, %{context: context}) do
    case Media.authorize_media_file_id(context[:current_scope], media_file_id) do
      {:ok, _file} ->
        settings =
          media_file_id
          |> TrackSettings.offsets_for_media_file()
          |> Enum.map(fn {track_ref, offset_ms} ->
            %{track_ref: track_ref, offset_ms: offset_ms}
          end)
          |> Enum.sort_by(& &1.track_ref)

        {:ok, settings}

      :denied ->
        {:ok, []}
    end
  end

  @doc "Stores a correction, replacing any previous value for that track."
  def set_offset(
        _root,
        %{media_file_id: media_file_id, track_ref: track_ref, offset_ms: offset_ms},
        %{context: context}
      ) do
    scope = context[:current_scope]

    with :ok <- authorize_write(scope),
         {:ok, _file} <- visible_file(scope, media_file_id),
         {:ok, setting} <- TrackSettings.set_offset(media_file_id, track_ref, offset_ms) do
      {:ok, %{track_ref: setting.track_ref, offset_ms: setting.offset_ms}}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, Formatters.format_changeset_errors(changeset)}

      {:error, message} ->
        {:error, message}
    end
  end

  defp authorize_write(scope) do
    if Authorization.can_update_media?(scope),
      do: :ok,
      else: {:error, "You do not have permission to change subtitle timing"}
  end

  defp visible_file(scope, media_file_id) do
    case Media.authorize_media_file_id(scope, media_file_id) do
      {:ok, file} -> {:ok, file}
      :denied -> {:error, "Media file not found"}
    end
  end
end
