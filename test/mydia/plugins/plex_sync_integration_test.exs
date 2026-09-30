defmodule Mydia.Plugins.PlexSyncIntegrationTest do
  use Mydia.PlexPluginCase

  describe "first tick" do
    test "crawls, pulls a remote movie and episode watch, and records a run",
         %{server: server, instance: instance} do
      user = user_fixture()
      link_user!(instance, user, "user-token")
      movie = movie!("The Glass Orchard")
      {_show, episode} = show_with_episode!(378_101, 1, 2)
      stub_sections(server)
      test_pid = self()

      FakePlexServer.stub(server, "GET", "/library/sections/1/all", fn conn ->
        send(test_pid, {:movies, token(conn)})

        json(conn, 200, %{
          "MediaContainer" => %{
            "Metadata" => [
              movie_json("100", movie.tmdb_id, %{
                "viewCount" => 1,
                "lastViewedAt" => 1_767_225_000
              })
            ]
          }
        })
      end)

      FakePlexServer.stub(server, "GET", "/library/sections/2/all", fn conn ->
        items =
          case query(conn)["type"] do
            # Pull pass: episodes, flat.
            "4" ->
              [
                %{
                  "ratingKey" => "201",
                  "type" => "episode",
                  "parentIndex" => 1,
                  "index" => 2,
                  "viewCount" => 1,
                  "lastViewedAt" => 1_767_225_100
                }
              ]

            # Crawl: shows.
            _ ->
              [%{"ratingKey" => "20", "type" => "show", "Guid" => [%{"id" => "tvdb://378101"}]}]
          end

        json(conn, 200, %{"MediaContainer" => %{"Metadata" => items}})
      end)

      FakePlexServer.stub(server, "GET", "/library/metadata/20/allLeaves", fn conn ->
        json(conn, 200, %{
          "MediaContainer" => %{
            "Metadata" => [
              %{"ratingKey" => "201", "type" => "episode", "parentIndex" => 1, "index" => 2}
            ]
          }
        })
      end)

      assert {:ok, %{"complete" => true, "pulled" => 2}} =
               Plugins.invoke_plugin_schedule("plex", instance.id)

      assert Playback.get_progress(user.id, media_item_id: movie.id).watched
      assert Playback.get_progress(user.id, episode_id: episode.id).watched

      # The crawl ran on the instance credential, the pull on the profile's own.
      assert_received {:movies, "owner-token"}
      assert_received {:movies, "user-token"}

      # The guest's own report-sync-run, written through the wasm boundary.
      assert %{status: :ok} = run = Mydia.Sync.last_run("plugin:plex", instance.id)
      assert run.provider_instance_id == instance.id
    end

    test "pages a section larger than one page", %{server: server, instance: instance} do
      user = user_fixture()
      link_user!(instance, user, "user-token")
      stub_sections(server)
      stub_empty_shows(server)
      test_pid = self()

      FakePlexServer.stub(server, "GET", "/library/sections/1/all", fn conn ->
        start = container_start(conn)
        send(test_pid, {:page, token(conn), start})
        # 201 movies: a full page of 200, then one.
        count = if start == 0, do: 200, else: 1
        items = for i <- 1..count, do: movie_json("#{start + i}", 900_000 + start + i)
        json(conn, 200, %{"MediaContainer" => %{"Metadata" => items}})
      end)

      assert {:ok, %{"complete" => true}} = Plugins.invoke_plugin_schedule("plex", instance.id)
      assert_received {:page, "owner-token", 0}
      assert_received {:page, "owner-token", 200}
      assert {:ok, entry} = Kv.get(instance.id, "map/201")
      assert is_binary(entry)
    end
  end

  describe "push" do
    test "a newer local position is pushed in milliseconds on the profile's token",
         %{server: server, instance: instance} do
      user = user_fixture()
      link_user!(instance, user, "user-token")
      movie = movie!("Lanterns of Vell")
      stub_sections(server)
      stub_empty_shows(server)
      test_pid = self()

      {:ok, _} =
        Playback.save_progress(user.id, [media_item_id: movie.id], %{
          position_seconds: 95,
          duration_seconds: 6000
        })

      FakePlexServer.stub(server, "GET", "/library/sections/1/all", fn conn ->
        # The crawl sees the movie untouched on Plex; so does the first pull.
        json(conn, 200, %{"MediaContainer" => %{"Metadata" => [movie_json("100", movie.tmdb_id)]}})
      end)

      FakePlexServer.stub(server, "GET", "/:/progress", fn conn ->
        send(test_pid, {:progress, token(conn), query(conn)})
        Plug.Conn.resp(conn, 200, "")
      end)

      assert {:ok, _} = Plugins.invoke_plugin_schedule("plex", instance.id)

      assert_received {:progress, "user-token", params}
      assert %{"key" => "100", "time" => "95000", "state" => "stopped"} = params
      refute_received {:progress, _, _}
    end

    test "a row this instance wrote is not pushed back, one written by the player is",
         %{server: server, instance: instance} do
      user = user_fixture()
      link = link_user!(instance, user, "user-token")
      echoed = movie!("Lanterns of Vell")
      played = movie!("Salt and Signal")
      stub_sections(server)
      stub_empty_shows(server)
      test_pid = self()

      # data-list rows carry `origin`: the host stamps this instance's own
      # write-backs, and the guest must not echo them to Plex again.
      {:ok, _} =
        Playback.save_progress(
          user.id,
          [media_item_id: echoed.id],
          %{position_seconds: 95, duration_seconds: 6000},
          origin: "plugin:plex:#{instance.id}"
        )

      {:ok, _} =
        Playback.save_progress(user.id, [media_item_id: played.id], %{
          position_seconds: 120,
          duration_seconds: 6000
        })

      # An incremental tick: Plex lists nothing changed, so only the push pass
      # over local rows can send these two.
      now = seed_crawled_movie!(instance, echoed, "100")
      seed_crawled_movie!(instance, played, "200")
      {:ok, _} = Kv.set(instance.id, "link/#{link.id}/cursor/pull", Integer.to_string(now - 3600))

      FakePlexServer.stub(server, "GET", "/library/sections/1/all", fn conn ->
        json(conn, 200, %{"MediaContainer" => %{}})
      end)

      for {rk, movie} <- [{"100", echoed}, {"200", played}] do
        FakePlexServer.stub(server, "GET", "/library/metadata/#{rk}", fn conn ->
          json(conn, 200, %{"MediaContainer" => %{"Metadata" => [movie_json(rk, movie.tmdb_id)]}})
        end)
      end

      FakePlexServer.stub(server, "GET", "/:/progress", fn conn ->
        send(test_pid, {:progress, query(conn)["key"]})
        Plug.Conn.resp(conn, 200, "")
      end)

      assert {:ok, _} = Plugins.invoke_plugin_schedule("plex", instance.id)

      assert_received {:progress, "200"}
      refute_received {:progress, "100"}
    end

    test "a 401 on one profile marks only that link as errored",
         %{server: server, instance: instance} do
      good = user_fixture()
      bad = user_fixture()
      [good_link, bad_link] = link_users!(instance, [{good, "good-token"}, {bad, "bad-token"}])
      stub_empty_shows(server)

      FakePlexServer.stub(server, "GET", "/library/sections", fn conn ->
        if token(conn) == "bad-token" do
          Plug.Conn.resp(conn, 401, "")
        else
          json(conn, 200, %{
            "MediaContainer" => %{"Directory" => [%{"key" => "1", "type" => "movie"}]}
          })
        end
      end)

      FakePlexServer.stub(server, "GET", "/library/sections/1/all", fn conn ->
        json(conn, 200, %{"MediaContainer" => %{}})
      end)

      assert {:ok, _} = Plugins.invoke_plugin_schedule("plex", instance.id)

      assert %{status: :error} = AccountLinks.get(bad_link.id)
      assert %{status: :active} = AccountLinks.get(good_link.id)
      assert {:ok, cursor} = Kv.get(instance.id, "link/#{good_link.id}/cursor/pull")
      assert is_binary(cursor)
    end
  end

  describe "mapping staleness" do
    test "a fresh crawl is not repeated, a day-old one is", %{server: server, instance: instance} do
      user = user_fixture()
      link_user!(instance, user, "user-token")
      stub_sections(server)
      stub_empty_shows(server)
      test_pid = self()

      FakePlexServer.stub(server, "GET", "/library/sections/1/all", fn conn ->
        send(test_pid, {:section_read, token(conn)})
        json(conn, 200, %{"MediaContainer" => %{}})
      end)

      now = System.system_time(:second)

      put_crawl = fn completed ->
        {:ok, _} =
          Kv.set(
            instance.id,
            "crawl/state",
            Jason.encode!(%{
              section_keys: ["movie:1", "show:2"],
              section_index: 2,
              offset: 0,
              started_at: completed - 60,
              completed_at: completed,
              last_completed_at: completed
            })
          )
      end

      put_crawl.(now - 60)
      assert {:ok, _} = Plugins.invoke_plugin_schedule("plex", instance.id)
      refute_received {:section_read, "owner-token"}

      put_crawl.(now - 86_401)
      assert {:ok, _} = Plugins.invoke_plugin_schedule("plex", instance.id)
      assert_received {:section_read, "owner-token"}
    end
  end

  describe "first tick after migration" do
    test "with migrated state it is incremental and pushes a pending unwatch",
         %{server: server, instance: instance} do
      user = user_fixture()
      link = link_user!(instance, user, "user-token")
      movie = movie!("The Quiet Meridian")
      stub_sections(server)
      stub_empty_shows(server)
      test_pid = self()
      now = seed_crawled_movie!(instance, movie, "100")

      # What Task 18 writes for a DB-configured server: a pull cursor, and a
      # snapshot saying the movie was watched. The local row is gone: the user
      # unwatched it in Mydia after the last native sync.
      {:ok, _} = Kv.set(instance.id, "link/#{link.id}/cursor/pull", Integer.to_string(now - 3600))

      {:ok, _} =
        Kv.set(
          instance.id,
          "link/#{link.id}/state/100",
          Jason.encode!(%{
            watched: true,
            position: nil,
            synced_at: "2026-01-01T00:00:00Z",
            remote_last_watched_at: "2026-01-01T00:00:00Z"
          })
        )

      FakePlexServer.stub(server, "GET", "/library/sections/1/all", fn conn ->
        send(test_pid, {:pull_since, query(conn)["lastViewedAt>"]})
        json(conn, 200, %{"MediaContainer" => %{}})
      end)

      FakePlexServer.stub(server, "GET", "/:/unscrobble", fn conn ->
        send(test_pid, {:unscrobble, token(conn), query(conn)["key"]})
        Plug.Conn.resp(conn, 200, "")
      end)

      assert {:ok, _} = Plugins.invoke_plugin_schedule("plex", instance.id)

      # Incremental: the cursor minus the 15 minute overlap, not a full listing.
      assert_received {:pull_since, since}
      assert String.to_integer(since) == now - 3600 - 900
      assert_received {:unscrobble, "user-token", "100"}
      refute_received {:unscrobble, _, _}
    end

    test "without migrated state (an env-declared server) it is a safe baseline",
         %{server: server, instance: instance} do
      # The contrasting case: env-declared native servers had no DB row, so
      # nothing was migrated. The first tick sees every item with no snapshot and
      # must never unwatch anything on either side.
      user = user_fixture()
      link_user!(instance, user, "user-token")
      watched_here = movie!("The Quiet Meridian")
      watched_there = movie!("Salt and Signal")
      stub_sections(server)
      stub_empty_shows(server)
      test_pid = self()

      {:ok, _} =
        Playback.save_progress(user.id, [media_item_id: watched_here.id], %{
          position_seconds: 6000,
          duration_seconds: 6000,
          watched: true
        })

      FakePlexServer.stub(server, "GET", "/library/sections/1/all", fn conn ->
        json(conn, 200, %{
          "MediaContainer" => %{
            "Metadata" => [
              movie_json("100", watched_here.tmdb_id, %{"viewCount" => 0}),
              movie_json("200", watched_there.tmdb_id, %{
                "viewCount" => 1,
                "lastViewedAt" => 1_767_225_000
              })
            ]
          }
        })
      end)

      FakePlexServer.stub(server, "GET", "/:/scrobble", fn conn ->
        send(test_pid, {:scrobble, query(conn)["key"]})
        Plug.Conn.resp(conn, 200, "")
      end)

      FakePlexServer.stub(server, "GET", "/:/progress", fn conn ->
        Plug.Conn.resp(conn, 200, "")
      end)

      FakePlexServer.stub(server, "GET", "/:/unscrobble", fn conn ->
        send(test_pid, :unscrobbled)
        Plug.Conn.resp(conn, 200, "")
      end)

      assert {:ok, _} = Plugins.invoke_plugin_schedule("plex", instance.id)

      assert_received {:scrobble, "100"}
      assert Playback.get_progress(user.id, media_item_id: watched_here.id).watched
      assert Playback.get_progress(user.id, media_item_id: watched_there.id).watched
      refute_received :unscrobbled
    end
  end

  describe "events" do
    test "media_file.imported refreshes the server's libraries", %{
      server: server,
      instance: instance
    } do
      test_pid = self()

      FakePlexServer.stub(server, "GET", "/library/sections/all/refresh", fn conn ->
        send(test_pid, {:refresh, token(conn)})
        Plug.Conn.resp(conn, 200, "")
      end)

      {:ok, plugin} = Plugins.get_plugin("plex")

      assert {:ok, %{"delivered" => true}} =
               Plugins.invoke_plugin(plugin, instance, %{
                 type: "media_file.imported",
                 category: "media",
                 metadata: %{"file_path" => "The Glass Orchard (2024).mkv"}
               })

      assert_received {:refresh, "owner-token"}
      refute_received {:refresh, _}
    end
  end
end
