defmodule Mydia.Subtitles.TrackSettings do
  @moduledoc """
  Reads and writes per-track subtitle corrections.

  `offsets_for_media_file/1` exists so a caller rendering every track of a file
  resolves all offsets in one query. The web UI and the GraphQL resolver both
  list tracks and would otherwise issue one lookup per track.

  A malformed media file id returns the same answer as an absent row rather
  than raising. Both `Delivery.content/3` and the GraphQL resolver call this on
  ids that arrive from a client, and a cast failure there is a missing setting,
  not a server error. `set_offset/3` applies the same rule on the write side;
  see its doc for how the two adapters get there differently.
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

  A `media_file_id` that does not reference an existing media file is reported
  as a changeset error rather than raising. The GraphQL `ID!` scalar does not
  validate UUID shape, so a client-supplied id can be malformed, and the two
  adapters fail that in different ways:

    * On PostgreSQL, a non-UUID-shaped string never reaches the database:
      `Repo.get_by/3` raises `Ecto.Query.CastError` while binding the query
      parameter. That is the read this function rescues.
    * On SQLite, any string casts as a valid `:binary_id`, so `Repo.get_by/3`
      finds no row and the write proceeds to `Repo.insert_or_update/2`, which
      fails the foreign key constraint. `Mydia.Repo.ForeignKeyGuard` turns that
      into a changeset error, covering both a malformed id and a well-formed
      but nonexistent one.
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
  rescue
    Ecto.Query.CastError ->
      {:error, missing_media_file_changeset(media_file_id, track_ref, offset_ms)}
  end

  defp missing_media_file_changeset(media_file_id, track_ref, offset_ms) do
    %TrackSetting{}
    |> TrackSetting.changeset(%{
      media_file_id: media_file_id,
      track_ref: track_ref,
      offset_ms: offset_ms
    })
    |> Ecto.Changeset.add_error(:media_file_id, "does not exist")
  end

  @doc """
  Records the outcome of a re-sync attempt without changing the stored offset.

  A skipped or failed attempt still writes a row. Without one the UI cannot
  distinguish "never attempted" from "attempted and declined", and every ingest
  of the same file would retry work already known to be fruitless.

  `state` is an atom from a fixed set, converted with `Atom.to_string/1` on the
  way in. Nothing here converts a stored string back into an atom.
  """
  @spec record_resync(binary(), String.t(), atom(), float() | nil) ::
          {:ok, TrackSetting.t()} | {:error, Ecto.Changeset.t()}
  def record_resync(media_file_id, track_ref, state, score) do
    attrs = %{
      resync_state: Atom.to_string(state),
      resync_score: score,
      resync_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    existing =
      Repo.get_by(TrackSetting, media_file_id: media_file_id, track_ref: track_ref) ||
        %TrackSetting{}

    existing
    |> TrackSetting.changeset(
      Map.merge(attrs, %{
        media_file_id: media_file_id,
        track_ref: track_ref
      })
    )
    |> Repo.insert_or_update()
  rescue
    # Guards Repo.get_by/3 above: on PostgreSQL a malformed media_file_id
    # raises while binding the query parameter, before any write. The foreign
    # key half of this is handled for every write by
    # Mydia.Repo.ForeignKeyGuard. See set_offset/3's doc.
    Ecto.Query.CastError ->
      {:error, unknown_media_file_changeset(track_ref)}
  end

  defp unknown_media_file_changeset(track_ref) do
    %TrackSetting{}
    |> TrackSetting.changeset(%{track_ref: track_ref})
    |> Ecto.Changeset.add_error(:media_file_id, "does not exist")
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

  @doc "Every stored resync outcome for a media file, keyed by `track_ref`."
  @spec resync_states_for_media_file(binary()) :: %{String.t() => String.t()}
  def resync_states_for_media_file(media_file_id) do
    TrackSetting
    |> where([s], s.media_file_id == ^media_file_id and not is_nil(s.resync_state))
    |> select([s], {s.track_ref, s.resync_state})
    |> Repo.all()
    |> Map.new()
  rescue
    Ecto.Query.CastError -> %{}
  end

  @doc """
  Every stored offset for a list of media files, keyed by `media_file_id` then
  `track_ref`.

  Exists so the media detail page issues one query instead of one per file. A
  file with no stored settings is absent from the result rather than mapped to
  an empty map, which lets a caller use `Map.get(result, id, %{})` and get the
  same answer either way.
  """
  @spec offsets_for_media_files([binary()]) :: %{binary() => %{String.t() => integer()}}
  def offsets_for_media_files([]), do: %{}

  def offsets_for_media_files(media_file_ids) do
    TrackSetting
    |> where([s], s.media_file_id in ^media_file_ids)
    |> select([s], {s.media_file_id, s.track_ref, s.offset_ms})
    |> Repo.all()
    |> group_by_media_file()
  rescue
    Ecto.Query.CastError -> %{}
  end

  @doc """
  Every stored resync outcome for a list of media files, keyed by
  `media_file_id` then `track_ref`. Tracks with no recorded outcome are omitted.
  """
  @spec resync_states_for_media_files([binary()]) :: %{binary() => %{String.t() => String.t()}}
  def resync_states_for_media_files([]), do: %{}

  def resync_states_for_media_files(media_file_ids) do
    TrackSetting
    |> where([s], s.media_file_id in ^media_file_ids and not is_nil(s.resync_state))
    |> select([s], {s.media_file_id, s.track_ref, s.resync_state})
    |> Repo.all()
    |> group_by_media_file()
  rescue
    Ecto.Query.CastError -> %{}
  end

  defp group_by_media_file(rows) do
    Enum.group_by(rows, fn {media_file_id, _ref, _value} -> media_file_id end)
    |> Map.new(fn {media_file_id, entries} ->
      {media_file_id, Map.new(entries, fn {_id, ref, value} -> {ref, value} end)}
    end)
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
