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

  @sync_interval_values [60, 360, 720, 1440]

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
      :list_url
    ])
    |> validate_required([:name, :type, :media_type])
    |> validate_inclusion(:type, @type_values)
    |> validate_inclusion(:media_type, @media_type_values)
    |> validate_inclusion(:sync_interval, @sync_interval_values)
    |> validate_list_url()
    |> store_list_url_in_config()
    |> maybe_add_unique_constraint()
    |> foreign_key_constraint(:quality_profile_id)
    |> foreign_key_constraint(:library_path_id)
  end

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
        name: :import_lists_type_media_type_unique,
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
