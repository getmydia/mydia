defmodule Mydia.Downloads.BuiltIn.Config do
  @moduledoc """
  Reads the built-in torrent client's environment variables.

  Pure: callers pass the environment and the types of the other configured
  download clients, so tests never touch global env.
  """

  # Written to the state directory once the client is on, so a later boot
  # keeps it on after the user adds clients of their own.
  @marker "enabled"

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
          explicit: boolean() | nil,
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
            explicit: nil,
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
  Decides whether the built-in client runs. With MYDIA_TORRENT_ENABLED unset,
  it turns on for a new install, one with no other download client of any
  kind (`other_client_types == []`) and `rqbit` on the PATH, and the
  supervisor then records that in the state directory (`marker_path/1`). A
  recorded install stays on whatever clients are added later, until
  MYDIA_TORRENT_ENABLED=false. An existing install with clients of its own
  stays off unless MYDIA_TORRENT_ENABLED=true.

  `other_client_types` is `:unknown` when the configured clients could not be
  read, which never turns a new install on.

  Options:

    * `:find_executable` (default `System.find_executable/1`) locates `rqbit`.
      Installs without it (bare releases, the NixOS module) stay off unless
      MYDIA_TORRENT_ENABLED=true.
    * `:file_exists?` (default `File.regular?/1`) checks the marker.
    * `:name_taken` (default `false`) says some other configured client,
      enabled or not, already uses the built-in client's reserved name.
      Clients are looked up by name, so the two cannot coexist: the built-in
      client stays off, even with MYDIA_TORRENT_ENABLED=true, and a
      `{:reserved_name_taken}` warning is recorded.
  """
  @spec load(%{String.t() => String.t()}, [atom()] | :unknown, keyword()) :: t()
  def load(env, other_client_types, opts \\ []) do
    {port, port_warnings} = parse_port(env["MYDIA_TORRENT_PORT"], @default_port, :invalid_port)

    {api_port, api_port_warnings} =
      parse_port(env["MYDIA_TORRENT_API_PORT"], @default_api_port, :invalid_api_port)

    {enabled, enabled_warnings} = parse_enabled(env["MYDIA_TORRENT_ENABLED"])
    provider = blank_to_nil(env["MYDIA_VPN_SERVICE_PROVIDER"])
    name_taken? = Keyword.get(opts, :name_taken, false)
    state_dir = blank_to_nil(env["MYDIA_TORRENT_STATE_PATH"]) || @default_state_dir
    wanted? = wanted?(enabled, state_dir, other_client_types, opts)
    name_warnings = if wanted? and name_taken?, do: [{:reserved_name_taken}], else: []

    %__MODULE__{
      enabled?: wanted? and not name_taken?,
      explicit: if(enabled == :unset, do: nil, else: enabled),
      download_path: blank_to_nil(env["MYDIA_TORRENT_DOWNLOAD_PATH"]) || @default_download_path,
      state_dir: state_dir,
      port: port,
      api_port: api_port,
      vpn?: provider != nil,
      vpn_provider: provider,
      vpn_interface: vpn_interface(env),
      warnings:
        enabled_warnings ++
          name_warnings ++ port_warnings ++ api_port_warnings ++ reserved_warnings(env)
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

  @doc "Where the supervisor records that this install runs the built-in client."
  @spec marker_path(t()) :: Path.t()
  def marker_path(%__MODULE__{state_dir: state_dir}), do: Path.join(state_dir, @marker)

  # Whether the client should run, before the reserved-name check.
  defp wanted?(:unset, state_dir, other_client_types, opts) do
    finder = Keyword.get(opts, :find_executable, &System.find_executable/1)
    exists? = Keyword.get(opts, :file_exists?, &File.regular?/1)
    exists?.(Path.join(state_dir, @marker)) or new_install?(other_client_types, finder)
  end

  defp wanted?(explicit, _state_dir, _other_client_types, _opts), do: explicit

  defp new_install?([], finder), do: finder.("rqbit") != nil
  defp new_install?(_types_or_unknown, _finder), do: false

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
