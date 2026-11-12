defmodule Mydia.Downloads.BuiltIn.Config do
  @moduledoc """
  Builds the built-in torrent client's settings from the layered runtime
  config section (`Mydia.Config.Schema.BuiltInTorrent`).

  Pure: callers pass the section, the environment and the types of the other
  configured download clients, so tests never touch global env. Values come
  from the section; the environment is read only for warnings, reserved
  names, `MYDIA_VPN_VPN_INTERFACE` and `env_vpn_names`.
  """

  alias Mydia.Config.Schema.BuiltInTorrent

  # Written to the state directory once the client is on, so a later boot
  # keeps it on after the user adds clients of their own.
  @marker "enabled"

  @reserved ~w(SPLIT_TUNNEL_GID HTTP_CONTROL_SERVER_ADDRESS HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE HTTP_CONTROL_SERVER_AUTH_CONFIG_FILEPATH DNS_ADDRESS DNS_SERVER)
  @default_port 51413
  @default_api_port 3030
  @default_download_path "/data/downloads"
  @default_state_dir "/config/rqbit"

  @truthy ~w(true 1 yes on)
  @falsy ~w(false 0 no off)

  # Inherited variables a child process must never see: the VPN credentials
  # and Mydia's own secrets. Matched by name so new secrets are covered too.
  @secret_names ~w(SECRET_KEY_BASE DATABASE_URL GUARDIAN_SECRET_KEY)

  # What only the VPN reads: left out of `restart_key/1` while it is off.
  @vpn_keys [:vpn_provider, :vpn_type, :vpn_interface, :env_vpn_names]
  @section_vpn_fields for {field, _var} <- BuiltInTorrent.env_vars(),
                          String.starts_with?(Atom.to_string(field), "vpn_"),
                          do: field
  @secret_fragments ~w(SECRET PASSWORD TOKEN)

  @type t :: %__MODULE__{
          enabled?: boolean(),
          explicit: boolean() | nil,
          rqbit_missing?: boolean(),
          download_path: String.t(),
          port: pos_integer(),
          api_port: pos_integer(),
          vpn?: boolean(),
          vpn_provider: String.t() | nil,
          vpn_type: String.t() | nil,
          vpn_section: BuiltInTorrent.t(),
          vpn_interface: String.t(),
          env_vpn_names: [String.t()],
          state_dir: String.t(),
          gluetun_dir: String.t(),
          warnings: [term()]
        }

  defstruct enabled?: false,
            explicit: nil,
            rqbit_missing?: false,
            download_path: @default_download_path,
            port: @default_port,
            api_port: @default_api_port,
            vpn?: false,
            vpn_provider: nil,
            vpn_type: nil,
            vpn_section: %BuiltInTorrent{},
            vpn_interface: "tun0",
            env_vpn_names: [],
            state_dir: @default_state_dir,
            gluetun_dir: "/config/gluetun",
            warnings: []

  @doc """
  Decides whether the built-in client runs. With `enabled` nil in the
  section, it turns on for a new install, one with no other download client
  of any kind (`other_client_types == []`) and `rqbit` on the PATH, and the
  manager then records that in the state directory (`marker_path/1`). A
  recorded install stays on whatever clients are added later, until `enabled`
  is false. An existing install with clients of its own stays off unless
  `enabled` is true.

  `other_client_types` is `:unknown` when the configured clients could not be
  read, which never turns a new install on.

  Options:

    * `:find_executable` (default `System.find_executable/1`) locates `rqbit`.
      Installs without it (bare releases, the NixOS module) stay off unless
      `enabled` is true.
    * `:file_exists?` (default `File.regular?/1`) checks the marker.
    * `:name_taken` (default `false`) says some other configured client,
      enabled or not, already uses the built-in client's reserved name.
      Clients are looked up by name, so the two cannot coexist: the built-in
      client stays off, even with `enabled: true`, and a
      `{:reserved_name_taken}` warning is recorded.
  """
  @spec from_runtime(
          BuiltInTorrent.t(),
          %{String.t() => String.t()},
          [atom()] | :unknown,
          keyword()
        ) :: t()
  def from_runtime(%BuiltInTorrent{} = section, env, other_client_types, opts \\ []) do
    name_taken? = Keyword.get(opts, :name_taken, false)
    state_dir = blank_to_nil(section.state_path) || @default_state_dir
    wanted? = wanted?(section.enabled, state_dir, other_client_types, opts)
    name_warnings = if wanted? and name_taken?, do: [{:reserved_name_taken}], else: []

    %__MODULE__{
      enabled?: wanted? and not name_taken?,
      explicit: section.enabled,
      rqbit_missing?: rqbit_missing?(section.enabled, wanted?, other_client_types),
      download_path: blank_to_nil(section.download_path) || @default_download_path,
      state_dir: state_dir,
      port: section.listen_port || @default_port,
      api_port: section.api_port || @default_api_port,
      vpn?: section.vpn_enabled == true,
      vpn_provider: blank_to_nil(section.vpn_provider),
      vpn_type: blank_to_nil(section.vpn_type),
      vpn_section: section,
      vpn_interface: vpn_interface(section, env),
      env_vpn_names: env_vpn_names(env),
      warnings:
        enabled_warnings(env["MYDIA_TORRENT_ENABLED"]) ++
          name_warnings ++
          port_warnings(env["MYDIA_TORRENT_PORT"], :invalid_port) ++
          port_warnings(env["MYDIA_TORRENT_API_PORT"], :invalid_api_port) ++
          reserved_warnings(env)
    }
  end

  @doc """
  What `BuiltIn.Manager` compares to decide whether a reload needs a restart:
  the config minus `warnings` and, while the VPN is off, minus every VPN
  field, since those do not reach a client running without it. Turning the
  VPN on still changes the key.
  """
  @spec restart_key(t()) :: map()
  def restart_key(%__MODULE__{} = config) do
    key = config |> Map.from_struct() |> Map.delete(:warnings)

    if config.vpn? do
      key
    else
      key
      |> Map.drop(@vpn_keys)
      |> Map.update!(:vpn_section, &(&1 |> Map.from_struct() |> Map.drop(@section_vpn_fields)))
    end
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

  # The section already holds the resolved value; the raw string is re-read
  # only to tell the user an unrecognised one was ignored.
  defp enabled_warnings(nil), do: []

  defp enabled_warnings(value) do
    normalized = value |> String.trim() |> String.downcase()

    if normalized == "" or normalized in @truthy or normalized in @falsy,
      do: [],
      else: [{:invalid_enabled, value}]
  end

  @doc "Where `BuiltIn.Manager` records that this install runs the built-in client."
  @spec marker_path(t()) :: Path.t()
  def marker_path(%__MODULE__{state_dir: state_dir}), do: Path.join(state_dir, @marker)

  # Whether the client should run, before the reserved-name check.
  defp wanted?(nil, state_dir, other_client_types, opts) do
    finder = Keyword.get(opts, :find_executable, &System.find_executable/1)
    exists? = Keyword.get(opts, :file_exists?, &File.regular?/1)
    exists?.(Path.join(state_dir, @marker)) or new_install?(other_client_types, finder)
  end

  defp wanted?(explicit, _state_dir, _other_client_types, _opts), do: explicit

  # Automatic, not recorded and no other client: the only thing keeping a new
  # install off is rqbit missing from the PATH.
  defp rqbit_missing?(nil = _explicit, false = _wanted?, []), do: true
  defp rqbit_missing?(_explicit, _wanted?, _other_client_types), do: false

  defp new_install?([], finder), do: finder.("rqbit") != nil
  defp new_install?(_types_or_unknown, _finder), do: false

  # Gluetun names the tunnel wg0 for WireGuard and tun0 for OpenVPN.
  defp vpn_interface(section, env) do
    case blank_to_nil(env["MYDIA_VPN_VPN_INTERFACE"]) do
      nil -> if section.vpn_type == "wireguard", do: "wg0", else: "tun0"
      interface -> interface
    end
  end

  defp port_warnings(value, warning) do
    case blank_to_nil(value) do
      nil ->
        []

      value ->
        case Integer.parse(value) do
          {port, ""} when port in 1..65_535 -> []
          _ -> [{warning, value}]
        end
    end
  end

  # MYDIA_VPN_* names set in the environment that the section has no field
  # for: handed to gluetun as they are and invisible to the settings form.
  defp env_vpn_names(env) do
    covered = for {_field, name} <- BuiltInTorrent.env_vars(), do: name

    names =
      for {name, value} <- env,
          String.starts_with?(name, "MYDIA_VPN_"),
          name not in covered,
          blank_to_nil(value) != nil,
          do: name

    Enum.sort(names)
  end

  defp reserved_warnings(env) do
    for name <- @reserved, Map.has_key?(env, "MYDIA_VPN_" <> name), do: {:reserved_variable, name}
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: if(String.trim(value) == "", do: nil, else: value)
end
