defmodule Mydia.Downloads.BuiltIn.VpnSettingsTest do
  use ExUnit.Case, async: true

  alias Mydia.Config.Schema.BuiltInTorrent
  alias Mydia.Downloads.BuiltIn.{Config, VpnSettings}

  @key "a=b$c 'd\""

  defp config(fields, opts \\ []) do
    %Config{
      enabled?: Keyword.get(opts, :enabled?, true),
      vpn?: Keyword.get(opts, :vpn?, true),
      vpn_section: struct!(BuiltInTorrent, fields),
      gluetun_dir: Keyword.get(opts, :dir, "/config/gluetun")
    }
  end

  defp mullvad(extra \\ []) do
    [vpn_provider: "mullvad", vpn_type: "wireguard", vpn_wireguard_private_key: @key] ++ extra
  end

  test "path/1 is settings/settings.env under the gluetun dir" do
    assert VpnSettings.path(config([], dir: "/x/y")) == "/x/y/settings/settings.env"
  end

  test "render/2 writes the allowlisted keys in order" do
    assert VpnSettings.render(config(mullvad()), %{}) ==
             "VPN_ENABLED=true\nVPN_SERVICE_PROVIDER=mullvad\nVPN_TYPE=wireguard\n" <>
               "WIREGUARD_PRIVATE_KEY=#{@key}\n"
  end

  test "render/2 omits fields whose env var is set" do
    out = VpnSettings.render(config(mullvad()), %{"MYDIA_VPN_WIREGUARD_PRIVATE_KEY" => "x"})
    refute out =~ "WIREGUARD_PRIVATE_KEY"
    assert out =~ "VPN_SERVICE_PROVIDER=mullvad"
  end

  test "a blank env value does not count as set" do
    out = VpnSettings.render(config(mullvad()), %{"MYDIA_VPN_WIREGUARD_PRIVATE_KEY" => "  "})
    assert out =~ "WIREGUARD_PRIVATE_KEY="
  end

  test "render/2 is exactly VPN_ENABLED=false when the VPN or client is off" do
    assert VpnSettings.render(config(mullvad(), vpn?: false), %{}) == "VPN_ENABLED=false\n"
    assert VpnSettings.render(config(mullvad(), enabled?: false), %{}) == "VPN_ENABLED=false\n"
  end

  test "port forwarding is on only when true" do
    assert VpnSettings.render(config(mullvad(vpn_port_forwarding: true)), %{}) =~
             "VPN_PORT_FORWARDING=on\n"

    refute VpnSettings.render(config(mullvad(vpn_port_forwarding: false)), %{}) =~
             "VPN_PORT_FORWARDING"
  end

  test "blank values are omitted and the remaining keys keep their order" do
    out =
      VpnSettings.render(
        config(
          vpn_provider: "protonvpn",
          vpn_type: "openvpn",
          vpn_openvpn_user: "u",
          vpn_openvpn_password: "p",
          vpn_wireguard_addresses: "",
          vpn_server_countries: "Sweden",
          vpn_server_regions: nil,
          vpn_server_cities: "Oslo",
          vpn_server_hostnames: "h1"
        ),
        %{}
      )

    assert out ==
             "VPN_ENABLED=true\nVPN_SERVICE_PROVIDER=protonvpn\nVPN_TYPE=openvpn\n" <>
               "OPENVPN_USER=u\nOPENVPN_PASSWORD=p\nSERVER_COUNTRIES=Sweden\n" <>
               "SERVER_CITIES=Oslo\nSERVER_HOSTNAMES=h1\n"
  end

  test "render/2 raises on a newline without leaking the value" do
    err =
      assert_raise ArgumentError, fn ->
        VpnSettings.render(config(mullvad(vpn_openvpn_password: "sekrit\nINJECT=1")), %{})
      end

    refute err.message =~ "sekrit"
  end

  test "render/2 raises past the 65536 bytes the root-side loop reads, without the value" do
    long = String.duplicate("k", 10_000)

    fields =
      mullvad(
        vpn_wireguard_private_key: long,
        vpn_wireguard_addresses: long,
        vpn_server_countries: long,
        vpn_server_regions: long,
        vpn_server_cities: long,
        vpn_server_hostnames: long,
        vpn_openvpn_user: long
      )

    err = assert_raise ArgumentError, fn -> VpnSettings.render(config(fields), %{}) end
    assert err.message =~ "65536"
    refute err.message =~ "kkkk"

    # Just under the limit still renders.
    fits = mullvad(vpn_server_countries: String.duplicate("k", 60_000))
    assert byte_size(VpnSettings.render(config(fits), %{})) <= 65_536
  end

  test "hash/1 is lowercase sha256 hex" do
    assert VpnSettings.hash("abc") ==
             "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  end

  @tag :tmp_dir
  test "write/2 writes mode 600 with no temp file left", %{tmp_dir: dir} do
    cfg = config(mullvad(), dir: dir)
    content = VpnSettings.render(cfg, %{})

    assert {:ok, hash} = VpnSettings.write(cfg, %{})
    assert hash == VpnSettings.hash(content)
    assert File.read!(VpnSettings.path(cfg)) == content
    assert File.stat!(VpnSettings.path(cfg)).mode |> Bitwise.band(0o777) == 0o600
    assert File.ls!(Path.join(dir, "settings")) == ["settings.env"]
  end

  @tag :tmp_dir
  test "write/2 keeps the settings directory private, new or existing", %{tmp_dir: dir} do
    mode = fn path -> File.stat!(path).mode |> Bitwise.band(0o777) end

    fresh = config(mullvad(), dir: Path.join(dir, "fresh"))
    assert {:ok, _} = VpnSettings.write(fresh, %{})
    assert mode.(Path.dirname(VpnSettings.path(fresh))) == 0o700
    assert mode.(VpnSettings.path(fresh)) == 0o600

    wide = config(mullvad(), dir: Path.join(dir, "wide"))
    File.mkdir_p!(Path.dirname(VpnSettings.path(wide)))
    File.chmod!(Path.dirname(VpnSettings.path(wide)), 0o755)
    assert {:ok, _} = VpnSettings.write(wide, %{})
    assert mode.(Path.dirname(VpnSettings.path(wide))) == 0o700
    assert mode.(VpnSettings.path(wide)) == 0o600
  end

  @tag :tmp_dir
  test "write/2 creates the gluetun dir and the settings subdir", %{tmp_dir: dir} do
    cfg = config(mullvad(), dir: Path.join(dir, "nested/gluetun"))
    assert {:ok, _} = VpnSettings.write(cfg, %{})
    assert File.exists?(Path.join(dir, "nested/gluetun/settings/settings.env"))
  end

  @tag :tmp_dir
  test "an identical second write leaves the file untouched", %{tmp_dir: dir} do
    cfg = config(mullvad(), dir: dir)
    {:ok, hash} = VpnSettings.write(cfg, %{})
    path = VpnSettings.path(cfg)
    File.touch!(path, {{2020, 1, 1}, {0, 0, 0}})
    before = File.stat!(path).mtime

    assert {:ok, ^hash} = VpnSettings.write(cfg, %{})
    assert File.stat!(path).mtime == before

    {:ok, other} = VpnSettings.write(config(mullvad(vpn_server_cities: "Oslo"), dir: dir), %{})
    refute other == hash
  end

  @tag :tmp_dir
  test "a read-only directory returns the posix error", %{tmp_dir: dir} do
    File.chmod!(dir, 0o500)
    on_exit(fn -> File.chmod(dir, 0o700) end)

    if File.touch(Path.join(dir, "probe")) == :ok do
      # running as root: permissions cannot be enforced here
      :ok
    else
      assert {:error, {:vpn_settings_write_failed, :eacces}} =
               VpnSettings.write(config(mullvad(), dir: dir), %{})
    end
  end
end
