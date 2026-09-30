defmodule Mydia.Plugins.PageReadsTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures
  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Collections
  alias Mydia.Media.MediaRequest
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
        "data:read" => ["media_request", "download", "collection"]
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
end
