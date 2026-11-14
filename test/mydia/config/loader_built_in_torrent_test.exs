defmodule Mydia.Config.LoaderBuiltInTorrentTest do
  # async: false because Loader.reload/1 mutates the global :runtime_config env.
  use ExUnit.Case, async: false

  alias Mydia.Config.Env.BuiltInTorrentEnv
  alias Mydia.Config.Loader

  defp env(map), do: fn name -> Map.get(map, name) end

  test "port parses" do
    assert BuiltInTorrentEnv.load(env(%{"MYDIA_TORRENT_PORT" => "6881"})).listen_port == 6881
  end

  test "bad port is left out" do
    refute Map.has_key?(
             BuiltInTorrentEnv.load(env(%{"MYDIA_TORRENT_PORT" => "abc"})),
             :listen_port
           )
  end

  test "out-of-range ports are left out so validation cannot fail at boot" do
    for bad <- ["0", "70000", "-1", "65536"],
        {var, key} <- [
          {"MYDIA_TORRENT_PORT", :listen_port},
          {"MYDIA_TORRENT_API_PORT", :api_port}
        ] do
      refute Map.has_key?(BuiltInTorrentEnv.load(env(%{var => bad})), key)
    end

    assert BuiltInTorrentEnv.load(env(%{"MYDIA_TORRENT_API_PORT" => "65535"})).api_port == 65535

    section = BuiltInTorrentEnv.load(env(%{"MYDIA_TORRENT_PORT" => "70000"}))

    assert Mydia.Config.Schema.BuiltInTorrent.changeset(
             %Mydia.Config.Schema.BuiltInTorrent{},
             section
           ).valid?
  end

  test "rate limits parse in KiB/s, and bad or out-of-range ones are left out" do
    loaded =
      BuiltInTorrentEnv.load(
        env(%{"MYDIA_TORRENT_DOWNLOAD_LIMIT" => "2048", "MYDIA_TORRENT_UPLOAD_LIMIT" => " 512 "})
      )

    assert loaded.download_limit_kib == 2048
    assert loaded.upload_limit_kib == 512

    for bad <- ["0", "-5", "abc", "4194304", "1.5"],
        {var, key} <- [
          {"MYDIA_TORRENT_DOWNLOAD_LIMIT", :download_limit_kib},
          {"MYDIA_TORRENT_UPLOAD_LIMIT", :upload_limit_kib}
        ] do
      refute Map.has_key?(BuiltInTorrentEnv.load(env(%{var => bad})), key)
    end

    assert BuiltInTorrentEnv.load(env(%{"MYDIA_TORRENT_UPLOAD_LIMIT" => "4194303"})).upload_limit_kib ==
             4_194_303
  end

  test "enabled accepts off and ignores junk" do
    assert BuiltInTorrentEnv.load(env(%{"MYDIA_TORRENT_ENABLED" => " OFF "})).enabled ==
             false

    assert BuiltInTorrentEnv.load(env(%{"MYDIA_TORRENT_ENABLED" => "yes"})).enabled == true

    refute Map.has_key?(
             BuiltInTorrentEnv.load(env(%{"MYDIA_TORRENT_ENABLED" => "maybe"})),
             :enabled
           )
  end

  test "provider implies vpn_enabled, blank does not" do
    r = BuiltInTorrentEnv.load(env(%{"MYDIA_VPN_SERVICE_PROVIDER" => " ProtonVPN "}))
    assert r.vpn_enabled == true
    assert r.vpn_provider == "protonvpn"

    assert BuiltInTorrentEnv.load(env(%{"MYDIA_VPN_SERVICE_PROVIDER" => "  "})) == %{}
  end

  test "port forwarding accepts on" do
    r = BuiltInTorrentEnv.load(env(%{"MYDIA_VPN_VPN_PORT_FORWARDING" => "on"}))
    assert r.vpn_port_forwarding == true
  end

  describe "reload/1" do
    setup do
      previous = Application.fetch_env(:mydia, :runtime_config)

      on_exit(fn ->
        case previous do
          {:ok, v} -> Application.put_env(:mydia, :runtime_config, v)
          :error -> Application.delete_env(:mydia, :runtime_config)
        end
      end)
    end

    test "broadcasts the new config" do
      assert Mydia.Config.Broadcast.topic() == "config:runtime"
      Phoenix.PubSub.subscribe(Mydia.PubSub, Mydia.Config.Broadcast.topic())
      assert {:ok, _} = Loader.reload(sources: [:yaml, :env])
      assert_receive {:runtime_config_reloaded, %Mydia.Config.Schema{}}
    end

    test "skips the broadcast when the PubSub is not running (boot)" do
      Phoenix.PubSub.subscribe(Mydia.PubSub, Mydia.Config.Broadcast.topic())
      assert {:ok, _} = Loader.reload(sources: [:yaml, :env], pubsub: :not_running_pubsub)
      refute_receive {:runtime_config_reloaded, _}, 50
    end
  end
end
