defmodule Mydia.Downloads.BuiltIn.VpnProvidersTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.BuiltIn.VpnProviders

  test "gluetun_version/0 matches the vendored VERSION file" do
    assert VpnProviders.gluetun_version() == String.trim(File.read!("vendor/gluetun/VERSION"))
  end

  test "every provider supports at least one known type" do
    for p <- VpnProviders.all() do
      assert p.types != [], p.name
      assert Enum.all?(p.types, &(&1 in ["openvpn", "wireguard"])), p.name
      assert p.label != "", p.name
    end
  end

  test "names are unique and exclude custom and example" do
    names = Enum.map(VpnProviders.all(), & &1.name)
    assert names == Enum.uniq(names)
    refute "custom" in names
    refute "example" in names
  end

  test "protonvpn supports both types with port forwarding" do
    assert %{types: types, port_forwarding?: true} = VpnProviders.get("protonvpn")
    assert Enum.sort(types) == ["openvpn", "wireguard"]
  end

  test "private internet access is OpenVPN-only with port forwarding" do
    assert %{types: ["openvpn"], port_forwarding?: true} =
             VpnProviders.get("private internet access")
  end

  test "pia is gluetun's alias for private internet access, matched like gluetun" do
    pia = VpnProviders.get("private internet access")
    assert VpnProviders.get("pia") == pia
    assert VpnProviders.get(" PIA ") == pia
    assert VpnProviders.get("ProtonVPN") == VpnProviders.get("protonvpn")
  end

  test "mullvad has no port forwarding" do
    assert %{port_forwarding?: false} = VpnProviders.get("mullvad")
  end

  test "extra_env/2 names what the form cannot supply for the chosen type" do
    assert VpnProviders.extra_env("cyberghost", "openvpn") == ["OPENVPN_CERT", "OPENVPN_KEY"]

    assert VpnProviders.extra_env("vpnsecure", "openvpn") ==
             ["OPENVPN_CERT", "OPENVPN_ENCRYPTED_KEY", "OPENVPN_KEY_PASSPHRASE"]

    assert VpnProviders.extra_env("airvpn", "openvpn") == ["OPENVPN_CERT", "OPENVPN_KEY"]
    assert VpnProviders.extra_env("airvpn", "wireguard") == ["WIREGUARD_PRESHARED_KEY"]
    assert VpnProviders.extra_env("mullvad", "wireguard") == []
    assert VpnProviders.extra_env("mullvad", "openvpn") == []
  end

  test "extra_env/2 treats a nil type as the first supported one and resolves aliases" do
    assert VpnProviders.extra_env("airvpn", nil) == ["OPENVPN_CERT", "OPENVPN_KEY"]
    assert VpnProviders.extra_env("pia", nil) == []
    assert VpnProviders.extra_env("nope", nil) == []
    assert VpnProviders.extra_env(nil, "openvpn") == []
  end

  test "get/1 returns nil for unknown names" do
    assert VpnProviders.get("nope") == nil
    assert VpnProviders.get(nil) == nil
  end
end
