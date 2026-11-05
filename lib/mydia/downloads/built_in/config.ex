defmodule Mydia.Downloads.BuiltIn.Config do
  @moduledoc """
  Reads the built-in torrent client's environment variables.

  Pure: callers pass the environment and the types of the other configured
  download clients, so tests never touch global env.
  """

  @torrent_types [:qbittorrent, :transmission, :rqbit, :rtorrent]
  @reserved ~w(SPLIT_TUNNEL_GID HTTP_CONTROL_SERVER_ADDRESS HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE DNS_ADDRESS)
  @default_port 51413

  @type t :: %__MODULE__{
          enabled?: boolean(),
          download_path: String.t(),
          port: pos_integer(),
          vpn?: boolean(),
          vpn_provider: String.t() | nil,
          vpn_interface: String.t(),
          state_dir: String.t(),
          gluetun_dir: String.t(),
          warnings: [term()]
        }

  defstruct enabled?: false,
            download_path: "/data/downloads",
            port: @default_port,
            vpn?: false,
            vpn_provider: nil,
            vpn_interface: "tun0",
            state_dir: "/config/rqbit",
            gluetun_dir: "/config/gluetun",
            warnings: []

  @spec load(%{String.t() => String.t()}, [atom()]) :: t()
  def load(env, other_client_types) do
    {port, port_warnings} = parse_port(env["MYDIA_TORRENT_PORT"])
    provider = blank_to_nil(env["MYDIA_VPN_SERVICE_PROVIDER"])

    %__MODULE__{
      enabled?: enabled?(env["MYDIA_TORRENT_ENABLED"], other_client_types),
      download_path: env["MYDIA_TORRENT_DOWNLOAD_PATH"] || "/data/downloads",
      port: port,
      vpn?: provider != nil,
      vpn_provider: provider,
      vpn_interface: env["MYDIA_VPN_VPN_INTERFACE"] || "tun0",
      warnings: port_warnings ++ reserved_warnings(env)
    }
  end

  defp enabled?("true", _types), do: true
  defp enabled?("false", _types), do: false
  defp enabled?(_unset, types), do: not Enum.any?(types, &(&1 in @torrent_types))

  defp parse_port(nil), do: {@default_port, []}

  defp parse_port(value) do
    case Integer.parse(value) do
      {port, ""} when port in 1..65_535 -> {port, []}
      _ -> {@default_port, [{:invalid_port, value}]}
    end
  end

  defp reserved_warnings(env) do
    for name <- @reserved, Map.has_key?(env, "MYDIA_VPN_" <> name), do: {:reserved_variable, name}
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: if(String.trim(value) == "", do: nil, else: value)
end
