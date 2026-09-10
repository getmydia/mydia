defmodule Mydia.Settings.IndexerConfig do
  @moduledoc """
  Schema for indexer/search provider configurations (Prowlarr, Jackett, public indexers).
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
          base_url: String.t() | nil,
          api_key: String.t() | nil,
          indexer_ids: [String.t()] | nil,
          categories: [String.t()] | nil,
          rate_limit: integer() | nil,
          connection_settings: map() | nil,
          env_name: String.t() | nil,
          min_post_age_minutes: integer() | nil,
          updated_by: Mydia.Accounts.User.t() | nil | Ecto.Association.NotLoaded.t(),
          updated_by_id: binary() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @indexer_types [:prowlarr, :jackett, :nzbhydra2, :public]

  schema "indexer_configs" do
    field :name, :string
    field :type, Ecto.Enum, values: @indexer_types
    field :enabled, :boolean, default: true
    field :priority, :integer, default: 1
    field :base_url, :string
    field :api_key, :string
    field :indexer_ids, {:array, :string}
    field :categories, {:array, :string}
    field :rate_limit, :integer
    field :connection_settings, Mydia.Settings.JsonMapType
    field :env_name, :string
    field :min_post_age_minutes, :integer

    belongs_to :updated_by, Mydia.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating an indexer config.
  """
  def changeset(indexer_config, attrs) do
    indexer_config
    |> cast(attrs, [
      :name,
      :type,
      :enabled,
      :priority,
      :base_url,
      :api_key,
      :indexer_ids,
      :categories,
      :rate_limit,
      :connection_settings,
      :updated_by_id,
      :env_name,
      :min_post_age_minutes
    ])
    |> validate_required([:name, :type])
    |> validate_base_url_or_env_name()
    |> validate_inclusion(:type, @indexer_types)
    |> validate_number(:priority, greater_than: 0)
    |> validate_number(:rate_limit, greater_than: 0)
    |> validate_number(:min_post_age_minutes, greater_than_or_equal_to: 0)
    |> normalize_base_url()
    |> validate_base_url()
    |> unique_constraint(:name)
  end

  # Validates that either base_url or env_name is provided
  defp validate_base_url_or_env_name(changeset) do
    base_url = get_field(changeset, :base_url)
    env_name = get_field(changeset, :env_name)

    cond do
      # env_name is set - base_url is optional
      is_binary(env_name) and env_name != "" ->
        changeset

      # base_url is set - valid
      is_binary(base_url) and base_url != "" ->
        changeset

      # Neither is set - error
      true ->
        add_error(changeset, :base_url, "is required unless env_name is set")
    end
  end

  # Stores the same normalized URL that reads use, see normalize_url/1
  defp normalize_base_url(changeset) do
    case get_change(changeset, :base_url) do
      nil ->
        changeset

      url ->
        normalized = normalize_url(url)

        if normalized != url do
          put_change(changeset, :base_url, normalized)
        else
          changeset
        end
    end
  end

  @doc """
  Normalizes an indexer base URL from any source: the admin form, env vars,
  YAML config, or a row saved before normalization existed.

  Trims whitespace, prepends `http://` when the scheme is missing, and strips
  trailing slashes. Adapters append paths such as `/api/v1/system/status`, so a
  trailing slash would otherwise produce `//api/...` (#765).
  """
  @spec normalize_url(String.t()) :: String.t()
  def normalize_url(url) when is_binary(url) do
    url
    |> String.trim()
    |> ensure_scheme()
    |> String.trim_trailing("/")
  end

  defp ensure_scheme(url) do
    case URI.parse(url) do
      # URL with valid http/https scheme - keep as-is
      %URI{scheme: scheme} when scheme in ["http", "https"] ->
        url

      # URL with another scheme (ftp://, etc.) - keep as-is, let validation reject it
      %URI{scheme: scheme, host: host} when is_binary(scheme) and is_binary(host) ->
        url

      # If scheme is missing, prepend http://
      # URI.parse("192.168.1.1:9696") -> %URI{scheme: nil, path: "192.168.1.1:9696"}
      # URI.parse("localhost:9696") -> %URI{scheme: "localhost", host: nil, path: "9696"}
      # In both cases, we need to prepend http://
      _ ->
        "http://#{url}"
    end
  end

  defp validate_base_url(changeset) do
    validate_change(changeset, :base_url, fn :base_url, url ->
      case URI.parse(url) do
        %URI{host: nil} ->
          [base_url: "must include a valid host"]

        %URI{host: ""} ->
          [base_url: "must include a valid host"]

        %URI{port: port} when is_integer(port) and (port < 1 or port > 65535) ->
          [base_url: "port must be between 1 and 65535"]

        %URI{scheme: scheme} when scheme not in ["http", "https"] ->
          [base_url: "must use http or https scheme"]

        _ ->
          []
      end
    end)
  end
end
