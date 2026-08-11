defmodule Mydia.Plugins.HostFunctionsWatchStateTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures

  alias Mydia.Playback
  alias Mydia.Plugins.Connections
  alias Mydia.Plugins.HostFunctions
  alias Mydia.Plugins.Plugin

  # There is no plugin fixture in this codebase; host function tests build the
  # struct inline. Mirror `test/mydia/plugins/host_functions_test.exs:13`.
  defp plugin(granted) do
    %Plugin{slug: "tester", name: "Tester", granted_capabilities: granted, enabled: true}
  end

  setup do
    user = user_fixture()
    movie = media_item_fixture(%{tmdb_id: "12345"})

    plugin = plugin(%{"surfaces:write" => ["playback:watched"]})

    # Connections.connect/3 resolves the owning config from the slug and fails
    # with :not_installed otherwise, so the config must exist first.
    {:ok, _config} =
      Mydia.Settings.create_plugin_config(%{
        slug: "tester",
        name: "Tester",
        version: "1.0.0",
        source_url: "test",
        manifest: %{
          "slug" => "tester",
          "name" => "Tester",
          "version" => "1.0.0",
          "capabilities" => %{"surfaces:write" => ["playback:watched"]}
        },
        granted_capabilities: %{"surfaces:write" => ["playback:watched"]},
        enabled: true
      })

    # Cross-user writes are consent-scoped (R21): only a user with an active
    # connection is writable by the plugin, so the connection is required.
    # access_token is required by the connection changeset; status alone is not enough.
    {:ok, _conn} =
      Connections.connect("tester", user.id, %{status: "connected", access_token: "t"})

    {:ok, user: user, movie: movie, plugin: plugin}
  end

  test "set_watch_state can unwatch, which ensure_watched cannot",
       %{user: user, movie: movie, plugin: plugin} do
    {:ok, _} =
      Playback.save_progress(user.id, [media_item_id: movie.id], %{
        position_seconds: 100,
        duration_seconds: 100
      })

    assert {:ok, _} =
             HostFunctions.set_watch_state(plugin, %{
               "user-id": user.id,
               "tmdb-id": 12_345,
               watched: false
             })

    assert Playback.get_progress(user.id, media_item_id: movie.id) == nil
  end

  test "set_watch_state carries a position", %{user: user, movie: movie, plugin: plugin} do
    assert {:ok, _} =
             HostFunctions.set_watch_state(plugin, %{
               "user-id": user.id,
               "tmdb-id": 12_345,
               watched: false,
               "position-seconds": 300,
               "duration-seconds": 1000
             })

    progress = Playback.get_progress(user.id, media_item_id: movie.id)
    assert progress.position_seconds == 300
  end
end
