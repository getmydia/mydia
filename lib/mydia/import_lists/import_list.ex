defmodule Mydia.ImportLists.ImportList do
  @moduledoc """
  Schema for import lists.

  An import list represents a configuration for syncing media from external sources
  like TMDB trending/popular lists. Each list can be enabled/disabled and configured
  with sync intervals, auto-add settings, and target quality profiles.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type_values ~w(
    tmdb_trending
    tmdb_popular
    tmdb_upcoming
    tmdb_now_playing
    tmdb_on_the_air
    tmdb_airing_today
    tmdb_list
    custom_url
  )

  @media_type_values ~w(movie tv_show)

  # Types restricted to a single media type. TMDB has no "upcoming TV shows"
  # or "now playing TV shows" endpoint, and no "movies on the air" or
  # "movies airing today" endpoint, so pairing these types with the wrong
  # media_type has no real target and must be rejected up front rather than
  # silently fetching the wrong content (see
  # Mydia.ImportLists.Provider.TMDB.build_endpoint/2).
  @movie_only_types ~w(tmdb_upcoming tmdb_now_playing)
  @tv_only_types ~w(tmdb_on_the_air tmdb_airing_today)

  @sync_interval_values [60, 360, 720, 1440]

  @type t :: %__MODULE__{
          id: binary(),
          name: String.t() | nil,
          type: String.t() | nil,
          media_type: String.t() | nil,
          enabled: boolean(),
          sync_interval: integer(),
          auto_add: boolean(),
          monitored: boolean(),
          config: map(),
          last_synced_at: DateTime.t() | nil,
          sync_error: String.t() | nil,
          list_url: String.t() | nil,
          quality_profile: Mydia.Settings.QualityProfile.t() | Ecto.Association.NotLoaded.t(),
          library_path: Mydia.Settings.LibraryPath.t() | Ecto.Association.NotLoaded.t(),
          target_collection: Mydia.Collections.Collection.t() | Ecto.Association.NotLoaded.t(),
          items: [Mydia.ImportLists.ImportListItem.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "import_lists" do
    field :name, :string
    field :type, :string
    field :media_type, :string
    field :enabled, :boolean, default: true
    field :sync_interval, :integer, default: 360
    field :auto_add, :boolean, default: false
    field :monitored, :boolean, default: true
    field :config, :map, default: %{}
    field :last_synced_at, :utc_datetime
    field :sync_error, :string

    # Virtual field for form handling
    field :list_url, :string, virtual: true

    belongs_to :quality_profile, Mydia.Settings.QualityProfile
    belongs_to :library_path, Mydia.Settings.LibraryPath
    belongs_to :target_collection, Mydia.Collections.Collection
    has_many :items, Mydia.ImportLists.ImportListItem

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating an import list.
  """
  def changeset(import_list, attrs) do
    import_list
    |> cast(attrs, [
      :name,
      :type,
      :media_type,
      :enabled,
      :sync_interval,
      :auto_add,
      :monitored,
      :config,
      :last_synced_at,
      :sync_error,
      :quality_profile_id,
      :library_path_id,
      :target_collection_id,
      :list_url
    ])
    |> validate_required([:name, :type, :media_type])
    |> validate_inclusion(:type, @type_values)
    |> validate_inclusion(:media_type, @media_type_values)
    |> validate_inclusion(:sync_interval, @sync_interval_values)
    |> validate_media_type_compatibility()
    |> validate_list_url()
    |> store_list_url_in_config()
    |> maybe_add_unique_constraint()
    |> foreign_key_constraint(:quality_profile_id)
    |> foreign_key_constraint(:library_path_id)
    |> foreign_key_constraint(:target_collection_id)
  end

  # Rejects a type/media_type pair with no real target, e.g. tmdb_upcoming
  # (movie-only) paired with media_type "tv_show". Runs after
  # validate_inclusion/3 on both fields so it only has to reason about
  # already-valid values; an unrecognized type or media_type is reported by
  # those validations instead.
  defp validate_media_type_compatibility(changeset) do
    type = get_field(changeset, :type)
    media_type = get_field(changeset, :media_type)

    if is_nil(type) or is_nil(media_type) or supports_media_type?(type, media_type) do
      changeset
    else
      add_error(
        changeset,
        :media_type,
        "is not supported by this list type (#{type_label(type)} only supports #{compatible_media_types_label(type)})"
      )
    end
  end

  defp compatible_media_types_label(type) do
    type
    |> compatible_media_types()
    |> Enum.map_join(" or ", &media_type_label/1)
  end

  defp media_type_label("movie"), do: "movies"
  defp media_type_label("tv_show"), do: "TV shows"

  # Validates that list_url is provided when the type requires config
  defp validate_list_url(changeset) do
    type = get_field(changeset, :type)

    if requires_config?(type) do
      changeset
      |> validate_required([:list_url], message: "is required for this list type")
      |> validate_list_url_format()
    else
      changeset
    end
  end

  # Validates the URL/ID format based on list type
  defp validate_list_url_format(changeset) do
    type = get_field(changeset, :type)
    list_url = get_field(changeset, :list_url)

    cond do
      is_nil(list_url) or list_url == "" ->
        changeset

      type == "custom_url" ->
        if String.starts_with?(list_url, "http://") or String.starts_with?(list_url, "https://") do
          changeset
        else
          add_error(changeset, :list_url, "must be a valid URL starting with http:// or https://")
        end

      type == "tmdb_list" ->
        # Accept either a numeric ID or a full TMDB list URL
        if Regex.match?(~r/^\d+$/, list_url) or String.contains?(list_url, "themoviedb.org/list/") do
          changeset
        else
          add_error(changeset, :list_url, "must be a TMDB list ID or URL")
        end

      true ->
        changeset
    end
  end

  # Stores the list_url in the config map for persistence
  defp store_list_url_in_config(changeset) do
    list_url = get_change(changeset, :list_url)

    if list_url do
      config = get_field(changeset, :config) || %{}
      put_change(changeset, :config, Map.put(config, "list_url", list_url))
    else
      changeset
    end
  end

  # Only apply unique constraint to preset list types
  defp maybe_add_unique_constraint(changeset) do
    type = get_field(changeset, :type)

    if requires_config?(type) do
      # Custom lists can have duplicates (different URLs)
      changeset
    else
      # Preset lists should be unique per media type
      unique_constraint(changeset, [:type, :media_type],
        message: "already exists for this media type"
      )
    end
  end

  @doc """
  Returns the list of valid type values.
  """
  def valid_types, do: @type_values

  @doc """
  Returns the list of valid media type values.
  """
  def valid_media_types, do: @media_type_values

  @doc """
  Returns the list of valid sync interval values (in minutes).
  """
  def valid_sync_intervals, do: @sync_interval_values

  @doc """
  Returns a human-readable label for a sync interval.
  """
  def sync_interval_label(60), do: "1 hour"
  def sync_interval_label(360), do: "6 hours"
  def sync_interval_label(720), do: "12 hours"
  def sync_interval_label(1440), do: "24 hours"
  def sync_interval_label(_), do: "Unknown"

  @doc """
  Returns a human-readable label for a list type.
  """
  def type_label("tmdb_trending"), do: "TMDB Trending"
  def type_label("tmdb_popular"), do: "TMDB Popular"
  def type_label("tmdb_upcoming"), do: "TMDB Upcoming"
  def type_label("tmdb_now_playing"), do: "TMDB Now Playing"
  def type_label("tmdb_on_the_air"), do: "TMDB On The Air"
  def type_label("tmdb_airing_today"), do: "TMDB Airing Today"
  def type_label("tmdb_list"), do: "TMDB List"
  def type_label("custom_url"), do: "Custom URL"
  def type_label(_), do: "Unknown"

  @doc """
  Returns the source category for grouping list types.
  """
  def source_category("tmdb_" <> _), do: :tmdb
  def source_category("custom_url"), do: :custom
  def source_category(_), do: :unknown

  @doc """
  Returns the media types a given list type can be configured with.

  Most types accept either `"movie"` or `"tv_show"`. A handful of TMDB
  preset types have no counterpart endpoint for the other media type
  (`tmdb_upcoming`/`tmdb_now_playing` are movie-only, `tmdb_on_the_air`/
  `tmdb_airing_today` are TV-only) and so only accept one. A LiveView form
  can use this to filter the Media Type select's options for the chosen
  type.

  ## Examples

      iex> Mydia.ImportLists.ImportList.compatible_media_types("tmdb_upcoming")
      ["movie"]

      iex> Mydia.ImportLists.ImportList.compatible_media_types("tmdb_trending")
      ["movie", "tv_show"]
  """
  @spec compatible_media_types(String.t()) :: [String.t()]
  def compatible_media_types(type) when type in @movie_only_types, do: ["movie"]
  def compatible_media_types(type) when type in @tv_only_types, do: ["tv_show"]
  def compatible_media_types(_type), do: @media_type_values

  @doc """
  Returns true if `media_type` is a valid pairing for list `type`.

  See `compatible_media_types/1` for the compatibility rule.
  """
  @spec supports_media_type?(String.t(), String.t()) :: boolean()
  def supports_media_type?(type, media_type) do
    media_type in compatible_media_types(type)
  end

  @doc """
  Returns true if this list type requires a URL or ID config.
  """
  def requires_config?("tmdb_list"), do: true
  def requires_config?("custom_url"), do: true
  def requires_config?(_), do: false

  @doc """
  Returns the config field label for list types that require config.
  """
  def config_field_label("tmdb_list"), do: "TMDB List ID"
  def config_field_label("custom_url"), do: "Feed URL"
  def config_field_label(_), do: nil

  @doc """
  Returns placeholder text for the config field.
  """
  def config_field_placeholder("tmdb_list"), do: "e.g., 12345 or full URL"
  def config_field_placeholder("custom_url"), do: "e.g., https://example.com/feed.json"
  def config_field_placeholder(_), do: nil
end
