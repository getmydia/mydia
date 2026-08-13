defmodule Mydia.Media.MediaItem do
  @moduledoc """
  Schema for media items (movies and TV shows).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary(),
          type: String.t() | nil,
          title: String.t() | nil,
          original_title: String.t() | nil,
          year: integer() | nil,
          tmdb_id: integer() | nil,
          tvdb_id: integer() | nil,
          imdb_id: String.t() | nil,
          metadata_source: atom() | nil,
          metadata: Mydia.Metadata.Structs.MediaMetadata.t() | nil,
          monitored: boolean(),
          monitoring_preset: atom(),
          monitor_new_seasons: :all | :none,
          category: String.t() | nil,
          category_override: boolean(),
          seasons_refreshed_at: DateTime.t() | nil,
          last_upgrade_check_at: DateTime.t() | nil,
          quality_profile: Mydia.Settings.QualityProfile.t() | Ecto.Association.NotLoaded.t(),
          library_path: Mydia.Settings.LibraryPath.t() | nil | Ecto.Association.NotLoaded.t(),
          library_path_id: binary() | nil,
          episodes: [Mydia.Media.Episode.t()] | Ecto.Association.NotLoaded.t(),
          media_files: [Mydia.Library.MediaFile.t()] | Ecto.Association.NotLoaded.t(),
          downloads: [Mydia.Downloads.Download.t()] | Ecto.Association.NotLoaded.t(),
          media_requests: [Mydia.Media.MediaRequest.t()] | Ecto.Association.NotLoaded.t(),
          playback_progress: [Mydia.Playback.Progress.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @type_values ~w(movie tv_show)

  schema "media_items" do
    field :type, :string
    field :title, :string
    field :original_title, :string
    field :year, :integer
    field :tmdb_id, :integer
    field :tvdb_id, :integer
    field :imdb_id, :string
    # Authoritative provider that supplied this item's current metadata
    # (tv_show only; movies stay nil). Source of truth for provider-aware
    # refresh — not inferred from tvdb_id/tmdb_id presence.
    field :metadata_source, Ecto.Enum, values: [:tvdb, :tmdb]
    field :metadata, Mydia.Media.MetadataType
    field :monitored, :boolean, default: true

    field :monitoring_preset, Ecto.Enum,
      values: [:all, :future, :missing, :existing, :first_season, :latest_season, :none],
      default: :all

    # Governs only seasons that do not exist yet. Whether a new episode in an
    # *existing* season is monitored is derived from that season's episodes.
    field :monitor_new_seasons, Ecto.Enum, values: [:all, :none], default: :all

    field :category, :string
    field :category_override, :boolean, default: false
    field :seasons_refreshed_at, :utc_datetime
    # Set programmatically by the upgrade sweep; never cast from user input.
    field :last_upgrade_check_at, :utc_datetime

    belongs_to :quality_profile, Mydia.Settings.QualityProfile
    belongs_to :library_path, Mydia.Settings.LibraryPath
    has_many :episodes, Mydia.Media.Episode
    has_many :media_files, Mydia.Library.MediaFile
    has_many :downloads, Mydia.Downloads.Download
    has_many :media_requests, Mydia.Media.MediaRequest
    has_many :playback_progress, Mydia.Playback.Progress

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
      :tvdb_id,
      :imdb_id,
      :metadata_source,
      :metadata,
      :monitored,
      :monitoring_preset,
      :monitor_new_seasons,
      :quality_profile_id,
      :library_path_id
    ])
    |> validate_required([:type, :title])
    |> validate_inclusion(:type, @type_values)
    |> validate_number(:year, greater_than: 1800, less_than: 2200)
    |> validate_year_for_movies()
    |> unique_constraint(:tmdb_id)
    |> unique_constraint(:tvdb_id)
    |> foreign_key_constraint(:quality_profile_id)
    |> foreign_key_constraint(:library_path_id)
  end

  # Custom validation to ensure movies have year data
  defp validate_year_for_movies(changeset) do
    type = get_field(changeset, :type)
    year = get_field(changeset, :year)

    if type == "movie" && is_nil(year) do
      add_error(changeset, :year, "is required for movies")
    else
      changeset
    end
  end

  @doc """
  Changeset for updating the category of a media item.

  When `override` is true, sets `category_override` to true, preventing
  automatic re-classification on metadata refresh.
  """
  def category_changeset(media_item, category, opts \\ []) do
    override = Keyword.get(opts, :override, false)

    media_item
    |> cast(%{category: to_string(category), category_override: override}, [
      :category,
      :category_override
    ])
    |> validate_category()
  end

  @doc """
  Changeset to clear the category override flag, allowing auto-classification.
  """
  def clear_category_override_changeset(media_item) do
    media_item
    |> cast(%{category_override: false}, [:category_override])
  end

  defp validate_category(changeset) do
    alias Mydia.Media.MediaCategory

    category = get_field(changeset, :category)

    if category && not MediaCategory.valid?(String.to_existing_atom(category)) do
      add_error(changeset, :category, "is not a valid category")
    else
      changeset
    end
  rescue
    ArgumentError ->
      add_error(changeset, :category, "is not a valid category")
  end

  @doc """
  Returns the list of valid type values.
  """
  def valid_types, do: @type_values
end
