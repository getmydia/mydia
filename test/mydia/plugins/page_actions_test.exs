defmodule Mydia.Plugins.PageActionsTest do
  # Not async: the media_add tests point the global metadata relay URL at a
  # Bypass server.
  use Mydia.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.Collections
  alias Mydia.Media
  alias Mydia.Metadata.Cache
  alias Mydia.Plugins.Grants
  alias Mydia.Plugins.Journal
  alias Mydia.Plugins.PageActions
  alias Mydia.Plugins.PendingWrite
  alias Mydia.Plugins.Plugin
  alias Mydia.Settings

  @surfaces ["playback:watched", "collections:favorite", "collections:write", "media:add"]

  setup do
    {:ok, _} =
      Settings.create_plugin_config(%{
        slug: "helper",
        name: "Helper",
        version: "0.1.0",
        source_url: "test",
        manifest: %{"slug" => "helper", "name" => "Helper", "version" => "0.1.0"},
        granted_capabilities: %{"surfaces:write" => @surfaces},
        enabled: true
      })

    plugin = %Plugin{
      slug: "helper",
      name: "Helper",
      enabled: true,
      granted_capabilities: %{"surfaces:write" => @surfaces, "surfaces:page" => []}
    }

    user = user_fixture()
    movie = media_item_fixture(%{title: "Harbor of Glass", tmdb_id: "777001"})
    {:ok, plugin: plugin, user: user, movie: movie}
  end

  defp ctx(user, session \\ "s1", invocation \\ "inv-1"),
    do: %{
      handler: :on_http,
      acting_user_id: user.id,
      role: user.role,
      session_id: session,
      invocation_id: invocation,
      slug: "helper"
    }

  # Serves one movie from a Bypass relay and points the default relay config at
  # it for the rest of the test.
  defp stub_relay_movie(tmdb_id, title, year) do
    bypass = Mydia.RelayStubHelpers.point_relay_at_bypass()

    language = Mydia.Metadata.default_relay_config().options.language

    on_exit(fn ->
      Cache.delete("fetch_by_ref:tmdb:#{tmdb_id}:movie:#{language}::official")
    end)

    Bypass.stub(bypass, "GET", "/tmdb/movies/#{tmdb_id}", fn conn ->
      body = %{
        "id" => tmdb_id,
        "title" => title,
        "release_date" => "#{year}-03-04",
        "overview" => "x",
        "credits" => %{"cast" => [], "crew" => []},
        "genres" => []
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  # Serves one TV show from a Bypass relay. Season requests are recorded in the
  # returned Agent, so a test can tell when the episode fetch happened.
  defp stub_relay_tv(tmdb_id) do
    paths = start_supervised!({Agent, fn -> [] end})
    bypass = Mydia.RelayStubHelpers.point_relay_at_bypass()
    language = Mydia.Metadata.default_relay_config().options.language

    on_exit(fn ->
      Cache.delete("fetch_by_ref:tmdb:#{tmdb_id}:tv_show:#{language}::official")
    end)

    Bypass.stub(bypass, "GET", "/tmdb/tv/shows/#{tmdb_id}", fn conn ->
      body = %{
        "id" => tmdb_id,
        "name" => "The Slate Lighthouse",
        "first_air_date" => "2031-03-04",
        "credits" => %{"cast" => [], "crew" => []},
        "seasons" => [%{"season_number" => 1, "episode_count" => 1}],
        "external_ids" => %{}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)

    Bypass.stub(bypass, "GET", "/tvdb/search", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"data" => []}))
    end)

    Bypass.stub(bypass, "GET", "/tmdb/tv/shows/#{tmdb_id}/1", fn conn ->
      Agent.update(paths, &[conn.request_path | &1])
      Plug.Conn.resp(conn, 404, "{}")
    end)

    paths
  end

  defp movie_target(tmdb_id),
    do: %{"media-type": "movie", "tmdb-id": {:some, tmdb_id}, "tvdb-id": :none}

  test "without a grant a write becomes pending", %{plugin: plugin, user: user, movie: movie} do
    assert {:ok, {:"needs-confirmation", id}} =
             PageActions.add_favorite(plugin, ctx(user), %{
               "tmdb-id": {:some, 777_001},
               "user-id": "ignored"
             })

    refute Collections.is_favorite?(Scope.for_user(user), movie.id)
    assert {:ok, [pending]} = PageActions.pending("helper", user.id, "s1", [id])
    assert pending.description =~ "Harbor of Glass"
  end

  test "with a grant a write executes and is journaled", %{
    plugin: plugin,
    user: user,
    movie: movie
  } do
    :ok = Grants.grant("helper", user.id, "collections:favorite", "always", "s0")

    assert {:ok, {:done, json}} =
             PageActions.add_favorite(plugin, ctx(user), %{"tmdb-id": {:some, 777_001}})

    assert %{"status" => "changed"} = Jason.decode!(json)
    assert Collections.is_favorite?(Scope.for_user(user), movie.id)
    assert [%{op: "favorite_add", batch_id: "inv-1"}] = Journal.list("helper", user.id)
  end

  test "a journal failure rolls the write back", %{plugin: plugin, user: user} do
    :ok = Grants.grant("helper", user.id, "collections:write", "always", "s0")

    # A blank batch id cannot be journaled.
    assert {:error, %{type: :unknown}} =
             PageActions.collection_create(plugin, ctx(user, "s1", ""), %{
               name: {:some, "Ghost Shelf"}
             })

    refute Enum.any?(Collections.list_collections(user), &(&1.name == "Ghost Shelf"))
    assert Journal.list("helper", user.id) == []
  end

  test "confirm with session records the grant and runs the batch", %{plugin: plugin, user: user} do
    {:ok, {:"needs-confirmation", id}} =
      PageActions.collection_create(plugin, ctx(user), %{name: {:some, "Rainy Sundays"}})

    assert {:ok, [%{id: ^id, ok: true}]} =
             PageActions.confirm("helper", user, "s1", [id], "session")

    assert Grants.granted?("helper", user.id, "collections:write", "s1")
    assert {:ok, []} = PageActions.pending("helper", user.id, "s1", [])
    assert [%{op: "collection_create"}] = Journal.list("helper", user.id)
  end

  test "confirming the same ids twice runs the write once", %{plugin: plugin, user: user} do
    {:ok, {:"needs-confirmation", id}} =
      PageActions.collection_create(plugin, ctx(user), %{name: {:some, "Once Only"}})

    assert {:ok, [%{ok: true}]} = PageActions.confirm("helper", user, "s1", [id], "once")
    assert {:error, :invalid} = PageActions.confirm("helper", user, "s1", [id], "once")
    assert length(Journal.list("helper", user.id)) == 1
  end

  test "confirm refuses ids from another session or user", %{plugin: plugin, user: user} do
    {:ok, {:"needs-confirmation", id}} =
      PageActions.collection_create(plugin, ctx(user), %{name: {:some, "X"}})

    assert {:error, :invalid} = PageActions.confirm("helper", user, "other", [id], "once")
    assert {:error, :invalid} = PageActions.confirm("helper", user_fixture(), "s1", [id], "once")
  end

  test "expired pending writes are not offered or confirmable", %{plugin: plugin, user: user} do
    {:ok, {:"needs-confirmation", id}} =
      PageActions.collection_create(plugin, ctx(user), %{name: {:some, "Stale"}})

    past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)
    Repo.update_all(PendingWrite, set: [expires_at: past])

    assert {:ok, []} = PageActions.pending("helper", user.id, "s1", [])
    assert {:error, :invalid} = PageActions.confirm("helper", user, "s1", [id], "once")
  end

  test "confirm refuses a choice above the ceiling", %{plugin: plugin} do
    guest = user_fixture(%{role: "guest"})

    {:ok, {:"needs-confirmation", id}} =
      PageActions.collection_create(plugin, ctx(guest), %{name: {:some, "X"}})

    assert {:error, :choice_not_allowed} =
             PageActions.confirm("helper", guest, "s1", [id], "always")
  end

  test "readonly users are denied without a prompt", %{plugin: plugin} do
    ro = user_fixture(%{role: "readonly"})

    assert {:error, %{type: :capability_denied}} =
             PageActions.collection_create(plugin, ctx(ro), %{name: {:some, "X"}})
  end

  test "a surface the plugin lacks is denied", %{user: user} do
    bare = %Plugin{slug: "helper", name: "H", enabled: true, granted_capabilities: %{}}

    assert {:error, %{type: :capability_denied}} =
             PageActions.collection_create(bare, ctx(user), %{name: {:some, "X"}})
  end

  test "page writes are denied outside on-http", %{plugin: plugin} do
    event_ctx = %{handler: :on_event, invocation_id: "e1", slug: "helper"}

    assert {:error, %{type: :capability_denied, message: msg}} =
             PageActions.collection_create(plugin, event_ctx, %{name: {:some, "X"}})

    assert msg =~ "interactive"
  end

  test "deny drops the pending rows", %{plugin: plugin, user: user} do
    {:ok, {:"needs-confirmation", id}} =
      PageActions.collection_create(plugin, ctx(user), %{name: {:some, "X"}})

    assert :ok = PageActions.deny("helper", user.id, "s1", [id])
    assert {:error, :invalid} = PageActions.confirm("helper", user, "s1", [id], "once")
    assert Repo.aggregate(from(p in PendingWrite, where: p.id == ^id), :count) == 0
  end

  test "a grant above a lowered role ceiling is not honored", %{plugin: plugin, user: user} do
    :ok = Grants.grant("helper", user.id, "collections:write", "always", "s0")
    {:ok, _} = Grants.put_ceilings("helper", %{"user" => "once"})

    assert {:ok, {:"needs-confirmation", _id}} =
             PageActions.collection_create(plugin, ctx(user), %{name: {:some, "Capped"}})
  end

  describe "confirm re-checks" do
    test "a revoked surfaces:write grant", %{plugin: plugin, user: user} do
      {:ok, {:"needs-confirmation", id}} =
        PageActions.collection_create(plugin, ctx(user), %{name: {:some, "Revoked"}})

      config = Settings.get_plugin_config_by_slug("helper")
      {:ok, _} = Settings.update_plugin_config(config, %{granted_capabilities: %{}})

      assert {:ok, [%{id: ^id, ok: false, error: msg}]} =
               PageActions.confirm("helper", user, "s1", [id], "once")

      assert msg =~ "not granted"
      assert Journal.list("helper", user.id) == []
    end

    test "a disabled plugin", %{plugin: plugin, user: user} do
      {:ok, {:"needs-confirmation", id}} =
        PageActions.collection_create(plugin, ctx(user), %{name: {:some, "Off"}})

      config = Settings.get_plugin_config_by_slug("helper")
      {:ok, _} = Settings.update_plugin_config(config, %{enabled: false})

      assert {:ok, [%{ok: false}]} = PageActions.confirm("helper", user, "s1", [id], "once")
    end
  end

  describe "confirm claims atomically" do
    test "an unknown id among real ones claims nothing and records no grant", %{
      plugin: plugin,
      user: user
    } do
      {:ok, {:"needs-confirmation", id}} =
        PageActions.collection_create(plugin, ctx(user), %{name: {:some, "Kept"}})

      assert {:error, :invalid} =
               PageActions.confirm("helper", user, "s1", [id, Ecto.UUID.generate()], "session")

      refute Grants.granted?("helper", user.id, "collections:write", "s1")
      assert {:ok, [_]} = PageActions.pending("helper", user.id, "s1", [id])
    end

    test "an expired row records no grant", %{plugin: plugin, user: user} do
      {:ok, {:"needs-confirmation", id}} =
        PageActions.collection_create(plugin, ctx(user), %{name: {:some, "Stale"}})

      past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)
      Repo.update_all(PendingWrite, set: [expires_at: past])

      assert {:error, :invalid} = PageActions.confirm("helper", user, "s1", [id], "always")
      refute Grants.granted?("helper", user.id, "collections:write", "s1")
    end
  end

  describe "pending writes are bounded" do
    test "a session cannot park more than the cap", %{plugin: plugin, user: user} do
      for n <- 1..50 do
        assert {:ok, {:"needs-confirmation", _}} =
                 PageActions.collection_create(plugin, ctx(user), %{name: {:some, "C#{n}"}})
      end

      assert {:error, %{type: :invalid_request}} =
               PageActions.collection_create(plugin, ctx(user), %{name: {:some, "One more"}})

      assert {:ok, {:"needs-confirmation", _}} =
               PageActions.collection_create(plugin, ctx(user, "s2"), %{name: {:some, "Other"}})
    end

    test "expired rows are pruned when a new one is parked", %{plugin: plugin, user: user} do
      {:ok, {:"needs-confirmation", old}} =
        PageActions.collection_create(plugin, ctx(user), %{name: {:some, "Old"}})

      past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)
      Repo.update_all(PendingWrite, set: [expires_at: past])

      {:ok, {:"needs-confirmation", _}} =
        PageActions.collection_create(plugin, ctx(user), %{name: {:some, "New"}})

      assert Repo.get(PendingWrite, old) == nil
    end

    test "an oversized collection name is refused", %{plugin: plugin, user: user} do
      long = String.duplicate("a", 201)

      assert {:error, %{type: :invalid_request}} =
               PageActions.collection_create(plugin, ctx(user), %{name: {:some, long}})

      assert {:error, %{type: :invalid_request}} =
               PageActions.collection_update(plugin, ctx(user), Ecto.UUID.generate(), %{
                 name: {:some, long}
               })
    end
  end

  describe "media:add" do
    test "a user adds the item to the library through the relay", %{plugin: plugin, user: user} do
      tmdb_id = 900_000_000 + System.unique_integer([:positive])
      stub_relay_movie(tmdb_id, "The Tin Orchard", 2031)
      :ok = Grants.grant("helper", user.id, "media:add", "session", "s1")

      assert {:ok, {:done, json}} =
               PageActions.media_add(plugin, ctx(user), movie_target(tmdb_id))

      assert %{"media_item_id" => item_id} = Jason.decode!(json)

      item = Media.get_media_item!(Scope.for_user(user), item_id)
      assert item.title == "The Tin Orchard"
      assert item.tmdb_id == tmdb_id

      assert [%{op: "media_add", description: "Add The Tin Orchard (2031) to the library"}] =
               Journal.list("helper", user.id)
    end

    test "the relay is consulted before the write transaction, not inside it", %{user: user} do
      tmdb_id = 900_000_000 + System.unique_integer([:positive])
      stub_relay_movie(tmdb_id, "The Tin Orchard", 2031)

      args = %{
        "media_type" => "movie",
        "provider" => "tmdb",
        "provider_id" => tmdb_id,
        "title" => "The Tin Orchard",
        "year" => 2031
      }

      assert {:ok, prepared} = Mydia.Plugins.PageWrites.prepare("media_add", args, user)

      # With the relay unreachable, executing the prepared write still works:
      # it does no network work of its own.
      Application.put_env(:mydia, :metadata_relay_url, "http://127.0.0.1:1")

      assert {:ok, %{"media_item_id" => _}, _inverse} =
               Mydia.Plugins.PageWrites.execute(
                 "media_add",
                 args,
                 user,
                 "plugin:helper",
                 prepared
               )
    end

    test "a TV add fetches episodes after the transaction, not inside it", %{user: user} do
      tmdb_id = 900_000_000 + System.unique_integer([:positive])
      paths = stub_relay_tv(tmdb_id)

      args = %{
        "media_type" => "tv_show",
        "provider" => "tmdb",
        "provider_id" => tmdb_id,
        "title" => "The Slate Lighthouse",
        "year" => 2031
      }

      # Inside the transaction: the write itself makes no episode call.
      assert {:ok, prepared} = Mydia.Plugins.PageWrites.prepare("media_add", args, user)

      assert {:ok, %{"media_item_id" => id} = result, _} =
               Mydia.Plugins.PageWrites.execute(
                 "media_add",
                 args,
                 user,
                 "plugin:helper",
                 prepared
               )

      assert Agent.get(paths, & &1) == []
      assert id

      # After commit: the episode fetch runs.
      capture_log(fn ->
        assert :ok = Mydia.Plugins.PageWrites.after_commit("media_add", result, user, prepared)
      end)

      assert Agent.get(paths, & &1) != []
    end

    test "a TV add through PageActions still fetches its episodes", %{plugin: plugin, user: user} do
      tmdb_id = 900_000_000 + System.unique_integer([:positive])
      paths = stub_relay_tv(tmdb_id)
      :ok = Grants.grant("helper", user.id, "media:add", "session", "s1")

      capture_log(fn ->
        assert {:ok, {:done, json}} =
                 PageActions.media_add(plugin, ctx(user), %{
                   "media-type": "tv_show",
                   "tmdb-id": {:some, tmdb_id},
                   "tvdb-id": :none
                 })

        assert %{"media_item_id" => _} = Jason.decode!(json)
      end)

      assert Agent.get(paths, & &1) != []
    end

    test "an add that is already in the library fetches nothing after commit", %{user: user} do
      result = %{"media_item_id" => Ecto.UUID.generate(), "status" => "already-in-library"}

      assert :ok =
               Mydia.Plugins.PageWrites.after_commit("media_add", result, user, %{
                 defaults: %{season_monitoring: "all"}
               })
    end

    test "executing media_add without preparing it is an error, not I/O", %{user: user} do
      args = %{"media_type" => "movie", "provider" => "tmdb", "provider_id" => 1}

      assert {:error, %{message: msg}} =
               Mydia.Plugins.PageWrites.execute("media_add", args, user, "plugin:helper")

      assert msg =~ "prepared"
    end

    test "without a grant the confirmation text carries the relay title", %{
      plugin: plugin,
      user: user
    } do
      tmdb_id = 900_000_000 + System.unique_integer([:positive])
      stub_relay_movie(tmdb_id, "The Tin Orchard", 2031)

      assert {:ok, {:"needs-confirmation", id}} =
               PageActions.media_add(plugin, ctx(user), movie_target(tmdb_id))

      assert {:ok, [%{description: "Add The Tin Orchard (2031) to the library"}]} =
               PageActions.pending("helper", user.id, "s1", [id])
    end

    test "a guest gets a request instead", %{plugin: plugin} do
      guest = user_fixture(%{role: "guest"})
      tmdb_id = 900_000_000 + System.unique_integer([:positive])
      stub_relay_movie(tmdb_id, "The Tin Orchard", 2031)
      :ok = Grants.grant("helper", guest.id, "media:add", "session", "s1")

      assert {:ok, {:done, json}} =
               PageActions.media_add(plugin, ctx(guest), movie_target(tmdb_id))

      assert %{"request_id" => _} = Jason.decode!(json)
    end

    test "a request stores only the id the relay verified", %{plugin: plugin} do
      guest = user_fixture(%{role: "guest"})
      tmdb_id = 900_000_000 + System.unique_integer([:positive])
      stub_relay_movie(tmdb_id, "The Tin Orchard", 2031)
      :ok = Grants.grant("helper", guest.id, "media:add", "session", "s1")

      target = %{movie_target(tmdb_id) | "tvdb-id": {:some, 424_242}}
      assert {:ok, {:done, _json}} = PageActions.media_add(plugin, ctx(guest), target)

      assert [request] = Mydia.MediaRequests.list_requests(requester_id: guest.id)
      assert request.tmdb_id == tmdb_id
      assert request.tvdb_id == nil
    end

    test "a role that can neither add nor request is refused", %{plugin: plugin} do
      ro = user_fixture(%{role: "readonly"})

      assert {:error, %{type: :capability_denied}} =
               PageActions.media_add(plugin, ctx(ro), movie_target(900_000_001))
    end

    test "a title the relay does not know is not found", %{plugin: plugin, user: user} do
      bypass = Mydia.RelayStubHelpers.point_relay_at_bypass()

      Bypass.stub(bypass, "GET", "/tmdb/movies/900000002", fn conn ->
        Plug.Conn.resp(conn, 404, "{}")
      end)

      assert {:error, %{type: :not_found}} =
               PageActions.media_add(plugin, ctx(user), movie_target(900_000_002))
    end
  end
end
