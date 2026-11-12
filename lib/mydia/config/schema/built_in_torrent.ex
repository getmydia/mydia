defmodule Mydia.Config.Schema.BuiltInTorrent do
  @moduledoc """
  The `built_in_torrent` section of `Mydia.Config.Schema`: the bundled rqbit
  client and the optional gluetun VPN in front of it.

  The section is flat, with `vpn_` prefixes, because database overlay keys are
  indexed one level deep (`section.field`).

  `enabled` is tri-state: `nil` keeps the automatic rule (on when `rqbit` is on
  the `PATH` and no torrent-capable client is configured).

  `vpn_provider` and `vpn_type` are plain trimmed, downcased strings. They are
  validated against the provider table by the settings form, not here, so an
  env value naming a newer provider cannot fail the whole config load.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :enabled, :boolean
    field :download_path, :string, default: "/data/downloads"
    field :state_path, :string, default: "/config/rqbit"
    field :listen_port, :integer, default: 51413
    field :api_port, :integer, default: 3030
    field :vpn_enabled, :boolean, default: false
    field :vpn_provider, :string
    field :vpn_type, :string
    field :vpn_openvpn_user, :string
    field :vpn_openvpn_password, :string, redact: true
    field :vpn_wireguard_private_key, :string, redact: true
    field :vpn_wireguard_addresses, :string
    field :vpn_server_countries, :string
    field :vpn_server_regions, :string
    field :vpn_server_cities, :string
    field :vpn_server_hostnames, :string
    field :vpn_port_forwarding, :boolean, default: false
  end

  @type t :: %__MODULE__{}

  @env_vars [
    enabled: "MYDIA_TORRENT_ENABLED",
    download_path: "MYDIA_TORRENT_DOWNLOAD_PATH",
    state_path: "MYDIA_TORRENT_STATE_PATH",
    listen_port: "MYDIA_TORRENT_PORT",
    api_port: "MYDIA_TORRENT_API_PORT",
    vpn_enabled: "MYDIA_VPN_SERVICE_PROVIDER",
    vpn_provider: "MYDIA_VPN_SERVICE_PROVIDER",
    vpn_type: "MYDIA_VPN_VPN_TYPE",
    vpn_openvpn_user: "MYDIA_VPN_OPENVPN_USER",
    vpn_openvpn_password: "MYDIA_VPN_OPENVPN_PASSWORD",
    vpn_wireguard_private_key: "MYDIA_VPN_WIREGUARD_PRIVATE_KEY",
    vpn_wireguard_addresses: "MYDIA_VPN_WIREGUARD_ADDRESSES",
    vpn_server_countries: "MYDIA_VPN_SERVER_COUNTRIES",
    vpn_server_regions: "MYDIA_VPN_SERVER_REGIONS",
    vpn_server_cities: "MYDIA_VPN_SERVER_CITIES",
    vpn_server_hostnames: "MYDIA_VPN_SERVER_HOSTNAMES",
    vpn_port_forwarding: "MYDIA_VPN_VPN_PORT_FORWARDING"
  ]

  @secret_fields [:vpn_openvpn_password, :vpn_wireguard_private_key]

  @doc "The single field-to-environment-variable table."
  @spec env_vars() :: [{atom(), String.t()}]
  def env_vars, do: @env_vars

  @doc "Fields holding credentials: never rendered, logged or exported."
  @spec secret_fields() :: [atom()]
  def secret_fields, do: @secret_fields

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, Keyword.keys(@env_vars))
    |> normalize_identifier(:vpn_provider)
    |> normalize_identifier(:vpn_type)
    |> validate_number(:listen_port, greater_than_or_equal_to: 1, less_than_or_equal_to: 65_535)
    |> validate_number(:api_port, greater_than_or_equal_to: 1, less_than_or_equal_to: 65_535)
  end

  defp normalize_identifier(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> value |> String.trim() |> String.downcase()
      value -> value
    end)
  end
end
