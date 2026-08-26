defmodule Mydia.Subtitles.TrackSettings do
  @moduledoc """
  Reads and writes per-track subtitle corrections.

  `offsets_for_media_file/1` exists so a caller rendering every track of a file
  resolves all offsets in one query. The web UI and the GraphQL resolver both
  list tracks and would otherwise issue one lookup per track.

  A malformed media file id returns the same answer as an absent row rather
  than raising. Both `Delivery.content/3` and the GraphQL resolver call this on
  ids that arrive from a client, and a cast failure there is a missing setting,
  not a server error.
  """

  import Ecto.Query

  alias Mydia.Repo
  alias Mydia.Subtitles.TrackSetting

  @doc "The stored offset in milliseconds, or 0 when none is stored."
  @spec offset_ms(binary(), String.t()) :: integer()
  def offset_ms(media_file_id, track_ref) do
    TrackSetting
    |> where([s], s.media_file_id == ^media_file_id and s.track_ref == ^track_ref)
    |> select([s], s.offset_ms)
    |> Repo.one()
    |> case do
      nil -> 0
      value -> value
    end
  rescue
    Ecto.Query.CastError -> 0
  end

  @doc """
  Stores `offset_ms` for a track, replacing any previous value.
  """
  @spec set_offset(binary(), String.t(), integer()) ::
          {:ok, TrackSetting.t()} | {:error, Ecto.Changeset.t()}
  def set_offset(media_file_id, track_ref, offset_ms) do
    existing =
      Repo.get_by(TrackSetting, media_file_id: media_file_id, track_ref: track_ref) ||
        %TrackSetting{}

    existing
    |> TrackSetting.changeset(%{
      media_file_id: media_file_id,
      track_ref: track_ref,
      offset_ms: offset_ms
    })
    |> Repo.insert_or_update()
  end

  @doc "Every stored offset for a media file, keyed by `track_ref`."
  @spec offsets_for_media_file(binary()) :: %{String.t() => integer()}
  def offsets_for_media_file(media_file_id) do
    TrackSetting
    |> where([s], s.media_file_id == ^media_file_id)
    |> select([s], {s.track_ref, s.offset_ms})
    |> Repo.all()
    |> Map.new()
  rescue
    Ecto.Query.CastError -> %{}
  end

  @doc "Removes a track's stored correction, if any."
  @spec delete_for_track(binary(), String.t()) :: :ok
  def delete_for_track(media_file_id, track_ref) do
    TrackSetting
    |> where([s], s.media_file_id == ^media_file_id and s.track_ref == ^track_ref)
    |> Repo.delete_all()

    :ok
  rescue
    Ecto.Query.CastError -> :ok
  end
end
