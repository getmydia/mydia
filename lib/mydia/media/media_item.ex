defmodule Mydia.Media.MediaItem do
  @moduledoc """
  Schema for media items (movies and TV shows).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type_values ~w(movie tv_show)

  schema "media_items" do
    field :type, :string
    field :title, :string
    field :original_title, :string
    field :year, :integer
    field :tmdb_id, :integer
    field :imdb_id, :string
    field :metadata, :map
    field :monitored, :boolean, default: true

    belongs_to :quality_profile, Mydia.Settings.QualityProfile
    has_many :episodes, Mydia.Media.Episode
    has_many :media_files, Mydia.Library.MediaFile
    has_many :downloads, Mydia.Downloads.Download

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a media item.
  """
  def changeset(media_item, attrs) do
    media_item
    |> cast(attrs, [
      :type,
      :title,
      :original_title,
      :year,
      :tmdb_id,
      :imdb_id,
      :metadata,
      :monitored,
      :quality_profile_id
    ])
    |> validate_required([:type, :title])
    |> validate_inclusion(:type, @type_values)
    |> validate_number(:year, greater_than: 1800, less_than: 2200)
    |> unique_constraint(:tmdb_id)
    |> foreign_key_constraint(:quality_profile_id)
  end

  @doc """
  Returns the list of valid type values.
  """
  def valid_types, do: @type_values
end
