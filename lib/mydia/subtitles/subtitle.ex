defmodule Mydia.Subtitles.Subtitle do
  @moduledoc """
  Schema for subtitle files.

  Stores metadata about downloaded subtitle files including their location,
  language, format, and relationship to media files.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @supported_formats ["srt", "ass", "vtt"]

  @type t :: %__MODULE__{
          id: binary(),
          language: String.t() | nil,
          provider: String.t() | nil,
          subtitle_hash: String.t() | nil,
          file_path: String.t() | nil,
          sync_offset: integer(),
          format: String.t() | nil,
          rating: float() | nil,
          download_count: integer() | nil,
          hearing_impaired: boolean(),
          media_file: Mydia.Library.MediaFile.t() | Ecto.Association.NotLoaded.t(),
          media_file_id: binary() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "subtitles" do
    field :language, :string
    field :provider, :string
    field :subtitle_hash, :string
    field :file_path, :string
    field :sync_offset, :integer, default: 0
    field :format, :string
    field :rating, :float
    field :download_count, :integer
    field :hearing_impaired, :boolean, default: false

    belongs_to :media_file, Mydia.Library.MediaFile

    timestamps(type: :utc_datetime)
  end

  @doc """
  Returns list of supported subtitle formats.
  """
  def supported_formats, do: @supported_formats

  @doc """
  Changeset for creating or updating a subtitle.
  """
  def changeset(subtitle, attrs) do
    subtitle
    |> cast(attrs, [
      :media_file_id,
      :language,
      :provider,
      :subtitle_hash,
      :file_path,
      :sync_offset,
      :format,
      :rating,
      :download_count,
      :hearing_impaired
    ])
    |> validate_required([
      :media_file_id,
      :language,
      :provider,
      :subtitle_hash,
      :file_path,
      :format
    ])
    |> validate_inclusion(:format, @supported_formats)
    |> validate_number(:rating, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 10.0)
    |> validate_number(:download_count, greater_than_or_equal_to: 0)
    # Scoped to the media file on purpose: two rips of the same movie can
    # legitimately share a subtitle_hash (see migration 20260812010000), so
    # uniqueness must be per {media_file_id, subtitle_hash}, not global.
    |> unique_constraint([:media_file_id, :subtitle_hash])
    |> foreign_key_constraint(:media_file_id)
  end
end
