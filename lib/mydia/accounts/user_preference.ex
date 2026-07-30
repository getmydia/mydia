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
    "close_manual_search_after_grab" => false
  }

  # Valid values for each preference
  @valid_themes ~w(system light dark)
  @valid_languages ~w(en es fr de it pt ja zh ko ru)

  @type t :: %__MODULE__{
          id: binary(),
          preferences: map(),
          user: Mydia.Accounts.User.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "user_preferences" do
    field :preferences, :map, default: %{}

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
  end

  # Validate individual preference values
  defp validate_preferences(changeset) do
    changeset
    |> validate_preference_value("theme", @valid_themes)
    |> validate_preference_value("metadata_language", @valid_languages)
    |> validate_preference_value("interface_language", @valid_languages)
    |> validate_preference_value("close_manual_search_after_grab", [true, false])
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
