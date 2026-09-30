defmodule Mydia.Plugins.Instance do
  @moduledoc """
  One configured instance of a plugin (host contract 1.4).

  A single-instance plugin has exactly one, its default instance. A plugin whose
  manifest declares `multi_instance: true` may have many, each with its own
  settings, approved endpoints, account links, store and schedule state.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "plugin_instances" do
    field :plugin_config_id, :binary_id
    field :plugin_slug, :string
    field :name, :string
    field :enabled, :boolean, default: true
    field :settings, Mydia.Settings.JsonMapType, default: %{}
    field :approved_endpoints, Mydia.Settings.JsonListType, default: []
    field :remote_accounts, Mydia.Settings.JsonListType, default: []
    field :last_scheduled_at, :utc_datetime_usec
    field :schedule_failures, :integer, default: 0
    # The declared name of a YAML/env instance (Task 11); nil for DB-created ones.
    field :runtime_key, :string
    # Derived from runtime_key by Instances.put_source/1 (Task 11).
    field :source, Ecto.Enum, values: [:db, :runtime], default: :db, virtual: true

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [
      :name,
      :enabled,
      :settings,
      :approved_endpoints,
      :remote_accounts,
      :last_scheduled_at,
      :schedule_failures,
      :runtime_key
    ])
    |> validate_required([:plugin_slug, :name])
    |> validate_length(:name, max: 200)
    |> unique_constraint([:plugin_slug, :runtime_key])
    |> foreign_key_constraint(:plugin_config_id)
  end

  @doc "Renders an approved endpoint map as `scheme://host:port`."
  @spec endpoint_label(map()) :: String.t()
  def endpoint_label(%{"scheme" => scheme, "host" => host, "port" => port}),
    do: "#{scheme}://#{host}:#{port}"

  def endpoint_label(other), do: inspect(other)
end
