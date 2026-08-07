defmodule Mydia.Settings.DownloadClientConfig do
  @moduledoc """
  Schema for download client configurations (qBittorrent, Transmission, rTorrent,
  Blackhole, HTTP, SABnzbd, NZBGet).

  ## Field notes

  - `category` (string) — COMPAT: superseded by `categories` (map).
    Accepts: single-category download client configs written before
    per-category routing existed.
    Source: existing rows in `download_client_configs` and the
    `DOWNLOAD_CLIENT_<N>_CATEGORY` environment variable (the only
    category-related env var; `categories` has no env-var equivalent).
    Removing it would: silently drop the configured category for clients
    still using it, sending completed downloads to the wrong path.
    `categories` takes precedence when populated; new code should prefer
    `categories` keyed by `Download.content_type`.
  - `categories` — map keyed by content type (`"movie"`, `"tv"`, `"music"`) to a
    client-native category string. Falls back to `category` when the key is
    missing or the map is empty.
  - `priority_profile` — map from a 5-tier priority atom string (`"verylow"`,
    `"low"`, `"normal"`, `"high"`, `"veryhigh"`) to the client-native priority
    value (integer or string, varies per adapter). Empty map means adapters
    fall back to their hardcoded default mapping.
  - `incomplete_grace_minutes` — stall detection grace window; defaults to 60.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary(),
          name: String.t() | nil,
          type: atom() | nil,
          enabled: boolean(),
          priority: integer(),
          host: String.t() | nil,
          port: integer() | nil,
          use_ssl: boolean(),
          url_base: String.t() | nil,
          username: String.t() | nil,
          password: String.t() | nil,
          api_key: String.t() | nil,
          category: String.t() | nil,
          categories: map(),
          priority_profile: map(),
          incomplete_grace_minutes: integer(),
          download_directory: String.t() | nil,
          connection_settings: map() | nil,
          remove_completed: boolean(),
          updated_by: Mydia.Accounts.User.t() | nil | Ecto.Association.NotLoaded.t(),
          updated_by_id: binary() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @client_types [
    :qbittorrent,
    :transmission,
    :rqbit,
    :rtorrent,
    :blackhole,
    :sabnzbd,
    :nzbget,
    :debrid
  ]

  @debrid_providers ~w(real_debrid all_debrid premiumize tor_box)
  @debrid_default_grace_minutes 1440

  @remote_fetch_types [:qbittorrent, :transmission, :rqbit, :rtorrent]
  @remote_fetch_auth_methods ~w(password ssh_key)

  schema "download_client_configs" do
    field :name, :string
    field :type, Ecto.Enum, values: @client_types
    field :enabled, :boolean, default: true
    field :priority, :integer, default: 1
    field :host, :string
    field :port, :integer
    field :use_ssl, :boolean, default: false
    field :url_base, :string
    field :username, :string
    field :password, :string
    field :api_key, :string
    field :category, :string
    field :categories, :map, default: %{}
    field :priority_profile, :map, default: %{}
    field :incomplete_grace_minutes, :integer, default: 60
    field :download_directory, :string
    field :connection_settings, Mydia.Settings.JsonMapType
    field :remove_completed, :boolean, default: false

    belongs_to :updated_by, Mydia.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a download client config.
  """
  def changeset(download_client_config, attrs) do
    download_client_config
    |> cast(attrs, [
      :name,
      :type,
      :enabled,
      :priority,
      :host,
      :port,
      :use_ssl,
      :url_base,
      :username,
      :password,
      :api_key,
      :category,
      :categories,
      :priority_profile,
      :incomplete_grace_minutes,
      :download_directory,
      :connection_settings,
      :remove_completed,
      :updated_by_id
    ])
    |> validate_required([:name, :type])
    |> validate_inclusion(:type, @client_types)
    |> apply_debrid_grace_default(attrs)
    |> validate_by_type()
    |> validate_remote_fetch_config()
    |> validate_number(:priority, greater_than: 0)
    |> validate_number(:incomplete_grace_minutes, greater_than: 0)
    |> validate_priority_profile()
    |> unique_constraint(:name)
  end

  # Debrid clients submit a release to the provider and then wait — sometimes
  # for hours — while the provider downloads it from its own swarm. The stall
  # detector's default 60-minute grace would flag those waits as stalled. When
  # the operator hasn't explicitly set a value, default `:debrid` clients to
  # 1440 minutes (24h). Explicit operator overrides are preserved.
  defp apply_debrid_grace_default(changeset, attrs) do
    case get_field(changeset, :type) do
      :debrid ->
        if Map.has_key?(attrs, :incomplete_grace_minutes) or
             Map.has_key?(attrs, "incomplete_grace_minutes") do
          changeset
        else
          put_change(changeset, :incomplete_grace_minutes, @debrid_default_grace_minutes)
        end

      _ ->
        changeset
    end
  end

  @valid_priority_keys ~w(verylow low normal high veryhigh)

  # Validates that any keys in `priority_profile` are one of the 5-tier
  # taxonomy atom names. Values are not range-checked here because their
  # native domain varies per adapter (SABnzbd: -100..2, NZBGet: any integer,
  # Transmission: -1..1, rTorrent: 0..3); range validation belongs in the
  # adapter, not the changeset. Empty map and nil are both accepted.
  defp validate_priority_profile(changeset) do
    case get_field(changeset, :priority_profile) do
      nil ->
        changeset

      profile when is_map(profile) ->
        invalid =
          profile
          |> Map.keys()
          |> Enum.reject(&(to_string(&1) in @valid_priority_keys))

        if invalid == [] do
          changeset
        else
          add_error(
            changeset,
            :priority_profile,
            "contains unknown priority key(s): #{Enum.join(invalid, ", ")} " <>
              "(must be one of: #{Enum.join(@valid_priority_keys, ", ")})"
          )
        end

      _other ->
        add_error(changeset, :priority_profile, "must be a map")
    end
  end

  # Blackhole and debrid clients use config patterns that don't include
  # `:host`/`:port`. Other clients still require them.
  defp validate_by_type(changeset) do
    case get_field(changeset, :type) do
      :blackhole ->
        changeset
        |> validate_blackhole_config()

      :debrid ->
        changeset
        |> validate_debrid_config()

      _network_client ->
        changeset
        |> validate_required([:host, :port])
        |> validate_number(:port, greater_than: 0, less_than: 65536)
    end
  end

  defp validate_blackhole_config(changeset) do
    case get_field(changeset, :connection_settings) do
      %{"watch_folder" => watch, "completed_folder" => completed}
      when is_binary(watch) and is_binary(completed) and watch != "" and completed != "" ->
        changeset

      _ ->
        changeset
        |> add_error(:connection_settings, "must include watch_folder and completed_folder")
    end
  end

  # Debrid clients require an API key and a `provider` selector under
  # `connection_settings`. `:host`/`:port` are intentionally ignored — the
  # provider's base URL is hardcoded per-provider module.
  defp validate_debrid_config(changeset) do
    changeset
    |> validate_required([:api_key])
    |> validate_debrid_provider()
  end

  defp validate_debrid_provider(changeset) do
    case get_field(changeset, :connection_settings) do
      %{"provider" => provider} when is_binary(provider) ->
        if provider in @debrid_providers do
          changeset
        else
          add_error(
            changeset,
            :connection_settings,
            "provider must be one of: #{Enum.join(@debrid_providers, ", ")} (got #{inspect(provider)})"
          )
        end

      _ ->
        add_error(
          changeset,
          :connection_settings,
          "must include provider (one of: #{Enum.join(@debrid_providers, ", ")})"
        )
    end
  end

  # `enabled` is matched against both the real boolean and its string form:
  # HTML checkboxes submit form params as strings ("true"/"false"), while
  # callers that build the map programmatically (tests, seed scripts) tend to
  # use real booleans. A missing key is treated as disabled rather than an
  # error, because the admin UI always renders the other remote_fetch inputs
  # (host, username, ...) for qBittorrent/Transmission/rqbit/rTorrent clients
  # regardless of whether the operator ever opens that section — an untouched
  # section round-trips its (irrelevant) empty field values with no
  # "enabled" key at all, since an unchecked checkbox is omitted from form
  # params entirely.
  defp validate_remote_fetch_config(changeset) do
    case get_field(changeset, :connection_settings) do
      %{"remote_fetch" => remote_fetch} when is_map(remote_fetch) ->
        case Map.get(remote_fetch, "enabled", false) do
          enabled when enabled in [true, "true"] ->
            validate_remote_fetch_enabled(changeset, remote_fetch)

          enabled when enabled in [false, "false", nil] ->
            changeset

          _other ->
            add_error(changeset, :connection_settings, "remote_fetch.enabled must be a boolean")
        end

      %{"remote_fetch" => _other} ->
        add_error(changeset, :connection_settings, "remote_fetch.enabled must be a boolean")

      _ ->
        changeset
    end
  end

  defp validate_remote_fetch_enabled(changeset, remote_fetch) do
    type = get_field(changeset, :type)

    if type in @remote_fetch_types do
      changeset
      |> validate_remote_fetch_required(remote_fetch, "host")
      |> validate_remote_fetch_required(remote_fetch, "username")
      |> validate_remote_fetch_auth(remote_fetch)
    else
      add_error(
        changeset,
        :connection_settings,
        "remote_fetch is only supported for #{Enum.join(@remote_fetch_types, ", ")} clients"
      )
    end
  end

  defp validate_remote_fetch_required(changeset, remote_fetch, key) do
    case Map.get(remote_fetch, key) do
      value when is_binary(value) and value != "" ->
        changeset

      _ ->
        add_error(changeset, :connection_settings, "remote_fetch.#{key} can't be blank")
    end
  end

  defp validate_remote_fetch_auth(changeset, remote_fetch) do
    case Map.get(remote_fetch, "auth_method") do
      "password" ->
        validate_remote_fetch_required(changeset, remote_fetch, "password")

      "ssh_key" ->
        validate_remote_fetch_required(changeset, remote_fetch, "private_key")

      other ->
        add_error(
          changeset,
          :connection_settings,
          "remote_fetch.auth_method must be one of: " <>
            "#{Enum.join(@remote_fetch_auth_methods, ", ")} (got #{inspect(other)})"
        )
    end
  end

  @doc """
  Returns the supported debrid provider names (as strings).
  """
  @spec debrid_providers() :: [String.t()]
  def debrid_providers, do: @debrid_providers

  @doc """
  Returns the supported remote_fetch auth method names (as strings).
  """
  @spec remote_fetch_auth_methods() :: [String.t()]
  def remote_fetch_auth_methods, do: @remote_fetch_auth_methods
end
