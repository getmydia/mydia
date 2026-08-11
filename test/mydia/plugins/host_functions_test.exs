defmodule Mydia.Plugins.HostFunctionsTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures

  alias Mydia.Events
  alias Mydia.Plugins.Connections
  alias Mydia.Plugins.Error
  alias Mydia.Plugins.HostFunctions
  alias Mydia.Plugins.Plugin

  defp plugin(granted) do
    %Plugin{slug: "tester", name: "Tester", granted_capabilities: granted, enabled: true}
  end

  defp loopback_resolver, do: fn _ -> {:ok, [{127, 0, 0, 1}]} end

  describe "http_request/3 (net:http grant)" do
    setup do
      {:ok, bypass: Bypass.open()}
    end

    test "R6: a granted host succeeds", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/hook", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"ok":true}))
      end)

      p = plugin(%{"net:http" => ["allowed.test"]})

      assert {:ok, %{"status" => 200, "ok" => true, "body" => body}} =
               HostFunctions.http_request(
                 p,
                 %{"url" => "http://allowed.test:#{bypass.port}/hook", "method" => "POST"},
                 resolver: loopback_resolver(),
                 allow_private: true
               )

      assert body =~ "ok"
    end

    test "AE2: a host not on the grant is denied" do
      p = plugin(%{"net:http" => ["discord.com"]})

      assert {:error, %Error{type: :capability_denied}} =
               HostFunctions.http_request(p, %{"url" => "https://evil.test/"},
                 resolver: loopback_resolver()
               )
    end

    test "a plugin without the net:http grant is denied before any request" do
      p = plugin(%{"events:subscribe" => ["media_item.added"]})

      assert {:error, %Error{type: :capability_denied}} =
               HostFunctions.http_request(p, %{"url" => "https://discord.com/"})
    end

    test "a missing url is rejected" do
      p = plugin(%{"net:http" => ["discord.com"]})
      assert {:error, %Error{type: :invalid_request}} = HostFunctions.http_request(p, %{})
    end
  end

  describe "stale-grant denials (a manifest revised after approval)" do
    defp declared_plugin(declared, granted) do
      %Plugin{
        slug: "tester",
        name: "Tester",
        capabilities: declared,
        granted_capabilities: granted,
        enabled: true
      }
    end

    test "a class the manifest declares but the grant lacks points at re-approval" do
      p = declared_plugin(%{"state:kv" => []}, %{"events:subscribe" => ["media_item.added"]})

      assert {:error, %Error{type: :capability_denied, message: msg}} =
               HostFunctions.kv_get(p, "k")

      assert msg =~ "re-approve"
    end

    test "a host the manifest declares but the grant lacks points at re-approval" do
      p = declared_plugin(%{"net:http" => ["api.example.com"]}, %{"net:http" => ["discord.com"]})

      assert {:error, %Error{type: :capability_denied, message: msg}} =
               HostFunctions.http_request(p, %{"url" => "https://api.example.com/x"},
                 resolver: loopback_resolver()
               )

      assert msg =~ "re-approve"
    end

    test "a host the manifest never declared still reads as an allowlist denial" do
      p = declared_plugin(%{"net:http" => ["discord.com"]}, %{"net:http" => ["discord.com"]})

      assert {:error, %Error{type: :capability_denied, message: msg}} =
               HostFunctions.http_request(p, %{"url" => "https://evil.test/"},
                 resolver: loopback_resolver()
               )

      assert msg =~ "allowlist"
      refute msg =~ "re-approve"
    end

    test "a namespace the manifest declares but the grant lacks points at re-approval" do
      item = media_item_fixture()
      p = declared_plugin(%{"data:read" => ["media_item"]}, %{"data:read" => []})

      assert {:error, %Error{type: :capability_denied, message: msg}} =
               HostFunctions.data_read(p, %{"resource" => "media_item", "id" => item.id})

      assert msg =~ "re-approve"
    end
  end

  describe "data_read/2 (data:read grant)" do
    test "returns a curated projection for a granted namespace" do
      item = media_item_fixture(%{title: "Dune", year: 2021, type: "movie"})
      p = plugin(%{"data:read" => ["media_item"]})

      assert {:ok, projection} =
               HostFunctions.data_read(p, %{"resource" => "media_item", "id" => item.id})

      assert projection["title"] == "Dune"
      assert projection["year"] == 2021
      assert projection["type"] == "movie"
      # The projection is curated — it never carries the raw struct's internals.
      refute Map.has_key?(projection, :__struct__)
      refute Map.has_key?(projection, "metadata")
    end

    test "is denied without the data:read grant" do
      item = media_item_fixture()
      p = plugin(%{"net:http" => ["discord.com"]})

      assert {:error, %Error{type: :capability_denied}} =
               HostFunctions.data_read(p, %{"resource" => "media_item", "id" => item.id})
    end

    test "is denied when the namespace is not granted" do
      item = media_item_fixture()
      p = plugin(%{"data:read" => ["something_else"]})

      assert {:error, %Error{type: :capability_denied}} =
               HostFunctions.data_read(p, %{"resource" => "media_item", "id" => item.id})
    end

    test "an unknown resource is rejected" do
      p = plugin(%{"data:read" => ["media_item"]})

      assert {:error, %Error{type: :invalid_request}} =
               HostFunctions.data_read(p, %{"resource" => "user", "id" => "1"})
    end

    test "a missing media item returns not_found" do
      p = plugin(%{"data:read" => ["media_item"]})

      assert {:error, %Error{type: type}} =
               HostFunctions.data_read(p, %{
                 "resource" => "media_item",
                 "id" => "00000000-0000-0000-0000-000000000000"
               })

      assert type in [:not_found, :invalid_request]
    end
  end

  describe "imports_for/2" do
    test "builds a per-invocation builder for the typed host interface" do
      builder = HostFunctions.imports_for("tester")
      assert is_function(builder, 1)

      imports = builder.(%{slug: "tester", invocation_id: "x", test_run: false})

      assert %{"mydia:plugin/host@1.2.0" => fns} = imports

      assert %{"http-request" => {:fn, f1}, "data-read" => {:fn, f2}, "log" => {:fn, f3}} = fns
      assert is_function(f1, 1) and is_function(f2, 1) and is_function(f3, 2)

      # 1.1 additions are all wired so a 1.1 guest instantiates.
      assert %{
               "kv-get" => {:fn, _},
               "kv-set" => {:fn, _},
               "kv-delete" => {:fn, _},
               "data-list" => {:fn, _},
               "ensure-watched" => {:fn, _},
               "ensure-favorite" => {:fn, _},
               "connections-list" => {:fn, _},
               "connection-request" => {:fn, _}
             } = fns
    end
  end

  describe "kv host functions (state:kv grant)" do
    setup do
      {:ok, _} =
        Mydia.Settings.create_plugin_config(%{
          slug: "tester",
          name: "Tester",
          version: "1.0.0",
          source_url: "test",
          manifest: %{
            "slug" => "tester",
            "name" => "Tester",
            "version" => "1.0.0",
            "capabilities" => %{
              "events:subscribe" => ["media_item.added"],
              "state:kv" => []
            }
          },
          granted_capabilities: %{"state:kv" => []},
          enabled: false
        })

      :ok
    end

    test "set then get round-trips, returning an option" do
      p = plugin(%{"state:kv" => []})
      assert {:ok, true} = HostFunctions.kv_set(p, "k", "v")
      assert {:ok, {:some, "v"}} = HostFunctions.kv_get(p, "k")
    end

    test "kv-get on a missing key returns none" do
      p = plugin(%{"state:kv" => []})
      assert {:ok, :none} = HostFunctions.kv_get(p, "absent")
    end

    test "kv-delete removes the key" do
      p = plugin(%{"state:kv" => []})
      {:ok, true} = HostFunctions.kv_set(p, "k", "v")
      assert {:ok, true} = HostFunctions.kv_delete(p, "k")
      assert {:ok, :none} = HostFunctions.kv_get(p, "k")
    end

    test "AE4: a plugin without state:kv is denied across all three" do
      p = plugin(%{"events:subscribe" => ["media_item.added"]})
      assert {:error, %Error{type: :capability_denied}} = HostFunctions.kv_get(p, "k")
      assert {:error, %Error{type: :capability_denied}} = HostFunctions.kv_set(p, "k", "v")
      assert {:error, %Error{type: :capability_denied}} = HostFunctions.kv_delete(p, "k")
    end

    test "an empty key is rejected as invalid-request" do
      p = plugin(%{"state:kv" => []})
      assert {:error, %Error{type: :invalid_request}} = HostFunctions.kv_get(p, "")
    end
  end

  describe "connections_list/1 (users:connections grant)" do
    setup do
      {:ok, _} =
        Mydia.Settings.create_plugin_config(%{
          slug: "tester",
          name: "Tester",
          version: "1.0.0",
          source_url: "test",
          manifest: %{
            "slug" => "tester",
            "name" => "Tester",
            "version" => "1.0.0",
            "capabilities" => %{
              "events:subscribe" => ["media_item.added"],
              "users:connections" => []
            }
          },
          granted_capabilities: %{"users:connections" => []},
          enabled: false
        })

      %{user: user_fixture()}
    end

    test "returns identity and status, never a token", %{user: user} do
      {:ok, _} =
        Connections.connect("tester", user.id, %{
          access_token: "do-not-leak",
          external_user_id: "ext-9",
          external_username: "bob"
        })

      p = plugin(%{"users:connections" => []})
      assert {:ok, [record]} = HostFunctions.connections_list(p)

      assert record[:"user-id"] == user.id
      assert record.status == :connected
      assert record[:"external-username"] == {:some, "bob"}

      # No field in the record carries token material.
      refute inspect(record) =~ "do-not-leak"
      refute Map.has_key?(record, :access_token)
      refute Map.has_key?(record, :"access-token")
    end

    test "AE4: a plugin without users:connections is denied" do
      p = plugin(%{"events:subscribe" => ["media_item.added"]})
      assert {:error, %Error{type: :capability_denied}} = HostFunctions.connections_list(p)
    end
  end

  describe "data_list/2 (data:read grant)" do
    setup do
      {:ok, _} =
        Mydia.Settings.create_plugin_config(%{
          slug: "tester",
          name: "Tester",
          version: "1.0.0",
          source_url: "test",
          manifest: %{
            "slug" => "tester",
            "name" => "Tester",
            "version" => "1.0.0",
            "capabilities" => %{"events:subscribe" => ["media_item.added"]}
          },
          granted_capabilities: %{},
          enabled: false
        })

      :ok
    end

    defp list_req(namespace, opts \\ []) do
      %{
        namespace: namespace,
        cursor: Keyword.get(opts, :cursor, :none),
        "updated-since": Keyword.get(opts, :updated_since, :none),
        limit: Keyword.get(opts, :limit, :none)
      }
    end

    defp create_movie do
      {:ok, item} =
        Mydia.Media.create_media_item(%{
          title: "Movie #{System.unique_integer([:positive])}",
          type: "movie",
          year: 2024,
          tmdb_id: System.unique_integer([:positive]),
          imdb_id: "tt#{System.unique_integer([:positive])}"
        })

      item
    end

    # Walk every page, collecting the variant rows.
    defp walk(plugin, namespace, limit) do
      walk(plugin, namespace, limit, :none, [])
    end

    defp walk(plugin, namespace, limit, cursor, acc) do
      req = list_req(namespace, cursor: cursor, limit: {:some, limit})
      assert {:ok, %{items: items, "next-cursor": next}} = HostFunctions.data_list(plugin, req)
      acc = acc ++ items

      case next do
        :none -> acc
        {:some, _} = c -> walk(plugin, namespace, limit, c, acc)
      end
    end

    test "media_item pagination walks the full set exactly once" do
      ids = for _ <- 1..5, do: create_movie().id
      p = plugin(%{"data:read" => ["media_item"]})

      rows = walk(p, "media_item", 2)
      seen = Enum.map(rows, fn {:"media-item", rec} -> rec.id end)

      assert Enum.sort(seen) == Enum.sort(ids)
      assert length(seen) == length(Enum.uniq(seen))
    end

    test "an unknown but granted namespace is invalid-request" do
      # Granting an unknown namespace passes the grant gate, so the host reaches
      # the namespace dispatch and reports it has no backing.
      p = plugin(%{"data:read" => ["bogus"]})

      assert {:error, %Error{type: :invalid_request}} =
               HostFunctions.data_list(p, list_req("bogus"))
    end

    test "a real namespace that is not granted is denied" do
      p = plugin(%{"data:read" => ["media_item"]})

      assert {:error, %Error{type: :capability_denied}} =
               HostFunctions.data_list(p, list_req("playback_progress"))
    end

    test "AE3: playback_progress returns rows only for connected users" do
      connected = user_fixture()
      other = user_fixture()
      movie = create_movie()

      {:ok, _} = Mydia.Plugins.Connections.connect("tester", connected.id, %{access_token: "t"})

      {:ok, _} =
        Mydia.Playback.save_progress(connected.id, [media_item_id: movie.id], %{
          position_seconds: 95,
          duration_seconds: 100
        })

      {:ok, _} =
        Mydia.Playback.save_progress(other.id, [media_item_id: movie.id], %{
          position_seconds: 95,
          duration_seconds: 100
        })

      p = plugin(%{"data:read" => ["playback_progress"]})
      assert {:ok, %{items: items}} = HostFunctions.data_list(p, list_req("playback_progress"))

      user_ids = Enum.map(items, fn {:"playback-progress", rec} -> rec[:"user-id"] end)
      assert connected.id in user_ids
      refute other.id in user_ids
    end

    test "an episode progress projection carries coordinates and the show's ids" do
      user = user_fixture()
      {:ok, _} = Mydia.Plugins.Connections.connect("tester", user.id, %{access_token: "t"})

      {:ok, show} =
        Mydia.Media.create_media_item(
          %{title: "Show", type: "tv_show", tmdb_id: System.unique_integer([:positive])},
          skip_episode_refresh: true
        )

      {:ok, episode} =
        Mydia.Media.create_episode(%{
          media_item_id: show.id,
          season_number: 2,
          episode_number: 4,
          title: "Ep"
        })

      {:ok, _} =
        Mydia.Playback.save_progress(user.id, [episode_id: episode.id], %{
          position_seconds: 95,
          duration_seconds: 100
        })

      p = plugin(%{"data:read" => ["playback_progress"]})

      assert {:ok, %{items: [{:"playback-progress", rec}]}} =
               HostFunctions.data_list(p, list_req("playback_progress"))

      assert rec[:"item-type"] == "episode"
      assert rec[:"season-number"] == {:some, 2}
      assert rec[:"episode-number"] == {:some, 4}
      assert rec[:"tmdb-id"] == {:some, show.tmdb_id}
      assert rec.watched == true
    end
  end

  describe "data_list/2 library_item namespace" do
    test "denies a plugin without the library_item namespace" do
      p = plugin(%{"data:read" => ["media_item"]})

      assert {:error, %Error{type: :capability_denied}} =
               HostFunctions.data_list(p, %{namespace: "library_item"})
    end

    test "projects the owned flag onto the WIT record" do
      movie = media_item_fixture(%{type: "movie", title: "Owned"})
      _file = media_file_fixture(%{media_item_id: movie.id})

      p = plugin(%{"data:read" => ["library_item"]})

      assert {:ok, %{items: items}} =
               HostFunctions.data_list(p, %{namespace: "library_item"})

      assert {:"library-item", record} =
               Enum.find(items, fn {_tag, r} -> r.id == movie.id end)

      assert record.owned == true
      assert record[:"item-type"] == "movie"
      assert is_binary(record[:"updated-at"])
    end
  end

  describe "connection_request/4 (host-attached auth)" do
    setup do
      {:ok, _} =
        Mydia.Settings.create_plugin_config(%{
          slug: "tester",
          name: "Tester",
          version: "1.0.0",
          source_url: "test",
          manifest: %{
            "slug" => "tester",
            "name" => "Tester",
            "version" => "1.0.0",
            "capabilities" => %{"events:subscribe" => ["media_item.added"]}
          },
          granted_capabilities: %{},
          enabled: false
        })

      user = user_fixture()

      {:ok, conn} =
        Connections.connect("tester", user.id, %{access_token: "secret-bearer"})

      %{bypass: Bypass.open(), connection: conn}
    end

    test "injects the host-held bearer token and strips any guest Authorization",
         %{bypass: bypass, connection: conn} do
      parent = self()

      Bypass.expect_once(bypass, "GET", "/sync/activities", fn c ->
        send(parent, {:auth, Plug.Conn.get_req_header(c, "authorization")})
        Plug.Conn.resp(c, 200, ~s({"ok":true}))
      end)

      p = plugin(%{"net:http" => ["127.0.0.1"], "users:connections" => []})

      request = %{
        "url" => "http://127.0.0.1:#{bypass.port}/sync/activities",
        "method" => "GET",
        "headers" => %{"authorization" => "Bearer guest-forged"}
      }

      assert {:ok, %{"status" => 200}} =
               HostFunctions.connection_request(p, conn.id, request,
                 resolver: loopback_resolver(),
                 allow_private: true
               )

      assert_received {:auth, ["Bearer secret-bearer"]}
    end

    test "a connection that does not belong to the plugin is not found", %{connection: _conn} do
      p = plugin(%{"net:http" => ["127.0.0.1"], "users:connections" => []})

      assert {:error, %Error{type: :not_found}} =
               HostFunctions.connection_request(
                 p,
                 Ecto.UUID.generate(),
                 %{"url" => "http://127.0.0.1/x"},
                 resolver: loopback_resolver(),
                 allow_private: true
               )
    end
  end

  describe "ensure_watched/2 (surfaces:write playback:watched)" do
    setup do
      {:ok, _} =
        Mydia.Settings.create_plugin_config(%{
          slug: "tester",
          name: "Tester",
          version: "1.0.0",
          source_url: "test",
          manifest: %{
            "slug" => "tester",
            "name" => "Tester",
            "version" => "1.0.0",
            "capabilities" => %{"events:subscribe" => ["media_item.added"]}
          },
          granted_capabilities: %{},
          enabled: false
        })

      user = user_fixture()
      {:ok, _} = Connections.connect("tester", user.id, %{access_token: "t"})
      %{user: user}
    end

    defp opt(nil), do: :none
    defp opt(v), do: {:some, v}

    defp target(user_id, opts) do
      %{
        "user-id": user_id,
        "imdb-id": opt(opts[:imdb]),
        "tmdb-id": opt(opts[:tmdb]),
        "tvdb-id": opt(opts[:tvdb]),
        "season-number": opt(opts[:season]),
        "episode-number": opt(opts[:episode]),
        "watched-at": opt(opts[:watched_at])
      }
    end

    defp movie_with(attrs) do
      {:ok, item} =
        Mydia.Media.create_media_item(Map.merge(%{title: "M", type: "movie", year: 2024}, attrs))

      item
    end

    defp finished_events(user) do
      Events.list_events(type: "playback.finished", actor_type: :user, actor_id: user.id)
    end

    test "grant access: write is denied without surfaces:write playback:watched", %{user: user} do
      p = plugin(%{"events:subscribe" => ["media_item.added"]})

      assert {:error, %Error{type: :capability_denied}} =
               HostFunctions.ensure_watched(p, target(user.id, imdb: "tt1"))
    end

    test "AE3: a user with no active connection is denied" do
      stranger = user_fixture()
      p = plugin(%{"surfaces:write" => ["playback:watched"]})

      assert {:error, %Error{type: :capability_denied}} =
               HostFunctions.ensure_watched(p, target(stranger.id, imdb: "tt1"))
    end

    test "AE1: a matched movie is marked watched; re-applying is an idempotent no-op",
         %{user: user} do
      _movie = movie_with(%{imdb_id: "tt500", tmdb_id: 500})
      p = plugin(%{"surfaces:write" => ["playback:watched"]})

      assert {:ok, %{status: :changed}} =
               HostFunctions.ensure_watched(p, target(user.id, imdb: "tt500"))

      # A synthetic-progress row created -> one finished event, origin plugin:tester.
      assert [event] = finished_events(user)
      assert event.metadata["origin"] == "plugin:tester"

      # Re-applying reports already-watched and emits no new event.
      assert {:ok, %{status: :"already-watched"}} =
               HostFunctions.ensure_watched(p, target(user.id, imdb: "tt500"))

      assert [_only] = finished_events(user)
    end

    test "unmatched external ids return not-found with no write", %{user: user} do
      p = plugin(%{"surfaces:write" => ["playback:watched"]})

      assert {:ok, %{status: :"not-found"}} =
               HostFunctions.ensure_watched(p, target(user.id, imdb: "tt-nope"))

      assert finished_events(user) == []
    end

    test "episode coordinates resolve through the show; a missing episode is not-found",
         %{user: user} do
      {:ok, show} =
        Mydia.Media.create_media_item(
          %{title: "Show", type: "tv_show", tvdb_id: 999},
          skip_episode_refresh: true
        )

      {:ok, ep} =
        Mydia.Media.create_episode(%{
          media_item_id: show.id,
          season_number: 3,
          episode_number: 7,
          title: "Ep"
        })

      p = plugin(%{"surfaces:write" => ["playback:watched"]})

      assert {:ok, %{status: :changed}} =
               HostFunctions.ensure_watched(p, target(user.id, tvdb: 999, season: 3, episode: 7))

      assert Mydia.Playback.get_progress(user.id, episode_id: ep.id).watched == true

      # A nonexistent episode of the same show is not-found.
      assert {:ok, %{status: :"not-found"}} =
               HostFunctions.ensure_watched(p, target(user.id, tvdb: 999, season: 9, episode: 9))
    end
  end

  describe "ensure_favorite/2 capability gate" do
    test "denies a plugin without the collections:favorite surface" do
      p = plugin(%{"surfaces:write" => ["playback:watched"]})

      assert {:error, %Error{type: :capability_denied}} =
               HostFunctions.ensure_favorite(p, %{
                 "user-id": "u1",
                 "imdb-id": {:some, "tt0111161"},
                 "tmdb-id": :none,
                 "tvdb-id": :none
               })
    end
  end
end
