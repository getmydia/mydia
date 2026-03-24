defmodule Mydia.Library.MediaFile do
  @moduledoc """
  Schema for media files (multiple versions support).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "media_files" do
    field :path, :string
    field :size, :integer
    field :resolution, :string
    field :codec, :string
    field :hdr_format, :string
    field :audio_codec, :string
    field :bitrate, :integer
    field :verified_at, :utc_datetime
    field :metadata, Mydia.Settings.JsonMapType

    # Generated media content references (MD5 checksums as storage keys)
    field :cover_blob, :string
    field :sprite_blob, :string
    field :vtt_blob, :string
    field :preview_blob, :string
    field :phash, :string
    field :generated_at, :utc_datetime

    # Soft-delete: files missing from disk are trashed for 30 days before permanent deletion
    field :trashed_at, :utc_datetime

    # Relative path storage (Phase 1)
    field :relative_path, :string
    belongs_to :library_path, Mydia.Settings.LibraryPath

    belongs_to :media_item, Mydia.Media.MediaItem
    belongs_to :episode, Mydia.Media.Episode
    belongs_to :quality_profile, Mydia.Settings.QualityProfile

    timestamps(type: :utc_datetime)
  end

  @doc """
  Resolves the absolute file path from relative_path and library_path.

  The library_path association must be preloaded.

  ## Examples

      iex> file = %MediaFile{relative_path: "Movie.mkv", library_path: %LibraryPath{path: "/movies"}}
      iex> MediaFile.absolute_path(file)
      "/movies/Movie.mkv"

      iex> file = %MediaFile{relative_path: "Movie.mkv", library_path: nil}
      iex> MediaFile.absolute_path(file)
      nil
  """
  def absolute_path(%__MODULE__{relative_path: relative_path, library_path: library_path})
      when not is_nil(relative_path) and not is_nil(library_path) do
    Path.join(library_path.path, relative_path)
  end

  def absolute_path(%__MODULE__{}), do: nil

  @cast_fields [
    :media_item_id,
    :episode_id,
    :quality_profile_id,
    :path,
    :relative_path,
    :library_path_id,
    :size,
    :resolution,
    :codec,
    :hdr_format,
    :audio_codec,
    :bitrate,
    :verified_at,
    :metadata,
    :cover_blob,
    :sprite_blob,
    :vtt_blob,
    :preview_blob,
    :phash,
    :generated_at,
    :trashed_at
  ]

  @doc """
  Changeset for creating or updating a media file.

  The `media_item_id` NOT NULL constraint is enforced at the database level.
  Library type compatibility is validated by the scanner and enricher before
  file creation — not in the changeset — to avoid DB queries during validation.
  """
  def changeset(media_file, attrs) do
    media_file
    |> cast(attrs, @cast_fields)
    |> validate_required([:relative_path, :library_path_id])
    |> validate_number(:size, greater_than: 0)
    |> validate_number(:bitrate, greater_than: 0)
    |> foreign_key_constraint(:media_item_id)
    |> foreign_key_constraint(:episode_id)
    |> foreign_key_constraint(:quality_profile_id)
    |> foreign_key_constraint(:library_path_id)
  end
end
