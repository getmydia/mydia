defmodule Mydia.Config.PluginInstancesConfigTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mydia.Config.Loader

  @yaml_path "test/fixtures/plugin_instances_config.yml"
  @prefixes ["PLUGIN_", "MEDIA_SERVER_"]

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Mydia.Repo, shared: true)

    saved =
      System.get_env()
      |> Enum.filter(fn {key, _} -> String.starts_with?(key, @prefixes) end)

    Enum.each(saved, fn {key, _} -> System.delete_env(key) end)
    File.rm(@yaml_path)
    # The legacy-Plex deprecation is logged once per boot; each test starts a new one.
    :persistent_term.erase({Loader, :legacy_plex_warned})

    on_exit(fn ->
      System.get_env()
      |> Enum.filter(fn {key, _} -> String.starts_with?(key, @prefixes) end)
      |> Enum.each(fn {key, _} -> System.delete_env(key) end)

      Enum.each(saved, fn {key, value} -> System.put_env(key, value) end)
      File.rm(@yaml_path)
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)

    :ok
  end

  defp load_env, do: Loader.load(config_file: "nonexistent.yml", sources: [:env])

  test "PLUGIN_<SLUG>_<N>_<KEY> declares instances with lower-cased settings keys" do
    System.put_env("PLUGIN_PLEX_0_NAME", "Living room")
    System.put_env("PLUGIN_PLEX_0_URL", "http://192.168.1.20:32400")
    System.put_env("PLUGIN_PLEX_0_TOKEN", "abc")
    System.put_env("PLUGIN_SIMKL_SYNC_1_CLIENT_ID", "cid")
    System.put_env("PLUGIN_SIMKL_SYNC_1_ENABLED", "false")

    assert {:ok, config} = load_env()

    by_plugin = Map.new(config.plugin_instances, &{&1.plugin, &1})

    assert %{name: "Living room", enabled: true, settings: settings} = by_plugin["plex"]
    assert settings == %{"url" => "http://192.168.1.20:32400", "token" => "abc"}

    assert %{name: "simkl_sync-1", enabled: false, settings: %{"client_id" => "cid"}} =
             by_plugin["simkl_sync"]
  end

  test "numeric PLUGIN_<N>_* installs are not read as instances and vice versa" do
    System.put_env("PLUGIN_0_SLUG", "webhook_notifier")
    System.put_env("PLUGIN_PLEX_0_URL", "http://10.0.0.2:32400")

    assert {:ok, config} = load_env()

    assert [%{slug: "webhook_notifier"}] = config.plugin_installs
    assert [%{plugin: "plex"}] = config.plugin_instances
  end

  test "YAML plugin_instances are read" do
    File.write!(@yaml_path, """
    plugin_instances:
      - plugin: plex
        name: Attic
        settings:
          url: http://10.0.0.3:32400
    """)

    assert {:ok, config} = Loader.load(config_file: @yaml_path, sources: [:yaml])

    assert [
             %{
               plugin: "plex",
               name: "Attic",
               enabled: true,
               settings: %{"url" => "http://10.0.0.3:32400"}
             }
           ] = config.plugin_instances
  end

  test "MEDIA_SERVER_* with TYPE=plex becomes a plex instance and warns" do
    System.put_env("MEDIA_SERVER_0_NAME", "Old Plex")
    System.put_env("MEDIA_SERVER_0_TYPE", "plex")
    System.put_env("MEDIA_SERVER_0_URL", "http://10.0.0.4:32400")
    System.put_env("MEDIA_SERVER_0_TOKEN", "legacy")
    System.put_env("MEDIA_SERVER_1_NAME", "Jelly")
    System.put_env("MEDIA_SERVER_1_TYPE", "jellyfin")
    System.put_env("MEDIA_SERVER_1_URL", "http://10.0.0.5:8096")
    System.put_env("MEDIA_SERVER_1_TOKEN", "jf")

    log =
      capture_log(fn ->
        assert {:ok, config} = load_env()
        send(self(), {:config, config})
      end)

    assert_received {:config, config}

    assert [%{name: "Jelly", type: :jellyfin}] = config.media_servers

    assert [
             %{
               plugin: "plex",
               name: "Old Plex",
               legacy_source: "media_servers",
               settings: %{"url" => "http://10.0.0.4:32400", "token" => "legacy"}
             }
           ] = config.plugin_instances

    assert log =~ "PLUGIN_PLEX_<N>_URL"
    assert log =~ "Old Plex"
  end

  test "the legacy Plex deprecation is logged once per boot, not on every load" do
    System.put_env("MEDIA_SERVER_0_NAME", "Old Plex")
    System.put_env("MEDIA_SERVER_0_TYPE", "plex")
    System.put_env("MEDIA_SERVER_0_URL", "http://10.0.0.4:32400")

    first = capture_log(fn -> assert {:ok, _} = load_env() end)

    second =
      capture_log(fn ->
        assert {:ok, config} = load_env()
        send(self(), {:c, config})
      end)

    assert first =~ "PLUGIN_PLEX_<N>_URL"
    refute second =~ "PLUGIN_PLEX_<N>_URL"
    # The translation itself still happens on every load.
    assert_received {:c, %{plugin_instances: [%{name: "Old Plex"}]}}
  end

  test "an invalid plugin slug fails validation" do
    File.write!(@yaml_path, """
    plugin_instances:
      - plugin: "Bad Slug"
        name: X
    """)

    assert {:error, %Ecto.Changeset{}} = Loader.load(config_file: @yaml_path, sources: [:yaml])
  end
end
