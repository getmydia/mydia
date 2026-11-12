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

  test "mullvad has no port forwarding" do
    assert %{port_forwarding?: false} = VpnProviders.get("mullvad")
  end

  test "extra_env names what the form cannot supply, empty by default" do
    assert %{extra_env: ["OPENVPN_CERT", "OPENVPN_KEY"]} = VpnProviders.get("cyberghost")

    assert %{extra_env: ["OPENVPN_CERT", "OPENVPN_ENCRYPTED_KEY", "OPENVPN_KEY_PASSPHRASE"]} =
             VpnProviders.get("vpnsecure")

    assert "WIREGUARD_PRESHARED_KEY" in VpnProviders.get("airvpn").extra_env
    assert VpnProviders.get("mullvad").extra_env == []
  end

  test "get/1 returns nil for unknown names" do
    assert VpnProviders.get("nope") == nil
    assert VpnProviders.get(nil) == nil
  end
end
