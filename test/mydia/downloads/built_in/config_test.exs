defmodule Mydia.Downloads.BuiltIn.ConfigTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.BuiltIn.Config

  # rqbit is "installed" unless a test says otherwise, so the auto-enable rule
  # does not depend on the machine running the tests.
  defp load(env, types, opts \\ []) do
    Config.load(
      env,
      types,
      Keyword.put_new(opts, :find_executable, fn "rqbit" -> "/bin/rqbit" end)
    )
  end

  defp no_rqbit, do: [find_executable: fn "rqbit" -> nil end]

  describe "load/3 auto-enable" do
    test "is on when no torrent client is configured" do
      assert %Config{enabled?: true} = load(%{}, [:sabnzbd])
    end

    test "is off when a torrent client is configured" do
      for type <- [:qbittorrent, :transmission, :rqbit, :rtorrent] do
        assert %Config{enabled?: false} = load(%{}, [type])
      end
    end

    test "is off when a debrid or blackhole client already takes torrents" do
      assert %Config{enabled?: false} = load(%{}, [:debrid])
      assert %Config{enabled?: false} = load(%{}, [:blackhole])
    end

    test "is off when rqbit is not installed" do
      assert %Config{enabled?: false} = load(%{}, [], no_rqbit())
    end

    test "an explicit true turns it on even without rqbit on the PATH" do
      assert %Config{enabled?: true} = load(%{"MYDIA_TORRENT_ENABLED" => "true"}, [], no_rqbit())
    end

    test "stays off when the configured clients could not be read" do
      assert %Config{enabled?: false} = load(%{}, :unknown)
      assert %Config{enabled?: true} = load(%{"MYDIA_TORRENT_ENABLED" => "true"}, :unknown)
    end

    test "MYDIA_TORRENT_ENABLED forces either way" do
      assert %Config{enabled?: true} = load(%{"MYDIA_TORRENT_ENABLED" => "true"}, [:qbittorrent])
      assert %Config{enabled?: false} = load(%{"MYDIA_TORRENT_ENABLED" => "false"}, [])
    end

    test "MYDIA_TORRENT_ENABLED accepts the usual boolean spellings in any case" do
      for value <- ~w(true TRUE True 1 yes YES on On) do
        assert %Config{enabled?: true, warnings: []} =
                 load(%{"MYDIA_TORRENT_ENABLED" => value}, [:qbittorrent]),
               value
      end

      for value <- ~w(false FALSE False 0 no NO off Off) do
        assert %Config{enabled?: false, warnings: []} =
                 load(%{"MYDIA_TORRENT_ENABLED" => value}, []),
               value
      end
    end

    test "an unrecognised MYDIA_TORRENT_ENABLED warns and is treated as unset" do
      config = load(%{"MYDIA_TORRENT_ENABLED" => "maybe"}, [])
      assert config.enabled?
      assert {:invalid_enabled, "maybe"} in config.warnings

      assert %Config{enabled?: false} = load(%{"MYDIA_TORRENT_ENABLED" => "maybe"}, [:rtorrent])
    end
  end

  describe "load/3 values" do
    test "defaults" do
      config = load(%{}, [])
      assert config.download_path == "/data/downloads"
      assert config.state_dir == "/config/rqbit"
      assert config.port == 51413
      assert config.api_port == 3030
      assert config.vpn? == false
      assert config.vpn_interface == "tun0"
      assert config.gluetun_dir == "/config/gluetun"
      assert config.warnings == []
    end

    test "reads paths, ports and provider" do
      config =
        load(
          %{
            "MYDIA_TORRENT_DOWNLOAD_PATH" => "/downloads",
            "MYDIA_TORRENT_STATE_PATH" => "/state/rqbit",
            "MYDIA_TORRENT_PORT" => "6881",
            "MYDIA_TORRENT_API_PORT" => "4036",
            "MYDIA_VPN_SERVICE_PROVIDER" => "protonvpn",
            "MYDIA_VPN_VPN_INTERFACE" => "tun5"
          },
          []
        )

      assert config.download_path == "/downloads"
      assert config.state_dir == "/state/rqbit"
      assert config.port == 6881
      assert config.api_port == 4036
      assert config.vpn?
      assert config.vpn_provider == "protonvpn"
      assert config.vpn_interface == "tun5"
    end

    test "blank values count as unset" do
      config =
        load(
          %{
            "MYDIA_TORRENT_DOWNLOAD_PATH" => " ",
            "MYDIA_TORRENT_STATE_PATH" => "",
            "MYDIA_TORRENT_PORT" => "",
            "MYDIA_TORRENT_API_PORT" => " ",
            "MYDIA_TORRENT_ENABLED" => "",
            "MYDIA_VPN_VPN_INTERFACE" => " "
          },
          []
        )

      assert config.download_path == "/data/downloads"
      assert config.state_dir == "/config/rqbit"
      assert config.port == 51413
      assert config.api_port == 3030
      assert config.vpn_interface == "tun0"
      assert config.enabled?
      assert config.warnings == []
    end

    test "WireGuard uses gluetun's wg0 interface unless one is set" do
      wireguard = %{
        "MYDIA_VPN_SERVICE_PROVIDER" => "protonvpn",
        "MYDIA_VPN_VPN_TYPE" => "WireGuard"
      }

      assert load(wireguard, []).vpn_interface == "wg0"

      assert load(Map.put(wireguard, "MYDIA_VPN_VPN_INTERFACE", "wg7"), []).vpn_interface ==
               "wg7"

      openvpn = %{"MYDIA_VPN_SERVICE_PROVIDER" => "pia", "MYDIA_VPN_VPN_TYPE" => "openvpn"}
      assert load(openvpn, []).vpn_interface == "tun0"
    end

    test "a bad port falls back to the default with a warning" do
      config = load(%{"MYDIA_TORRENT_PORT" => "nope", "MYDIA_TORRENT_API_PORT" => "70000"}, [])
      assert config.port == 51413
      assert config.api_port == 3030
      assert {:invalid_port, "nope"} in config.warnings
      assert {:invalid_api_port, "70000"} in config.warnings
    end

    test "reserved gluetun variables are reported" do
      config =
        load(
          %{
            "MYDIA_VPN_SERVICE_PROVIDER" => "pia",
            "MYDIA_VPN_SPLIT_TUNNEL_GID" => "5",
            "MYDIA_VPN_DNS_SERVER" => "off"
          },
          []
        )

      assert {:reserved_variable, "SPLIT_TUNNEL_GID"} in config.warnings
      assert {:reserved_variable, "DNS_SERVER"} in config.warnings
    end
  end

  describe "child_env_unset/1" do
    test "unsets the VPN variables and Mydia's secrets, nothing else" do
      env = %{
        "MYDIA_VPN_WIREGUARD_PRIVATE_KEY" => "k",
        "MYDIA_VPN_SERVER_REGIONS" => "Netherlands",
        "SECRET_KEY_BASE" => "s",
        "DATABASE_URL" => "postgres://u:p@db/mydia",
        "GUARDIAN_SECRET_KEY" => "g",
        "SOME_API_TOKEN" => "t",
        "SMTP_PASSWORD" => "p",
        "TMDB_KEY" => "k",
        "PATH" => "/bin",
        "HOME" => "/home/mydia",
        "MYDIA_TORRENT_PORT" => "51413"
      }

      unset = Config.child_env_unset(env)
      assert Enum.all?(unset, &match?({_, false}, &1))

      assert unset |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
               Enum.sort(~w(
                 MYDIA_VPN_WIREGUARD_PRIVATE_KEY MYDIA_VPN_SERVER_REGIONS SECRET_KEY_BASE
                 DATABASE_URL GUARDIAN_SECRET_KEY SOME_API_TOKEN SMTP_PASSWORD TMDB_KEY
               ))
    end
  end
end
