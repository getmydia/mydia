defmodule Mydia.Settings.PluginConfig do
  @moduledoc """
  Schema for installed WASM plugin configuration (the DB overlay).

  Mirrors `Mydia.Settings.DownloadClientConfig`: a row per installed plugin
  participating in the layered config model (env > DB > YAML > default) with
  source provenance. Env/index-sourced plugins surface as read-only
  `runtime::plugin::<slug>` rows (see `Mydia.Settings.RuntimeConfig`); DB rows
  are editable.

  ## Field notes

  - `settings` — per-plugin config map (e.g. a notifier's `webhook_url`),
    stored as JSON text via `Mydia.Settings.JsonMapType`.
  - `granted_capabilities` — the capabilities an admin approved, persisted
    **server-side** (KTD6). A canonical map of `class => values`, e.g.
    `%{"net:http" => ["discord.com"]}`. A plugin can never widen its own grant.
  - `integrity_hash` — the package checksum stored as `Base.encode16` hex
    (ASCII-safe), never raw bytes (KTD10 — raw bytes fail Postgres UTF-8).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary(),
          slug: String.t() | nil,
          name: String.t() | nil,
          version: String.t() | nil,
          enabled: boolean(),
          priority: integer(),
          settings: map() | nil,
          granted_capabilities: map() | nil,
          source_url: String.t() | nil,
          integrity_hash: String.t() | nil,
          manifest: map() | nil,
          wasm_module: binary() | nil,
          connections: [map()],
          last_scheduled_at: DateTime.t() | nil,
          consecutive_schedule_failures: integer(),
          updated_by: Mydia.Accounts.User.t() | nil | Ecto.Association.NotLoaded.t(),
          updated_by_id: binary() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "plugin_configs" do
    field :slug, :string
    field :name, :string
    field :version, :string
    field :enabled, :boolean, default: false
    field :priority, :integer, default: 1
    field :settings, Mydia.Settings.JsonMapType
    field :granted_capabilities, Mydia.Settings.JsonMapType
    field :source_url, :string
    field :integrity_hash, :string
    # The plugin's manifest (declared events + capabilities), kept so a descriptor
    # can be rebuilt at boot. The verified wasm artifact, persisted as a true
    # binary (BLOB/BYTEA) for offline-boot activation (never a text column).
    field :manifest, Mydia.Settings.JsonMapType
    field :wasm_module, :binary
    field :connections, {:array, :map}, virtual: true, default: []

    # Scheduler bookkeeping (U4): when the last scheduled run completed, and the
    # consecutive-failure counter that drives exponential backoff.
    field :last_scheduled_at, :utc_datetime_usec
    field :consecutive_schedule_failures, :integer, default: 0

    belongs_to :updated_by, Mydia.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating or updating a plugin config."
  def changeset(plugin_config, attrs) do
    plugin_config
    |> cast(attrs, [
      :slug,
      :name,
      :version,
      :enabled,
      :priority,
      :settings,
      :granted_capabilities,
      :source_url,
      :integrity_hash,
      :manifest,
      :wasm_module,
      :updated_by_id
    ])
    |> validate_required([:slug, :name])
    |> validate_number(:priority, greater_than: 0)
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9_-]*$/,
      message: "must be lowercase alphanumeric with - or _"
    )
    |> unique_constraint(:slug)
  end
end
