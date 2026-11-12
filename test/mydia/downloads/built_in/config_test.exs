defmodule Mydia.Downloads.BuiltIn.ConfigTest do
  use ExUnit.Case, async: true

  alias Mydia.Config.Schema.BuiltInTorrent
  alias Mydia.Downloads.BuiltIn.Config

  # `fields` are the section's values (what the layered config resolved);
  # `:env` in opts is the raw environment, read only for warnings, reserved
  # names and the interface override.
  #
  # rqbit is "installed" and nothing is recorded in the state directory unless
  # a test says otherwise, so the auto-enable rule does not depend on the
  # machine running the tests.
  defp load(fields, types, opts \\ []) do
    {env, opts} = Keyword.pop(opts, :env, %{})

    opts =
      opts
      |> Keyword.put_new(:find_executable, fn "rqbit" -> "/bin/rqbit" end)
      |> Keyword.put_new(:file_exists?, fn _path -> false end)

    Config.from_runtime(struct!(BuiltInTorrent, fields), env, types, opts)
  end

  defp no_rqbit, do: [find_executable: fn "rqbit" -> nil end]

  defp remembered, do: [file_exists?: &(&1 == "/config/rqbit/enabled")]

  describe "from_runtime/4 auto-enable" do
    test "is on for a new install, one with no other download client" do
      assert %Config{enabled?: true, explicit: nil} = load([], [])
    end

    test "is off for an existing install with a client of any kind" do
      for type <-
            [:qbittorrent, :transmission, :rqbit, :rtorrent, :debrid, :blackhole] ++
              [:sabnzbd, :nzbget] do
        assert %Config{enabled?: false} = load([], [type]), inspect(type)
      end
    end

    test "stays on once recorded, whatever clients are added later" do
      assert %Config{enabled?: true} = load([], [:qbittorrent, :sabnzbd], remembered())
      assert %Config{enabled?: true} = load([], :unknown, remembered())
      assert %Config{enabled?: true} = load([], [:qbittorrent], remembered() ++ no_rqbit())
    end

    test "the record is looked for under the section's state_path" do
      opts = [file_exists?: &(&1 == "/state/enabled")]
      assert %Config{enabled?: true} = load([state_path: "/state"], [:x], opts)
      assert %Config{enabled?: false} = load([], [:x], opts)
      assert Config.marker_path(%Config{state_dir: "/state"}) == "/state/enabled"
    end

    test "enabled: false turns a recorded install off" do
      assert %Config{enabled?: false, explicit: false} =
               load([enabled: false], [], remembered())
    end

    test "is off when rqbit is not installed" do
      assert %Config{enabled?: false, rqbit_missing?: true} = load([], [], no_rqbit())
    end

    test "names a missing rqbit only when it is what keeps a new install off" do
      assert %Config{rqbit_missing?: false} = load([], [])
      assert %Config{rqbit_missing?: false} = load([], [:qbittorrent], no_rqbit())
      assert %Config{rqbit_missing?: false} = load([], :unknown, no_rqbit())
      assert %Config{rqbit_missing?: false} = load([enabled: false], [], no_rqbit())
      assert %Config{rqbit_missing?: false} = load([], [], remembered() ++ no_rqbit())
    end

    test "an explicit true turns it on even without rqbit on the PATH" do
      assert %Config{enabled?: true, explicit: true} = load([enabled: true], [], no_rqbit())
    end

    test "stays off when the configured clients could not be read" do
      assert %Config{enabled?: false} = load([], :unknown)
      assert %Config{enabled?: true} = load([enabled: true], :unknown)
    end

    test "enabled forces either way" do
      assert %Config{enabled?: true} = load([enabled: true], [:qbittorrent])
      assert %Config{enabled?: false} = load([enabled: false], [])
    end

    test "an unrecognised MYDIA_TORRENT_ENABLED warns" do
      config = load([], [], env: %{"MYDIA_TORRENT_ENABLED" => "maybe"})
      assert config.enabled?
      assert {:invalid_enabled, "maybe"} in config.warnings

      assert %Config{enabled?: false} =
               load([], [:rtorrent], env: %{"MYDIA_TORRENT_ENABLED" => "maybe"})
    end

    test "recognised or blank MYDIA_TORRENT_ENABLED spellings do not warn" do
      for value <- ~w(true TRUE 1 yes On false off 0) ++ ["", " "] do
        assert %Config{warnings: []} = load([], [], env: %{"MYDIA_TORRENT_ENABLED" => value}),
               value
      end
    end
  end

  # Clients are looked up by name, so the built-in client never runs beside
  # another client that has its name.
  describe "from_runtime/4 reserved name" do
    test "a recorded install is kept off, with a warning, when the name is taken" do
      config = load([], [:sabnzbd], [{:name_taken, true} | remembered()])
      refute config.enabled?
      assert {:reserved_name_taken} in config.warnings
    end

    test "an explicit true is kept off too" do
      config = load([enabled: true], [:sabnzbd], name_taken: true)
      refute config.enabled?
      assert {:reserved_name_taken} in config.warnings
    end

    test "no warning when it was off anyway" do
      assert %Config{enabled?: false, warnings: []} = load([], [:qbittorrent], name_taken: true)
      assert %Config{warnings: []} = load([], [], [{:name_taken, true} | no_rqbit()])
      assert %Config{warnings: []} = load([], :unknown, name_taken: true)
      assert %Config{warnings: []} = load([enabled: false], [], name_taken: true)
    end

    test "a free name changes nothing" do
      assert %Config{enabled?: true, warnings: []} = load([], [], name_taken: false)
    end
  end

  describe "from_runtime/4 values" do
    test "defaults" do
      config = load([], [])
      assert config.download_path == "/data/downloads"
      assert config.state_dir == "/config/rqbit"
      assert config.port == 51413
      assert config.api_port == 3030
      assert config.vpn? == false
      assert config.vpn_provider == nil
      assert config.vpn_type == nil
      assert config.vpn_interface == "tun0"
      assert config.gluetun_dir == "/config/gluetun"
      assert config.env_vpn_names == []
      assert config.warnings == []
    end

    test "reads paths, ports and VPN settings from the section" do
      section = [
        download_path: "/downloads",
        state_path: "/state/rqbit",
        listen_port: 6881,
        api_port: 4036,
        vpn_enabled: true,
        vpn_provider: "protonvpn",
        vpn_type: "openvpn"
      ]

      config = load(section, [])

      assert config.download_path == "/downloads"
      assert config.state_dir == "/state/rqbit"
      assert config.port == 6881
      assert config.api_port == 4036
      assert config.vpn?
      assert config.vpn_provider == "protonvpn"
      assert config.vpn_type == "openvpn"
      assert %BuiltInTorrent{vpn_provider: "protonvpn"} = config.vpn_section
    end

    test "vpn? follows vpn_enabled, not the provider" do
      refute load([vpn_provider: "pia"], []).vpn?
      assert load([vpn_enabled: true], []).vpn?
    end

    test "the VPN interface follows the VPN type unless the env overrides it" do
      assert load([vpn_type: "wireguard"], []).vpn_interface == "wg0"
      assert load([vpn_type: "openvpn"], []).vpn_interface == "tun0"
      assert load([vpn_type: nil], []).vpn_interface == "tun0"

      env = %{"MYDIA_VPN_VPN_INTERFACE" => "tun5"}
      assert load([vpn_type: "wireguard"], [], env: env).vpn_interface == "tun5"
      assert load([vpn_type: "openvpn"], [], env: env).vpn_interface == "tun5"
      assert load([], [], env: %{"MYDIA_VPN_VPN_INTERFACE" => " "}).vpn_interface == "tun0"
    end

    test "env_vpn_names lists MYDIA_VPN_* variables the section does not cover" do
      env = %{
        "MYDIA_VPN_SERVER_NAMES" => "x",
        "MYDIA_VPN_OPENVPN_USER" => "u",
        "MYDIA_VPN_BLANK_ONE" => " "
      }

      assert load([], [], env: env).env_vpn_names == ["MYDIA_VPN_SERVER_NAMES"]

      env = %{"MYDIA_VPN_B" => "1", "MYDIA_VPN_A" => "1", "MYDIA_TORRENT_PORT" => "1"}
      assert load([], [], env: env).env_vpn_names == ["MYDIA_VPN_A", "MYDIA_VPN_B"]
    end

    test "a bad port in the environment warns" do
      config =
        load([], [], env: %{"MYDIA_TORRENT_PORT" => "nope", "MYDIA_TORRENT_API_PORT" => "70000"})

      assert {:invalid_port, "nope"} in config.warnings
      assert {:invalid_api_port, "70000"} in config.warnings
      assert %Config{warnings: []} = load([], [], env: %{"MYDIA_TORRENT_PORT" => "6881"})
      assert %Config{warnings: []} = load([], [], env: %{"MYDIA_TORRENT_PORT" => " "})
    end

    test "reserved gluetun variables are reported" do
      env = %{
        "MYDIA_VPN_SPLIT_TUNNEL_GID" => "5",
        "MYDIA_VPN_DNS_SERVER" => "off",
        "MYDIA_VPN_HTTP_CONTROL_SERVER_AUTH_CONFIG_FILEPATH" => "/x"
      }

      config = load([], [], env: env)
      assert {:reserved_variable, "SPLIT_TUNNEL_GID"} in config.warnings
      assert {:reserved_variable, "DNS_SERVER"} in config.warnings
      assert {:reserved_variable, "HTTP_CONTROL_SERVER_AUTH_CONFIG_FILEPATH"} in config.warnings
    end
  end

  describe "restart_key/1" do
    test "ignores warnings and nothing else" do
      a = load([], [], env: %{"MYDIA_TORRENT_PORT" => "nope"})
      b = load([], [])
      refute a.warnings == b.warnings
      assert Config.restart_key(a) == Config.restart_key(b)
      refute Map.has_key?(Config.restart_key(a), :warnings)

      refute Config.restart_key(load([listen_port: 1], [])) == Config.restart_key(b)

      vpn_on = load([vpn_enabled: true, vpn_provider: "mullvad"], [])

      refute Config.restart_key(load([vpn_enabled: true, vpn_provider: "pia"], [])) ==
               Config.restart_key(vpn_on)
    end

    test "with the VPN off, VPN fields do not count" do
      off = load([], [])

      for fields <- [
            [vpn_provider: "pia"],
            [vpn_type: "wireguard"],
            [vpn_openvpn_user: "u", vpn_openvpn_password: "p"],
            [vpn_server_countries: "Atlantis", vpn_port_forwarding: true]
          ] do
        assert Config.restart_key(load(fields, [])) == Config.restart_key(off), inspect(fields)
      end

      assert Config.restart_key(load([], [], env: %{"MYDIA_VPN_FOO" => "x"})) ==
               Config.restart_key(off)

      refute Config.restart_key(load([vpn_enabled: true], [])) == Config.restart_key(off)

      refute Config.restart_key(load([download_path: "/elsewhere"], [])) ==
               Config.restart_key(off)
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
