defmodule Mydia.Downloads.BuiltIn.VpnSettings do
  @moduledoc """
  Renders and writes `settings.env`, the file the root-side gluetun loop
  reads (one `KEY=value` per line, no quoting, no shell evaluation).

  Keys are written in the loop's allowlist order, `VPN_ENABLED` first.
  Fields whose environment variable is set are left out: those values reach
  gluetun from the root's own environment and are never copied to disk. Nil
  and blank fields are left out too. The file is written atomically (temp
  file, then rename) with mode 600, and not at all when it already holds the
  same bytes.
  """

  alias Mydia.Config.Schema.BuiltInTorrent
  alias Mydia.Downloads.BuiltIn.Config

  # In a subdirectory of its own: the root-side loop never opens anything
  # under /config itself; it reads this file as mydia.
  @file_name "settings/settings.env"

  # {section field, gluetun key}, in the loop's allowlist order.
  @fields [
    vpn_provider: "VPN_SERVICE_PROVIDER",
    vpn_type: "VPN_TYPE",
    vpn_openvpn_user: "OPENVPN_USER",
    vpn_openvpn_password: "OPENVPN_PASSWORD",
    vpn_wireguard_private_key: "WIREGUARD_PRIVATE_KEY",
    vpn_wireguard_addresses: "WIREGUARD_ADDRESSES",
    vpn_server_countries: "SERVER_COUNTRIES",
    vpn_server_regions: "SERVER_REGIONS",
    vpn_server_cities: "SERVER_CITIES",
    vpn_server_hostnames: "SERVER_HOSTNAMES",
    vpn_port_forwarding: "VPN_PORT_FORWARDING"
  ]

  @doc "Where the settings file lives."
  @spec path(Config.t()) :: Path.t()
  def path(%Config{gluetun_dir: dir}), do: Path.join(dir, @file_name)

  @doc "Lowercase SHA-256 hex of the file content."
  @spec hash(binary()) :: String.t()
  def hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  @doc """
  The file content for this config. `env` is the process environment (a map),
  used only to tell which fields come from env. Raises `ArgumentError` when a
  value contains a newline; the message never includes the value.
  """
  @spec render(Config.t(), %{String.t() => String.t()}) :: String.t()
  def render(%Config{enabled?: true, vpn?: true, vpn_section: section}, env) do
    env_vars = BuiltInTorrent.env_vars()

    lines =
      for {field, key} <- @fields,
          not env_set?(env, Keyword.fetch!(env_vars, field)),
          value = value(field, Map.fetch!(section, field)),
          value != nil do
        if String.contains?(value, ["\n", "\r"]) do
          raise ArgumentError, "VPN setting #{key} contains a line break"
        end

        "#{key}=#{value}\n"
      end

    IO.iodata_to_binary(["VPN_ENABLED=true\n" | lines])
  end

  def render(%Config{}, _env), do: "VPN_ENABLED=false\n"

  @doc """
  Writes the file for this config and returns the content hash. Skips the
  write when the file already holds identical bytes.
  """
  @spec write(Config.t(), %{String.t() => String.t()}) ::
          {:ok, String.t()} | {:error, {:vpn_settings_write_failed, atom()}}
  def write(%Config{} = config, env) do
    content = render(config, env)
    target = path(config)

    with :ok <- unless_unchanged(target, content),
         :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- atomic_write(target, content) do
      {:ok, hash(content)}
    else
      :unchanged -> {:ok, hash(content)}
      {:error, posix} -> {:error, {:vpn_settings_write_failed, posix}}
    end
  end

  defp unless_unchanged(target, content) do
    case File.read(target) do
      {:ok, ^content} -> :unchanged
      _ -> :ok
    end
  end

  defp atomic_write(target, content) do
    tmp = "#{target}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.write(tmp, content, [:exclusive]),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, target) do
      :ok
    else
      {:error, _} = error ->
        File.rm(tmp)
        error
    end
  end

  defp env_set?(env, name) do
    case Map.get(env, name) do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end

  defp value(:vpn_port_forwarding, true), do: "on"
  defp value(:vpn_port_forwarding, _), do: nil

  defp value(_field, value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp value(_field, _), do: nil
end
