defmodule Mydia.Plugins.PageReadsTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures
  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Collections
  alias Mydia.Media.MediaRequest
  alias Mydia.Playback
  alias Mydia.Plugins.PageReads
  alias Mydia.Plugins.Plugin
  alias Mydia.Repo

  setup do
    plugin = %Plugin{
      slug: "helper",
      name: "Helper",
      enabled: true,
      granted_capabilities: %{
        "data:search" => [],
        "data:read" => ["media_request", "download", "collection", "watch_history"]
      }
    }

    user = user_fixture()
    {:ok, plugin: plugin, user: user, ctx: ctx_for(user)}
  end

  defp ctx_for(user) do
    %{
      handler: :on_http,
      acting_user_id: user.id,
      role: user.role,
      session_id: "s",
      invocation_id: "i",
      slug: "helper"
    }
  end

  defp request_for(user, title, media_item_id \\ nil) do
    Repo.insert!(%MediaRequest{
      requester_id: user.id,
      media_type: "movie",
      title: title,
      tmdb_id: System.unique_integer([:positive]),
      status: "pending",
      media_item_id: media_item_id
    })
  end

  # A freshly grabbed download (no client yet) counts as active without any
  # download client being configured.
  defp grabbing_download(attrs) do
    download_fixture(Map.merge(%{download_client: nil, download_client_id: nil}, attrs))
  end

  defp search_req(query),
    do: %{kind: :library, query: query, "media-type": :none, limit: :none}

  test "library search returns the user's visible items", %{plugin: plugin, ctx: ctx} do
    item = media_item_fixture(%{title: "Harbor of Glass", type: "movie"})

    assert {:ok, hits} = PageReads.search(plugin, ctx, search_req("Harbor"))

    assert Enum.any?(
             hits,
             &(&1[:"media-item-id"] == {:some, item.id} and &1.title == "Harbor of Glass")
           )
  end

  test "search requires data:search", %{ctx: ctx} do
    bare = %Plugin{slug: "helper", name: "H", enabled: true, granted_capabilities: %{}}

    assert {:error, %{type: :capability_denied}} = PageReads.search(bare, ctx, search_req("x"))
  end

  test "search outside on-http is denied", %{plugin: plugin} do
    assert {:error, %{type: :capability_denied}} =
             PageReads.search(plugin, %{handler: :on_event}, search_req("x"))
  end

  test "an oversized limit is capped", %{plugin: plugin, ctx: ctx} do
    for n <- 1..30, do: media_item_fixture(%{title: "Lantern Vale #{n}", type: "movie"})

    req = %{search_req("Lantern") | limit: {:some, 500}}
    assert {:ok, hits} = PageReads.search(plugin, ctx, req)
    assert length(hits) == 25
  end

  test "collection namespace lists only the user's collections", %{
    plugin: plugin,
    user: user,
    ctx: ctx
  } do
    {:ok, _} = Collections.create_collection(user, %{name: "Mine", type: "manual"})
    {:ok, _} = Collections.create_collection(user_fixture(), %{name: "Theirs", type: "manual"})

    assert {:ok, %{items: items}} = PageReads.list("collection", plugin, ctx)
    names = for {:collection, row} <- items, do: row.name
    assert "Mine" in names
    refute "Theirs" in names
  end

  test "media_request namespace lists only the user's requests", %{
    plugin: plugin,
    user: user,
    ctx: ctx
  } do
    request_for(user, "Copper Tide")
    request_for(user_fixture(), "Stranger Tide")

    assert {:ok, %{items: items}} = PageReads.list("media_request", plugin, ctx)
    assert ["Copper Tide"] = for({:"media-request", row} <- items, do: row.title)
  end

  test "download namespace lists only downloads for media the user requested", %{
    plugin: plugin,
    user: user,
    ctx: ctx
  } do
    mine = media_item_fixture(%{title: "Amber Weir", type: "movie"})
    theirs = media_item_fixture(%{title: "Slate Hollow", type: "movie"})
    request_for(user, "Amber Weir", mine.id)
    request_for(user_fixture(), "Slate Hollow", theirs.id)

    grabbing_download(%{media_item_id: mine.id, title: "amber.weir.1080p"})
    grabbing_download(%{media_item_id: theirs.id, title: "slate.hollow.1080p"})

    assert {:ok, %{items: items}} = PageReads.list("download", plugin, ctx)
    assert ["amber.weir.1080p"] = for({:download, row} <- items, do: row.title)
  end

  test "download namespace is empty when the user requested nothing", %{
    plugin: plugin,
    ctx: ctx
  } do
    grabbing_download(%{title: "orphan.release"})

    assert {:ok, %{items: []}} = PageReads.list("download", plugin, ctx)
  end

  test "an ungranted namespace is denied", %{ctx: ctx} do
    narrow = %Plugin{
      slug: "helper",
      name: "H",
      enabled: true,
      granted_capabilities: %{"data:read" => ["collection"]}
    }

    assert {:error, %{type: :capability_denied}} = PageReads.list("download", narrow, ctx)
  end

  test "reads outside on-http are denied", %{plugin: plugin} do
    assert {:error, %{type: :capability_denied}} =
             PageReads.list("collection", plugin, %{handler: :on_event})
  end

  describe "watch_history" do
    defp watch(user, content, days_ago, origin \\ "player") do
      {:ok, p} =
        Playback.save_progress(user.id, content, %{position_seconds: 60, duration_seconds: 600})

      at = DateTime.utc_now() |> DateTime.add(-days_ago * 86_400) |> DateTime.truncate(:second)

      p
      |> Ecto.Changeset.change(last_watched_at: at, last_write_origin: origin)
      |> Repo.update!()
    end

    defp history_req(opts \\ []) do
      %{
        namespace: "watch_history",
        cursor: :none,
        "updated-since": Keyword.get(opts, :since, :none),
        limit: Keyword.get(opts, :limit, :none)
      }
    end

    defp rows({:ok, %{items: items}}), do: for({:"playback-progress", r} <- items, do: r)

    test "lists the acting user's watches newest first", %{plugin: plugin, user: user, ctx: ctx} do
      older = media_item_fixture(%{type: "movie", title: "Ivory Causeway"})
      newer = media_item_fixture(%{type: "movie", title: "Umber Coast"})
      watch(user, [media_item_id: older.id], 4)
      watch(user, [media_item_id: newer.id], 1)
      watch(user_fixture(), [media_item_id: older.id], 0)

      assert [first, second] = rows(PageReads.watch_history(plugin, ctx, history_req(), true))
      assert first[:"media-item-id"] == {:some, newer.id}
      assert second[:"media-item-id"] == {:some, older.id}
      assert first[:"user-id"] == user.id
    end

    test "an episode row carries its show's id", %{plugin: plugin, user: user, ctx: ctx} do
      show = media_item_fixture(%{type: "tv_show", title: "Tin Lanterns"})
      ep = episode_fixture(%{media_item_id: show.id, season_number: 2, episode_number: 4})
      watch(user, [episode_id: ep.id], 1)

      assert [row] = rows(PageReads.watch_history(plugin, ctx, history_req(), true))
      assert row[:"item-type"] == "episode"
      assert row[:"media-item-id"] == {:some, show.id}
      assert row[:"episode-id"] == {:some, ep.id}
      assert row[:"season-number"] == {:some, 2}
      assert row[:"episode-number"] == {:some, 4}
    end

    test "origin is included only for 1.5 guests", %{plugin: plugin, user: user, ctx: ctx} do
      movie = media_item_fixture(%{type: "movie", title: "Velvet Quarry"})
      watch(user, [media_item_id: movie.id], 1, "plugin:plex:abc")

      assert [row] = rows(PageReads.watch_history(plugin, ctx, history_req(), true))
      assert row.origin == {:some, "plugin:plex:abc"}

      assert [old] = rows(PageReads.watch_history(plugin, ctx, history_req(), false))
      refute Map.has_key?(old, :origin)
    end

    test "updated-since filters by watch time", %{plugin: plugin, user: user, ctx: ctx} do
      a = media_item_fixture(%{type: "movie", title: "Frost Arcade"})
      b = media_item_fixture(%{type: "movie", title: "Rust Belt Choir"})
      watch(user, [media_item_id: a.id], 30)
      watch(user, [media_item_id: b.id], 2)

      since = DateTime.utc_now() |> DateTime.add(-7 * 86_400) |> DateTime.to_iso8601()
      req = history_req(since: {:some, since})

      assert [row] = rows(PageReads.watch_history(plugin, ctx, req, true))
      assert row[:"media-item-id"] == {:some, b.id}
    end

    test "a malformed updated-since is an invalid request", %{plugin: plugin, ctx: ctx} do
      req = history_req(since: {:some, "last tuesday"})

      assert {:error, %{type: :invalid_request}} =
               PageReads.watch_history(plugin, ctx, req, true)
    end

    test "limit is clamped to 50", %{plugin: plugin, user: user, ctx: ctx} do
      for n <- 1..55 do
        m = media_item_fixture(%{type: "movie", title: "Cinder Row #{n}"})
        watch(user, [media_item_id: m.id], rem(n, 20))
      end

      assert length(
               rows(PageReads.watch_history(plugin, ctx, history_req(limit: {:some, 500}), true))
             ) == 50

      assert length(rows(PageReads.watch_history(plugin, ctx, history_req(), true))) == 20
    end

    test "requires the watch_history grant", %{ctx: ctx} do
      narrow = %Plugin{
        slug: "helper",
        name: "H",
        enabled: true,
        granted_capabilities: %{"data:read" => ["collection"]}
      }

      assert {:error, %{type: :capability_denied}} =
               PageReads.watch_history(narrow, ctx, history_req(), true)
    end

    test "is refused outside on-http", %{plugin: plugin} do
      assert {:error, %{type: :capability_denied}} =
               PageReads.watch_history(plugin, %{handler: :on_event}, history_req(), true)
    end

    test "data_list routes the namespace to the page read", %{
      plugin: plugin,
      user: user,
      ctx: ctx
    } do
      movie = media_item_fixture(%{type: "movie", title: "Harrow Lights"})
      watch(user, [media_item_id: movie.id], 1)

      assert [row] =
               rows(
                 Mydia.Plugins.HostFunctions.data_list(plugin, history_req(),
                   ctx: ctx,
                   with_origin: true
                 )
               )

      assert row[:"media-item-id"] == {:some, movie.id}
    end
  end
end
