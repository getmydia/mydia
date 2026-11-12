defmodule Mydia.Downloads.BuiltIn.VpnProviders do
  @moduledoc """
  The VPN providers the bundled gluetun can use, for the settings form.

  Built from gluetun v3.41.3 (`vendor/gluetun/VERSION`), files under
  `https://raw.githubusercontent.com/qdm12/gluetun/v3.41.3/`:

    * `internal/constants/providers/providers.go`: the provider names
      (`All()`, which leaves out `custom` and `example`; `custom` needs a
      config file the UI does not take).
    * `internal/configuration/settings/wireguard.go`: the providers that
      accept `VPN_TYPE=wireguard`. Every provider accepts OpenVPN.
    * `internal/configuration/settings/portforward.go`: the providers that
      accept `VPN_PORT_FORWARDING=on`.

  `name` is gluetun's exact `VPN_SERVICE_PROVIDER` string; `label` is for
  display. `extra_env` lists the gluetun variables a provider requires that
  the form cannot supply (client certificates and keys, a WireGuard preshared
  key), from the `validate` functions in `internal/configuration/settings/openvpn.go`
  (`validateOpenVPNClientCertificate`, `validateOpenVPNClientKey`,
  `validateOpenVPNEncryptedKey`) and `wireguard.go` (the AirVPN preshared key
  check). They go in the container environment as `MYDIA_VPN_<NAME>`.
  Refresh this table when `vendor/gluetun/VERSION` changes.
  """

  @gluetun_version "v3.41.3"

  @wireguard ~w(airvpn fastestvpn ivpn mullvad nordvpn protonvpn surfshark windscribe)
  @port_forwarding ["perfect privacy", "private internet access", "privatevpn", "protonvpn"]

  @providers [
    {"airvpn", "AirVPN"},
    {"cyberghost", "CyberGhost"},
    {"expressvpn", "ExpressVPN"},
    {"fastestvpn", "FastestVPN"},
    {"giganews", "Giganews"},
    {"hidemyass", "HideMyAss"},
    {"ipvanish", "IPVanish"},
    {"ivpn", "IVPN"},
    {"mullvad", "Mullvad"},
    {"nordvpn", "NordVPN"},
    {"perfect privacy", "Perfect Privacy"},
    {"privado", "Privado"},
    {"private internet access", "Private Internet Access"},
    {"privatevpn", "PrivateVPN"},
    {"protonvpn", "Proton VPN"},
    {"purevpn", "PureVPN"},
    {"slickvpn", "SlickVPN"},
    {"surfshark", "Surfshark"},
    {"torguard", "TorGuard"},
    {"vpnsecure", "VPNSecure"},
    {"vpn unlimited", "VPN Unlimited"},
    {"vyprvpn", "VyprVPN"},
    {"windscribe", "Windscribe"}
  ]

  @extra_env %{
    "airvpn" => ["OPENVPN_CERT", "OPENVPN_KEY", "WIREGUARD_PRESHARED_KEY"],
    "cyberghost" => ["OPENVPN_CERT", "OPENVPN_KEY"],
    "vpnsecure" => ["OPENVPN_CERT", "OPENVPN_ENCRYPTED_KEY", "OPENVPN_KEY_PASSPHRASE"],
    "vpn unlimited" => ["OPENVPN_CERT", "OPENVPN_KEY"]
  }

  @type provider :: %{
          name: String.t(),
          label: String.t(),
          types: [String.t()],
          port_forwarding?: boolean(),
          extra_env: [String.t()]
        }

  @table Enum.map(@providers, fn {name, label} ->
           %{
             name: name,
             label: label,
             types: if(name in @wireguard, do: ["openvpn", "wireguard"], else: ["openvpn"]),
             port_forwarding?: name in @port_forwarding,
             extra_env: Map.get(@extra_env, name, [])
           }
         end)

  @doc "The gluetun release this table was built from."
  @spec gluetun_version() :: String.t()
  def gluetun_version, do: @gluetun_version

  @doc "Every supported provider, in gluetun's order."
  @spec all() :: [provider()]
  def all, do: @table

  @doc "The provider with this exact gluetun name, or nil."
  @spec get(term()) :: provider() | nil
  def get(name) when is_binary(name), do: Enum.find(@table, &(&1.name == name))
  def get(_), do: nil
end
