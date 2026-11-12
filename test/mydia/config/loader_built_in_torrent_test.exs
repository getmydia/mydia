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
