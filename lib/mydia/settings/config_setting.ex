defmodule Mydia.Settings.ConfigSetting do
  @moduledoc """
  Schema for general application configuration settings stored in the database.

  ## Configuration Precedence

  ConfigSetting records are part of the 4-layer configuration system:
  1. Environment variables (highest priority)
  2. **Database/UI settings (this schema)** - Overrides YAML config
  3. YAML configuration file
  4. Schema defaults (lowest priority)

  This allows administrators to configure the application through the UI while
  still allowing environment variables to override for deployment-specific needs.

  ## Key Format

  Configuration keys use dot notation to represent nested configuration paths:
  - `"server.port"` → `config.server.port`
  - `"auth.local_enabled"` → `config.auth.local_enabled`
  - `"media.movies_path"` → `config.media.movies_path`

  ## Value Parsing

  Values are stored as strings and automatically parsed based on type:
  - Integers: `"8080"` → `8080`
  - Booleans: `"true"` → `true`, `"false"` → `false`
  - Strings: `"example.com"` → `"example.com"`

  ## Examples

      # Create a config setting to override the server port
      %ConfigSetting{
        key: "server.port",
        value: "8080",
        category: :server,
        description: "Web server port"
      }

      # Create a config setting to enable OIDC authentication
      %ConfigSetting{
        key: "auth.oidc_enabled",
        value: "true",
        category: :auth,
        description: "Enable OIDC authentication"
      }
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @categories [:server, :auth, :media, :downloads, :notifications, :general]

  schema "config_settings" do
    field :key, :string
    field :value, :string
    field :category, Ecto.Enum, values: @categories
    field :description, :string

    belongs_to :updated_by, Mydia.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a config setting.
  """
  def changeset(config_setting, attrs) do
    config_setting
    |> cast(attrs, [:key, :value, :category, :description, :updated_by_id])
    |> validate_required([:key, :category])
    |> validate_inclusion(:category, @categories)
    |> unique_constraint(:key)
  end
end
