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

  @origins ~w(provider sidecar upload)

  @type t :: %__MODULE__{
          id: binary(),
          language: String.t() | nil,
          provider: String.t() | nil,
          subtitle_hash: String.t() | nil,
          file_path: String.t() | nil,
          format: String.t() | nil,
          rating: float() | nil,
          download_count: integer() | nil,
          hearing_impaired: boolean(),
          origin: String.t(),
          forced: boolean(),
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
    field :format, :string
    field :rating, :float
    field :download_count, :integer
    field :hearing_impaired, :boolean, default: false
    field :origin, :string, default: "provider"
    field :forced, :boolean, default: false

    belongs_to :media_file, Mydia.Library.MediaFile

    timestamps(type: :utc_datetime)
  end

  @doc """
  Returns list of supported subtitle formats.
  """
  def supported_formats, do: @supported_formats

  @doc """
  Returns the list of valid `origin` values.

  `provider` is a search result Mydia downloaded, `sidecar` is a file adopted
  from disk by `Mydia.Subtitles.Sidecars`, and `upload` came from the web UI.
  """
  def origins, do: @origins

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
      :format,
      :rating,
      :download_count,
      :hearing_impaired,
      :origin,
      :forced
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
    |> validate_inclusion(:origin, @origins)
    |> validate_number(:rating, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 10.0)
    |> validate_number(:download_count, greater_than_or_equal_to: 0)
    # Uniqueness is scoped to the media file, because two rips of the same movie
    # share a subtitle hash and each needs its own row.
    |> unique_constraint([:media_file_id, :subtitle_hash],
      name: :subtitles_media_file_id_subtitle_hash_index
    )
    |> foreign_key_constraint(:media_file_id)
  end
end
