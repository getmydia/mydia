defmodule Mydia.Subtitles.TrackSettings do
  @moduledoc """
  Reads and writes per-track subtitle corrections.

  `offsets_for_media_file/1` exists so a caller rendering every track of a file
  resolves all offsets in one query. The web UI and the GraphQL resolver both
  list tracks and would otherwise issue one lookup per track.

  A malformed media file id returns the same answer as an absent row rather
  than raising. Both `Delivery.content/3` and the GraphQL resolver call this on
  ids that arrive from a client, and a cast failure there is a missing setting,
  not a server error. `set_offset/3` applies the same rule on the write side,
  reporting a bad id as a changeset error instead of raising; see its doc for
  why that needs two rescue clauses rather than one.
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

  A `media_file_id` that does not reference an existing media file is
  reported as a changeset error rather than raising. The GraphQL `ID!`
  scalar does not validate UUID shape, so a client-supplied id can be
  malformed, and the two adapters fail that in different ways:

    * On PostgreSQL, a non-UUID-shaped string never reaches the database:
      `Repo.get_by/3` raises `Ecto.Query.CastError` while binding the query
      parameter.
    * On SQLite, any string casts as a valid `:binary_id`, so `Repo.get_by/3`
      just finds no row and the write proceeds to `Repo.insert_or_update/2`,
      which fails the foreign key constraint instead. `ecto_sqlite3` cannot
      recover *which* constraint failed from SQLite's error message (see
      `to_constraints/2` in its connection module, which maps every foreign
      key violation to a nameless `nil`), so the changeset's own
      `foreign_key_constraint/3` can never match it by name and Ecto
      re-raises as `Ecto.ConstraintError` instead of returning `{:error,
      changeset}`. The same path also fires for a well-formed but
      nonexistent id on SQLite, not only a malformed one.

  Catching both keeps callers, including the GraphQL resolver, adapter
  agnostic: either failure mode becomes a normal `{:error, changeset}`
  instead of a 500.
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

    error in Ecto.ConstraintError ->
      if error.type == :foreign_key do
        {:error, missing_media_file_changeset(media_file_id, track_ref, offset_ms)}
      else
        reraise error, __STACKTRACE__
      end
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
        track_ref: track_ref,
        offset_ms: existing.offset_ms || 0
      })
    )
    |> Repo.insert_or_update()
  rescue
    # Mirrors set_offset/3 in this module, and for the same reason. A malformed
    # media_file_id fails differently per adapter: PostgreSQL raises CastError
    # while binding the query parameter, while SQLite casts any string as a
    # valid :binary_id and fails later on the foreign key, which ecto_sqlite3
    # cannot attribute to a named constraint and so re-raises as
    # ConstraintError. Catching both keeps callers adapter agnostic. Read
    # set_offset/3's doc before touching these two clauses.
    Ecto.Query.CastError -> {:error, unknown_media_file_changeset(track_ref)}
    Ecto.ConstraintError -> {:error, unknown_media_file_changeset(track_ref)}
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
