defmodule Mydia.Settings.LibraryPath do
  @moduledoc """
  Schema for library paths that should be monitored for media files.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Mydia.Media.MediaCategory

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary(),
          path: String.t() | nil,
          type: atom() | nil,
          monitored: boolean(),
          scan_interval: integer() | nil,
          last_scan_at: DateTime.t() | nil,
          last_scan_status: atom() | nil,
          last_scan_error: String.t() | nil,
          from_env: boolean(),
          disabled: boolean(),
          category_paths: map(),
          auto_organize: boolean(),
          auto_import: boolean(),
          write_nfo: boolean(),
          auto_rename: boolean(),
          tv_metadata_source: atom() | nil,
          default_for_movies: boolean(),
          default_for_series: boolean(),
          quality_profile:
            Mydia.Settings.QualityProfile.t() | nil | Ecto.Association.NotLoaded.t(),
          quality_profile_id: binary() | nil,
          updated_by: Mydia.Accounts.User.t() | nil | Ecto.Association.NotLoaded.t(),
          updated_by_id: binary() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @path_types [:movies, :series, :mixed, :music, :books, :adult]
  @movie_library_types [:movies, :mixed]
  @series_library_types [:series, :mixed]
  @scan_statuses [:success, :failed, :in_progress]
  @tv_metadata_sources [:tvdb, :tmdb]

  @doc "Library types that can serve as the default target for each media kind."
  def movie_library_types, do: @movie_library_types
  def series_library_types, do: @series_library_types

  @doc "Valid TV metadata source providers for series/mixed libraries."
  def tv_metadata_sources, do: @tv_metadata_sources

  schema "library_paths" do
    field :path, :string
    field :type, Ecto.Enum, values: @path_types
    field :monitored, :boolean, default: true
    field :scan_interval, :integer
    field :last_scan_at, :utc_datetime
    field :last_scan_status, Ecto.Enum, values: @scan_statuses
    field :last_scan_error, :string
    # Tracks if this library path was created from environment variables
    field :from_env, :boolean, default: false
    # Controls whether the library path is hidden from the UI
    field :disabled, :boolean, default: false
    # Map of category -> relative path for auto-organization
    field :category_paths, :map, default: %{}
    # Enable/disable auto-organization for this library
    field :auto_organize, :boolean, default: false
    # Enable/disable automatic record creation from discovered files
    field :auto_import, :boolean, default: false
    # Enable/disable writing Jellyfin-compatible NFO metadata files alongside media files
    field :write_nfo, :boolean, default: false
    # Enable/disable automatic file renaming on import (TRaSH Guides format)
    field :auto_rename, :boolean, default: true
    # Metadata provider for TV shows in this library (series/mixed only)
    field :tv_metadata_source, Ecto.Enum, values: @tv_metadata_sources, default: :tvdb
    # At most one library per media kind may be the default download target.
    field :default_for_movies, :boolean, default: false
    field :default_for_series, :boolean, default: false

    belongs_to :quality_profile, Mydia.Settings.QualityProfile
    belongs_to :updated_by, Mydia.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a library path.
  """
  def changeset(library_path, attrs) do
    library_path
    |> cast(attrs, [
      :path,
      :type,
      :monitored,
      :scan_interval,
      :last_scan_at,
      :last_scan_status,
      :last_scan_error,
      :quality_profile_id,
      :updated_by_id,
      :from_env,
      :disabled,
      :category_paths,
      :auto_organize,
      :auto_import,
      :write_nfo,
      :auto_rename,
      :tv_metadata_source,
      :default_for_movies,
      :default_for_series
    ])
    |> validate_required([:path, :type])
    |> validate_inclusion(:type, @path_types)
    |> validate_inclusion(:tv_metadata_source, @tv_metadata_sources)
    |> validate_number(:scan_interval, greater_than_or_equal_to: 900)
    |> validate_category_paths()
    |> validate_default_flag_types()
    |> unique_constraint(:default_for_movies,
      name: :library_paths_single_default_for_movies,
      message: "another library is already the default for movies"
    )
    |> unique_constraint(:default_for_series,
      name: :library_paths_single_default_for_series,
      message: "another library is already the default for series"
    )
    |> unique_constraint(:path)
  end

  @doc """
  Validates that category_paths keys are valid MediaCategory values.
  """
  def validate_category_paths(changeset) do
    case get_change(changeset, :category_paths) do
      nil ->
        changeset

      category_paths when is_map(category_paths) ->
        invalid_keys =
          category_paths
          |> Map.keys()
          |> Enum.reject(&valid_category_key?/1)

        if invalid_keys == [] do
          changeset
        else
          add_error(
            changeset,
            :category_paths,
            "contains invalid category keys: #{Enum.join(invalid_keys, ", ")}"
          )
        end

      _ ->
        add_error(changeset, :category_paths, "must be a map")
    end
  end

  defp valid_category_key?(key) when is_binary(key) do
    # Use MediaCategory.all() to check if the string matches a valid category
    # This avoids issues with String.to_existing_atom when the atom isn't loaded yet
    valid_keys = MediaCategory.all() |> Enum.map(&Atom.to_string/1)
    key in valid_keys
  end

  defp valid_category_key?(key) when is_atom(key), do: MediaCategory.valid?(key)
  defp valid_category_key?(_), do: false

  @doc """
  Rejects a default flag the library's own `type` cannot serve.

  A :movies library cannot be the series default, and vice versa. A :mixed
  library may hold both.
  """
  def validate_default_flag_types(changeset) do
    type = get_field(changeset, :type)

    changeset
    |> validate_flag_for_type(:default_for_movies, type, @movie_library_types, "movies")
    |> validate_flag_for_type(:default_for_series, type, @series_library_types, "series")
  end

  defp validate_flag_for_type(changeset, field, type, allowed_types, kind_label) do
    if get_field(changeset, field) && type not in allowed_types do
      add_error(
        changeset,
        field,
        "cannot be the default #{kind_label} library for a #{type} library"
      )
    else
      changeset
    end
  end

  @doc """
  Resolves the full destination path for a media item based on its category.

  If the library has auto_organize enabled and a category path is configured
  for the given category, returns: library_path / category_path / media_folder

  Otherwise returns: library_path / media_folder

  ## Examples

      iex> library = %LibraryPath{path: "/media/movies", category_paths: %{"anime_movie" => "Anime"}, auto_organize: true}
      iex> resolve_category_path(library, :anime_movie, "Spirited Away (2001)")
      "/media/movies/Anime/Spirited Away (2001)"

      iex> library = %LibraryPath{path: "/media/movies", category_paths: %{}, auto_organize: false}
      iex> resolve_category_path(library, :movie, "The Matrix (1999)")
      "/media/movies/The Matrix (1999)"
  """
  @spec resolve_category_path(%__MODULE__{}, atom() | String.t(), String.t()) :: String.t()
  def resolve_category_path(%__MODULE__{} = library_path, category, media_folder) do
    category_key = if is_atom(category), do: Atom.to_string(category), else: category

    category_subpath =
      if library_path.auto_organize do
        Map.get(library_path.category_paths || %{}, category_key)
      end

    case category_subpath do
      nil -> Path.join(library_path.path, media_folder)
      subpath -> Path.join([library_path.path, subpath, media_folder])
    end
  end
end
