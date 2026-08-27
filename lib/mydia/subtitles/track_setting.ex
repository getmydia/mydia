defmodule Mydia.Subtitles.TrackSetting do
  @moduledoc """
  A per-track correction applied to one subtitle track of one media file.

  `track_ref` identifies the track the same way the GraphQL wire does: the
  stringified ffprobe stream index for an embedded track, or a
  `Mydia.Subtitles.Subtitle` id for a sidecar. Reusing that representation
  means there is no second identity concept to keep in step with
  `Mydia.Subtitles.Delivery.content/3`, which already dispatches on exactly
  that split.

  Embedded tracks are the reason this is a separate table rather than columns
  on `subtitles`: an embedded track has no `subtitles` row, because that table
  holds sidecar files.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Ten minutes either way. Past this a subtitle is for a different cut of the
  # film, not a mistimed one, and the bound keeps a stray paste out of the
  # database.
  @max_offset_ms 600_000

  @type t :: %__MODULE__{
          id: binary(),
          media_file_id: binary() | nil,
          track_ref: String.t() | nil,
          offset_ms: integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "subtitle_track_settings" do
    field :track_ref, :string
    field :offset_ms, :integer, default: 0

    belongs_to :media_file, Mydia.Library.MediaFile

    timestamps(type: :utc_datetime)
  end

  @doc "The largest offset magnitude this table will store, in milliseconds."
  def max_offset_ms, do: @max_offset_ms

  def changeset(track_setting, attrs) do
    track_setting
    |> cast(attrs, [:media_file_id, :track_ref, :offset_ms])
    |> validate_required([:media_file_id, :track_ref])
    |> validate_number(:offset_ms,
      greater_than_or_equal_to: -@max_offset_ms,
      less_than_or_equal_to: @max_offset_ms
    )
    |> unique_constraint([:media_file_id, :track_ref],
      name: :subtitle_track_settings_media_file_id_track_ref_index
    )
    |> foreign_key_constraint(:media_file_id)
  end
end
