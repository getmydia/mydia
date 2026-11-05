defmodule Mydia.Downloads.BuiltIn.Config do
  @moduledoc """
  Reads the built-in torrent client's environment variables.

  Pure: callers pass the environment and the types of the other configured
  download clients, so tests never touch global env.
  """

  # Clients that already handle torrents. Any of them configured keeps the
  # built-in client off unless MYDIA_TORRENT_ENABLED says otherwise: debrid
  # and blackhole take torrents too, so a second engine would compete.
  @torrent_handler_types [:qbittorrent, :transmission, :rqbit, :rtorrent, :debrid, :blackhole]
  def torrent_handler_types, do: @torrent_handler_types

  @reserved ~w(SPLIT_TUNNEL_GID HTTP_CONTROL_SERVER_ADDRESS HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE DNS_ADDRESS DNS_SERVER)
  @default_port 51413
  @default_api_port 3030
  @default_download_path "/data/downloads"
  @default_state_dir "/config/rqbit"

  @truthy ~w(true 1 yes on)
  @falsy ~w(false 0 no off)

  # Inherited variables a child process must never see: the VPN credentials
  # and Mydia's own secrets. Matched by name so new secrets are covered too.
  @secret_names ~w(SECRET_KEY_BASE DATABASE_URL GUARDIAN_SECRET_KEY)
  @secret_fragments ~w(SECRET PASSWORD TOKEN)

  @type t :: %__MODULE__{
          enabled?: boolean(),
          download_path: String.t(),
          port: pos_integer(),
          api_port: pos_integer(),
          vpn?: boolean(),
          vpn_provider: String.t() | nil,
          vpn_interface: String.t(),
          state_dir: String.t(),
          gluetun_dir: String.t(),
          warnings: [term()]
        }

  defstruct enabled?: false,
            download_path: @default_download_path,
            port: @default_port,
            api_port: @default_api_port,
            vpn?: false,
            vpn_provider: nil,
            vpn_interface: "tun0",
            state_dir: @default_state_dir,
            gluetun_dir: "/config/gluetun",
            warnings: []

  @doc """
  `other_client_types` is `:unknown` when the configured clients could not be
  read. It never turns the client on by itself, only an explicit
  MYDIA_TORRENT_ENABLED does.

  Options: `:find_executable` (default `System.find_executable/1`). Left
  unset, MYDIA_TORRENT_ENABLED only turns the client on when `rqbit` is on the
  PATH, so installs without it (bare releases, the NixOS module) stay off.
  """
  @spec load(%{String.t() => String.t()}, [atom()] | :unknown, keyword()) :: t()
  def load(env, other_client_types, opts \\ []) do
    finder = Keyword.get(opts, :find_executable, &System.find_executable/1)
    {port, port_warnings} = parse_port(env["MYDIA_TORRENT_PORT"], @default_port, :invalid_port)

    {api_port, api_port_warnings} =
      parse_port(env["MYDIA_TORRENT_API_PORT"], @default_api_port, :invalid_api_port)

    {enabled, enabled_warnings} = parse_enabled(env["MYDIA_TORRENT_ENABLED"])
    provider = blank_to_nil(env["MYDIA_VPN_SERVICE_PROVIDER"])

    %__MODULE__{
      enabled?: enabled?(enabled, other_client_types, finder),
      download_path: blank_to_nil(env["MYDIA_TORRENT_DOWNLOAD_PATH"]) || @default_download_path,
      state_dir: blank_to_nil(env["MYDIA_TORRENT_STATE_PATH"]) || @default_state_dir,
      port: port,
      api_port: api_port,
      vpn?: provider != nil,
      vpn_provider: provider,
      vpn_interface: vpn_interface(env),
      warnings: enabled_warnings ++ port_warnings ++ api_port_warnings ++ reserved_warnings(env)
    }
  end

  @doc """
  The `{name, false}` entries that unset every secret in `env` for a child
  process opened with `Port.open/2`'s `:env` option.
  """
  @spec child_env_unset(%{String.t() => String.t()}) :: [{String.t(), false}]
  def child_env_unset(env) do
    for {name, _value} <- env, secret_name?(name), do: {name, false}
  end

  defp secret_name?(name) do
    String.starts_with?(name, "MYDIA_VPN_") or name in @secret_names or
      String.ends_with?(name, "_KEY") or String.contains?(name, @secret_fragments)
  end

  defp parse_enabled(nil), do: {:unset, []}

  defp parse_enabled(value) do
    normalized = value |> String.trim() |> String.downcase()

    cond do
      normalized == "" -> {:unset, []}
      normalized in @truthy -> {true, []}
      normalized in @falsy -> {false, []}
      true -> {:unset, [{:invalid_enabled, value}]}
    end
  end

  defp enabled?(true, _types, _finder), do: true
  defp enabled?(false, _types, _finder), do: false
  defp enabled?(:unset, :unknown, _finder), do: false

  defp enabled?(:unset, types, finder),
    do: not Enum.any?(types, &(&1 in @torrent_handler_types)) and finder.("rqbit") != nil

  # Gluetun names the tunnel wg0 for WireGuard and tun0 for OpenVPN.
  defp vpn_interface(env) do
    case blank_to_nil(env["MYDIA_VPN_VPN_INTERFACE"]) do
      nil ->
        if String.downcase(env["MYDIA_VPN_VPN_TYPE"] || "") |> String.trim() == "wireguard",
          do: "wg0",
          else: "tun0"

      interface ->
        interface
    end
  end

  defp parse_port(value, default, warning) do
    case blank_to_nil(value) do
      nil ->
        {default, []}

      value ->
        case Integer.parse(value) do
          {port, ""} when port in 1..65_535 -> {port, []}
          _ -> {default, [{warning, value}]}
        end
    end
  end

  defp reserved_warnings(env) do
    for name <- @reserved, Map.has_key?(env, "MYDIA_VPN_" <> name), do: {:reserved_variable, name}
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: if(String.trim(value) == "", do: nil, else: value)
end
