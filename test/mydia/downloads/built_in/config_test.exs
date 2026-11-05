defmodule Mydia.Downloads.BuiltIn.ConfigTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.BuiltIn.Config

  describe "load/2 auto-enable" do
    test "is on when no torrent client is configured" do
      assert %Config{enabled?: true} = Config.load(%{}, [:sabnzbd])
    end

    test "is off when a torrent client is configured" do
      for type <- [:qbittorrent, :transmission, :rqbit, :rtorrent] do
        assert %Config{enabled?: false} = Config.load(%{}, [type])
      end
    end

    test "stays off when the configured clients could not be read" do
      assert %Config{enabled?: false} = Config.load(%{}, :unknown)
      assert %Config{enabled?: true} = Config.load(%{"MYDIA_TORRENT_ENABLED" => "true"}, :unknown)
    end

    test "MYDIA_TORRENT_ENABLED forces either way" do
      assert %Config{enabled?: true} =
               Config.load(%{"MYDIA_TORRENT_ENABLED" => "true"}, [:qbittorrent])

      assert %Config{enabled?: false} = Config.load(%{"MYDIA_TORRENT_ENABLED" => "false"}, [])
    end
  end

  describe "load/2 values" do
    test "defaults" do
      config = Config.load(%{}, [])
      assert config.download_path == "/data/downloads"
      assert config.port == 51413
      assert config.vpn? == false
      assert config.vpn_interface == "tun0"
      assert config.state_dir == "/config/rqbit"
      assert config.gluetun_dir == "/config/gluetun"
      assert config.warnings == []
    end

    test "reads path, port and provider" do
      config =
        Config.load(
          %{
            "MYDIA_TORRENT_DOWNLOAD_PATH" => "/downloads",
            "MYDIA_TORRENT_PORT" => "6881",
            "MYDIA_VPN_SERVICE_PROVIDER" => "protonvpn",
            "MYDIA_VPN_VPN_INTERFACE" => "wg0"
          },
          []
        )

      assert config.download_path == "/downloads"
      assert config.port == 6881
      assert config.vpn?
      assert config.vpn_provider == "protonvpn"
      assert config.vpn_interface == "wg0"
    end

    test "a bad port falls back to the default with a warning" do
      config = Config.load(%{"MYDIA_TORRENT_PORT" => "nope"}, [])
      assert config.port == 51413
      assert {:invalid_port, "nope"} in config.warnings
    end

    test "reserved gluetun variables are reported" do
      config =
        Config.load(
          %{"MYDIA_VPN_SERVICE_PROVIDER" => "pia", "MYDIA_VPN_SPLIT_TUNNEL_GID" => "5"},
          []
        )

      assert {:reserved_variable, "SPLIT_TUNNEL_GID"} in config.warnings
    end
  end
end
