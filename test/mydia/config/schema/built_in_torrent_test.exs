defmodule Mydia.Config.Schema.BuiltInTorrentTest do
  use ExUnit.Case, async: true

  alias Mydia.Config.Schema.BuiltInTorrent

  test "provider and type are trimmed and downcased" do
    cs =
      BuiltInTorrent.changeset(%BuiltInTorrent{}, %{
        "vpn_provider" => " ProtonVPN ",
        "vpn_type" => "WireGuard"
      })

    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :vpn_provider) == "protonvpn"
    assert Ecto.Changeset.get_field(cs, :vpn_type) == "wireguard"
  end

  test "defaults" do
    s = %BuiltInTorrent{}
    assert s.enabled == nil
    assert s.download_path == "/data/downloads"
    assert s.state_path == "/config/rqbit"
    assert s.listen_port == 51413
    assert s.api_port == 3030
    assert s.vpn_enabled == false
    assert s.vpn_port_forwarding == false
  end

  test "ports must be in 1..65535" do
    for field <- [:listen_port, :api_port], value <- [0, 70_000] do
      cs = BuiltInTorrent.changeset(%BuiltInTorrent{}, %{field => value})
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, field)
    end

    assert BuiltInTorrent.changeset(%BuiltInTorrent{}, %{listen_port: 65_535}).valid?
  end

  test "secrets are redacted from inspect" do
    s = %BuiltInTorrent{vpn_openvpn_password: "hunter2", vpn_wireguard_private_key: "wgkey123"}
    out = inspect(s)
    refute out =~ "hunter2"
    refute out =~ "wgkey123"
  end

  test "env_vars/0 has one row per field" do
    rows = BuiltInTorrent.env_vars()
    assert length(rows) == 19
    assert rows |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == 19
    assert {:vpn_enabled, "MYDIA_VPN_SERVICE_PROVIDER"} in rows
    assert {:listen_port, "MYDIA_TORRENT_PORT"} in rows
    assert {:download_limit_kib, "MYDIA_TORRENT_DOWNLOAD_LIMIT"} in rows
    assert {:upload_limit_kib, "MYDIA_TORRENT_UPLOAD_LIMIT"} in rows
  end

  test "changeset/2 bounds the rate limits to what rqbit accepts" do
    max = BuiltInTorrent.max_rate_limit_kib()
    assert max == 4_194_303

    valid = BuiltInTorrent.changeset(%BuiltInTorrent{}, %{download_limit_kib: max})
    assert valid.valid?

    for bad <- [0, max + 1] do
      refute BuiltInTorrent.changeset(%BuiltInTorrent{}, %{upload_limit_kib: bad}).valid?
    end
  end

  test "secret_fields/0" do
    assert BuiltInTorrent.secret_fields() == [:vpn_openvpn_password, :vpn_wireguard_private_key]
  end
end
