defmodule Mydia.Accounts.UserPreference do
  @moduledoc """
  Schema for user preferences.

  Uses a flexible map column to store all preferences, with typed getter functions
  that provide defaults. This approach allows adding new preference types without
  requiring database migrations.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Default preference values
  @defaults %{
    "metadata_language" => "en",
    "interface_language" => "en",
    "theme" => "system",
    "close_manual_search_after_grab" => false,
    "grid_density" => "comfortable",
    "recommendations_expanded" => false,
    "discover_hide_owned" => false,
    "hide_player" => false,
    "player_banner_dismissed" => false
  }

  # Valid values for each preference
  @valid_themes ~w(system light dark)
  @valid_languages ~w(en es fr de it pt ja zh ko ru)
  @valid_densities ~w(comfortable compact dense)

  @type t :: %__MODULE__{
          id: binary(),
          preferences: map(),
          lock_version: integer(),
          user: Mydia.Accounts.User.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "user_preferences" do
    field :preferences, :map, default: %{}
    field :lock_version, :integer, default: 1

    belongs_to :user, Mydia.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Returns the default preference values.
  """
  def defaults, do: @defaults

  @doc """
  Gets the metadata language preference with default fallback.
  """
  def metadata_language(%__MODULE__{preferences: prefs}) do
    Map.get(prefs, "metadata_language", @defaults["metadata_language"])
  end

  @doc """
  Gets the interface language preference with default fallback.
  """
  def interface_language(%__MODULE__{preferences: prefs}) do
    Map.get(prefs, "interface_language", @defaults["interface_language"])
  end

  @doc """
  Gets the theme preference with default fallback.
  """
  def theme(%__MODULE__{preferences: prefs}) do
    Map.get(prefs, "theme", @defaults["theme"])
  end

  @doc """
  Whether the manual search modal should close immediately after a grab.
  """
  def close_manual_search_after_grab?(%__MODULE__{preferences: prefs}) do
    Map.get(prefs, "close_manual_search_after_grab", @defaults["close_manual_search_after_grab"])
  end

  @doc """
  Grid density for the Discover and Libraries poster grids.
  """
  def grid_density(%__MODULE__{preferences: prefs}) do
    Map.get(prefs, "grid_density", @defaults["grid_density"])
  end

  @doc """
  Whether the More Like This rail on a show's detail page starts open.

  Only shows collapse the rail. `MydiaWeb.DiscoverComponents.media_rail/1`
  computes `open? = not collapsible or expanded`, and the rail is collapsible
  only for a tv_show, so a movie ignores this value.
  """
  def recommendations_expanded(%__MODULE__{preferences: prefs}) do
    Map.get(prefs, "recommendations_expanded", @defaults["recommendations_expanded"])
  end

  @doc """
  Whether the Discover grid hides titles already in the library.

  Defaults to false. Hiding by default would make a search for an owned title
  render an empty result, which reads as "not available" rather than "you
  already have this".
  """
  def discover_hide_owned(%__MODULE__{preferences: prefs}) do
    Map.get(prefs, "discover_hide_owned", @defaults["discover_hide_owned"])
  end

  @doc """
  Per-user override for the target library on add, or nil to inherit the
  instance default.

  These add-option getters return nil rather than a concrete default on
  purpose: nil is the signal `Mydia.Media.AddDefaults` uses to fall through to
  the instance setting. Do not add them to `@defaults`.
  """
  def add_library_path_id(%__MODULE__{preferences: prefs}, :movie),
    do: Map.get(prefs, "add_movie_library_path_id")

  def add_library_path_id(%__MODULE__{preferences: prefs}, :tv_show),
    do: Map.get(prefs, "add_series_library_path_id")

  @doc "Per-user quality profile override on add, or nil to inherit."
  def add_quality_profile_id(%__MODULE__{preferences: prefs}),
    do: Map.get(prefs, "add_quality_profile_id")

  @doc "Per-user monitored override on add, or nil to inherit."
  def add_monitored(%__MODULE__{preferences: prefs}),
    do: Map.get(prefs, "add_monitored")

  @doc "Per-user season monitoring override on add, or nil to inherit."
  def add_season_monitoring(%__MODULE__{preferences: prefs}),
    do: Map.get(prefs, "add_season_monitoring")

  @doc "Per-user search-on-add override, or nil to inherit."
  def add_search_on_add(%__MODULE__{preferences: prefs}),
    do: Map.get(prefs, "add_search_on_add")

  @doc """
  Whether the player's navigation entry points should be hidden.

  Covers the sidebar pill, the mobile dock tab, the dashboard banner and the
  Devices "Web" tile. Play buttons on individual movies and episodes are not
  affected, and `/player` stays reachable: this is a preference, not access
  control.

  The `== true` comparison is deliberate. `preferences` is a free-form map and
  `validate_preferences/1` only runs on writes, so a hand-edited row could hold
  the string "true". Returning that string would reach `not @hide_player` in a
  template, where `not "true"` raises ArgumentError and breaks every render.
  """
  def hide_player?(%__MODULE__{preferences: prefs}) do
    Map.get(prefs, "hide_player", @defaults["hide_player"]) == true
  end

  @doc """
  Whether the user closed the dashboard player banner.

  Independent of `hide_player?/1`: closing the banner never touches the
  navigation, and turning the hide setting off never brings a dismissed banner
  back.
  """
  def player_banner_dismissed?(%__MODULE__{preferences: prefs}) do
    Map.get(prefs, "player_banner_dismissed", @defaults["player_banner_dismissed"]) == true
  end

  @doc """
  Changeset for creating or updating user preferences.

  The `preferences` param should be a map with string keys, e.g.:
  %{"metadata_language" => "en", "theme" => "dark"}
  """
  def changeset(user_preference, attrs) do
    user_preference
    |> cast(attrs, [:preferences])
    |> validate_preferences()
  end

  @doc """
  Updates specific preference keys while preserving others.

  ## Example

      update_preferences(user_pref, %{"theme" => "dark"})
  """
  def update_preferences_changeset(%__MODULE__{} = user_preference, new_prefs)
      when is_map(new_prefs) do
    merged_prefs = Map.merge(user_preference.preferences || %{}, stringify_keys(new_prefs))

    user_preference
    |> cast(%{preferences: merged_prefs}, [:preferences])
    |> validate_preferences()
    |> optimistic_lock(:lock_version)
  end

  # Validate individual preference values
  defp validate_preferences(changeset) do
    changeset
    |> validate_preference_value("theme", @valid_themes)
    |> validate_preference_value("metadata_language", @valid_languages)
    |> validate_preference_value("interface_language", @valid_languages)
    |> validate_preference_value("close_manual_search_after_grab", [true, false])
    |> validate_preference_value("grid_density", @valid_densities)
    |> validate_preference_value("recommendations_expanded", [true, false])
    |> validate_preference_value("discover_hide_owned", [true, false])
    |> validate_preference_value("add_monitored", [true, false])
    |> validate_preference_value("add_search_on_add", [true, false])
    |> validate_preference_value(
      "add_season_monitoring",
      Mydia.Config.Schema.season_monitoring_values()
    )
    |> validate_preference_value("hide_player", [true, false])
    |> validate_preference_value("player_banner_dismissed", [true, false])
  end

  defp validate_preference_value(changeset, key, valid_values) do
    case get_change(changeset, :preferences) do
      nil ->
        changeset

      prefs when is_map(prefs) ->
        value = Map.get(prefs, key)

        cond do
          is_nil(value) ->
            changeset

          Enum.member?(valid_values, value) ->
            changeset

          true ->
            add_error(
              changeset,
              :preferences,
              "invalid value for #{key}: #{inspect(value)}"
            )
        end

      _ ->
        changeset
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
