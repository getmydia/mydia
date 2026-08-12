defmodule Mydia.Plugins.SimklSyncIntegrationTest do
  # async: false — starts a real pool under the app-wide PoolRegistry and seeds
  # rows the connected invocation reads (Postgres sandbox rule).
  use Mydia.DataCase, async: false

  import Ecto.Query
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Collections
  alias Mydia.Media
  alias Mydia.Playback
  alias Mydia.Plugins
  alias Mydia.Plugins.Connections
  alias Mydia.Plugins.Host
  alias Mydia.Plugins.HostFunctions
  alias Mydia.Plugins.Kv
  alias Mydia.Plugins.Plugin
  alias Mydia.Plugins.Registry
  alias Mydia.Settings

  @slug "simkl_sync"

  # The bundled guest, built by the :plugins compiler into priv/plugins/ (nix
  # toolchain). Read from the app dir like the webhook notifier integration test.
  defp guest_wasm, do: File.read!(Application.app_dir(:mydia, "priv/plugins/simkl_sync.wasm"))

  @grants %{
    "net:http" => ["127.0.0.1"],
    "state:kv" => [],
    "data:read" => ["playback_progress", "library_item"],
    "surfaces:write" => ["playback:watched", "collections:favorite"],
    "users:connections" => [],
    "schedule:interval" => []
  }

  setup do
    # Plugin lifecycle replaces the global :runtime_config; restore it.
    original = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original,
        do: Application.put_env(:mydia, :runtime_config, original),
        else: Application.delete_env(:mydia, :runtime_config)
    end)

    bypass = Bypass.open()
    api_base = "http://127.0.0.1:#{bypass.port}"

    {:ok, _} =
      Settings.create_plugin_config(%{
        slug: @slug,
        name: "Simkl Sync",
        version: "1.0.0",
        source_url: "test",
        manifest: %{
          "slug" => @slug,
          "name" => "Simkl Sync",
          "version" => "1.0.0",
          "capabilities" => %{"events:subscribe" => ["playback.finished"]}
        },
        settings: %{"api_base" => api_base},
        granted_capabilities: @grants,
        enabled: true
      })

    {:ok, _} =
      Registry.register(@slug, %Plugin{
        slug: @slug,
        name: "Simkl Sync",
        granted_capabilities: @grants,
        enabled: true
      })

    on_exit(fn -> Registry.unregister(@slug) end)

    bytes = guest_wasm()

    imports =
      HostFunctions.imports_for(@slug,
        allow_private: true,
        resolver: fn _ -> {:ok, [{127, 0, 0, 1}]} end
      )

    {:ok, _pid} = Host.start_plugin(@slug, bytes, imports: imports)
    on_exit(fn -> Host.stop_plugin(@slug) end)

    user = user_fixture()
    {:ok, _} = Connections.connect(@slug, user.id, %{access_token: "simkl-token"})

    %{bypass: bypass, user: user}
  end

  defp movie!(imdb) do
    {:ok, item} =
      Media.create_media_item(%{
        title: "Movie #{imdb}",
        type: "movie",
        year: 2024,
        imdb_id: imdb,
        tmdb_id: System.unique_integer([:positive])
      })

    item
  end

  # A TV show with a single episode, matched by tvdb id + season/episode
  # coordinates — the shape Simkl's shows/anime entries resolve against.
  defp show_with_episode!(tvdb, season, episode) do
    {:ok, show} =
      Media.create_media_item(
        %{
          title: "Show #{tvdb}",
          type: "tv_show",
          year: 2024,
          tvdb_id: tvdb
        },
        skip_episode_refresh: true
      )

    {:ok, ep} =
      Media.create_episode(%{
        media_item_id: show.id,
        season_number: season,
        episode_number: episode,
        title: "S#{season}E#{episode}"
      })

    {show, ep}
  end

  test "pulls Simkl history into mydia and pushes local watches back, with echo guard",
       %{bypass: bypass, user: user} do
    pull_movie = movie!("ttPULL")
    {_show, pull_episode} = show_with_episode!(320_724, 1, 1)
    push_movie = movie!("ttPUSH")

    # A local watch to push.
    {:ok, _} =
      Playback.save_progress(user.id, [media_item_id: push_movie.id], %{
        position_seconds: 95,
        duration_seconds: 100
      })

    test_pid = self()

    Bypass.expect(bypass, "GET", "/sync/activities", fn conn ->
      # Real Simkl shape: a top-level `all` alongside nested per-type objects and
      # a `null` sibling — the cursor read must not choke on those.
      Plug.Conn.resp(conn, 200, ~s({
        "all": "2024-06-01T00:00:00Z",
        "tv_shows": {"all": "2024-05-30T00:00:00Z"},
        "movies": {"all": "2024-05-27T00:00:00Z"},
        "settings": {"all": null}
      }))
    end)

    Bypass.expect(bypass, "GET", "/sync/all-items", fn conn ->
      # The request must carry the episode/extended params, or shows come back as
      # show-level summaries with no per-episode coordinates (regression guard for
      # the pull URL).
      send(test_pid, {:all_items_query, conn.query_string})

      # Real Simkl shape: top-level shows/anime/movies, ids nested under
      # show/movie, string-typed tvdb, per-episode watched_at under seasons[].
      Plug.Conn.resp(conn, 200, ~s({
        "shows": [
          {
            "status": "watching",
            "show": {"title": "Show 320724", "ids": {"tvdb": "320724"}},
            "seasons": [
              {"number": 1, "episodes": [{"number": 1, "watched_at": "2024-05-15T20:06:00Z"}]}
            ]
          }
        ],
        "anime": [],
        "movies": [
          {"status": "completed", "last_watched_at": "2024-05-20T00:00:00Z", "movie": {"ids": {"imdb": "ttPULL"}}}
        ]
      }))
    end)

    Bypass.expect(bypass, "POST", "/sync/history", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:history, body})
      Plug.Conn.resp(conn, 200, ~s({"added":{"movies":1}}))
    end)

    Bypass.stub(bypass, "GET", "/sync/all-items/movies/plantowatch", fn conn ->
      Plug.Conn.resp(conn, 200, "{}")
    end)

    Bypass.stub(bypass, "GET", "/sync/all-items/shows/plantowatch", fn conn ->
      Plug.Conn.resp(conn, 200, "{}")
    end)

    Bypass.stub(bypass, "POST", "/sync/add-to-list", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"added":{"movies":0,"shows":0}}))
    end)

    assert {:ok, result} = Plugins.invoke_plugin_schedule(@slug)
    # Movie + episode both pulled.
    assert result["pulled"] >= 2
    assert result["pushed"] >= 1

    # The pull request asked for episode-level, extended data (KTD2).
    assert_received {:all_items_query, query}
    assert query =~ "episode_watched_at=yes"
    assert query =~ "extended=full"

    # Pull: the Simkl-watched movie AND episode are now watched locally (AE1).
    assert Playback.get_progress(user.id, media_item_id: pull_movie.id).watched == true
    assert Playback.get_progress(user.id, episode_id: pull_episode.id).watched == true

    # R-PULL-3: the activities cursor watermark was persisted for the connection.
    assert cursor_value() == "2024-06-01T00:00:00Z"

    # Push: the local watch reached Simkl, and the just-pulled item was NOT
    # echoed back.
    assert_received {:history, body}
    assert body =~ "ttPUSH"
    refute body =~ "ttPULL"
  end

  # The Simkl guest writes its pull watermark to `conn/<id>/activities`. Read it
  # back from plugin_kv without assuming the connection id.
  defp cursor_value do
    Mydia.Repo.one(
      from k in Kv,
        where: k.plugin_slug == @slug and like(k.key, "conn/%/activities"),
        select: k.value
    )
  end

  test "a pushed library item never comes back as a favorite", %{
    bypass: bypass,
    user: user
  } do
    # Owned and unwatched: enters D, so it gets pushed and must NOT be favorited
    # even though the stubbed Simkl list echoes it straight back.
    owned = movie!("ttOWNED")
    _file = media_file_fixture(%{media_item_id: owned.id})

    # Catalogued but not owned: absent from D, so it SHOULD become a favorite.
    wanted = movie!("ttWANTED")

    Bypass.stub(bypass, "GET", "/sync/activities", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"all":"2026-08-11T00:00:00Z"}))
    end)

    Bypass.stub(bypass, "GET", "/sync/all-items", fn conn ->
      Plug.Conn.resp(conn, 200, "{}")
    end)

    # Simkl reports both items as plan-to-watch.
    Bypass.stub(bypass, "GET", "/sync/all-items/movies/plantowatch", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"movies":[
        {"status":"plantowatch","movie":{"ids":{"imdb":"ttOWNED"}}},
        {"status":"plantowatch","movie":{"ids":{"imdb":"ttWANTED"}}}
      ]}))
    end)

    Bypass.stub(bypass, "GET", "/sync/all-items/shows/plantowatch", fn conn ->
      Plug.Conn.resp(conn, 200, "{}")
    end)

    Bypass.stub(bypass, "POST", "/sync/add-to-list", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"added":{"movies":0,"shows":0}}))
    end)

    assert {:ok, _result} = Plugins.invoke_plugin_schedule(@slug)

    refute Collections.is_favorite?(user, owned.id),
           "an item we pushed must never be favorited back"

    assert Collections.is_favorite?(user, wanted.id),
           "a catalogued-but-unowned plan-to-watch item should become a favorite"
  end

  test "a 401 from Simkl reports the connection as invalid", %{bypass: bypass, user: user} do
    Bypass.expect(bypass, "GET", "/sync/activities", fn conn ->
      Plug.Conn.resp(conn, 401, ~s({"error":"unauthorized"}))
    end)

    assert {:ok, result} = Plugins.invoke_plugin_schedule(@slug)
    assert user.id in result["connections_invalid"]
  end
end
