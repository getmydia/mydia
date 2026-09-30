defmodule Mydia.Plugins.PageReadsCatalogTest do
  # Not async: the catalog search points the global metadata relay URL at a
  # Bypass server.
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures

  alias Mydia.Plugins.PageReads
  alias Mydia.Plugins.Plugin
  alias Mydia.RelayStubHelpers

  setup do
    plugin = %Plugin{
      slug: "helper",
      name: "Helper",
      enabled: true,
      granted_capabilities: %{"data:search" => []}
    }

    user = user_fixture()

    ctx = %{
      handler: :on_http,
      acting_user_id: user.id,
      role: user.role,
      session_id: "s",
      invocation_id: "i",
      slug: "helper"
    }

    {:ok, plugin: plugin, ctx: ctx, bypass: RelayStubHelpers.point_relay_at_bypass()}
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  defp catalog(query, type \\ :none, limit \\ :none),
    do: %{kind: :catalog, query: query, "media-type": type, limit: limit}

  test "a movie hit carries its tmdb id and no library id", %{
    plugin: plugin,
    ctx: ctx,
    bypass: bypass
  } do
    Bypass.stub(bypass, "GET", "/tmdb/movies/search", fn conn ->
      json(conn, 200, %{
        "results" => [
          %{
            "id" => 880_011,
            "title" => "Quiet Cartographer",
            "release_date" => "2027-05-01",
            "overview" => "Maps."
          }
        ]
      })
    end)

    assert {:ok, [hit]} =
             PageReads.search(plugin, ctx, catalog("quiet cartographer", {:some, "movie"}))

    assert hit.kind == :catalog
    assert hit."item-type" == "movie"
    assert hit.title == "Quiet Cartographer"
    assert hit."tmdb-id" == {:some, 880_011}
    assert hit."tvdb-id" == :none
    assert hit."media-item-id" == :none
    assert hit.overview == {:some, "Maps."}
  end

  test "a show hit carries its tvdb id", %{plugin: plugin, ctx: ctx, bypass: bypass} do
    Bypass.stub(bypass, "GET", "/tvdb/search", fn conn ->
      json(conn, 200, %{
        "data" => [%{"tvdb_id" => "770022", "name" => "Salt Line Nights", "year" => "2026"}]
      })
    end)

    assert {:ok, [hit]} =
             PageReads.search(plugin, ctx, catalog("salt line nights", {:some, "tv_show"}))

    assert hit."item-type" == "tv_show"
    assert hit."tvdb-id" == {:some, 770_022}
    assert hit."tmdb-id" == :none
  end

  test "results are cut to the limit", %{plugin: plugin, ctx: ctx, bypass: bypass} do
    Bypass.stub(bypass, "GET", "/tmdb/movies/search", fn conn ->
      results = for n <- 1..5, do: %{"id" => 880_100 + n, "title" => "Ember Row #{n}"}
      json(conn, 200, %{"results" => results})
    end)

    assert {:ok, hits} =
             PageReads.search(plugin, ctx, catalog("ember row", {:some, "movie"}, {:some, 2}))

    assert length(hits) == 2
  end

  test "a relay failure is an error, not an empty result", %{
    plugin: plugin,
    ctx: ctx,
    bypass: bypass
  } do
    Bypass.stub(bypass, "GET", "/tmdb/movies/search", fn conn -> json(conn, 400, %{}) end)

    assert {:error, %{type: :network_error}} =
             PageReads.search(plugin, ctx, catalog("relay down query", {:some, "movie"}))
  end

  test "one failing type still returns the other's hits", %{
    plugin: plugin,
    ctx: ctx,
    bypass: bypass
  } do
    Bypass.stub(bypass, "GET", "/tmdb/movies/search", fn conn ->
      json(conn, 200, %{"results" => [%{"id" => 880_201, "title" => "Half Lit Harbor"}]})
    end)

    Bypass.stub(bypass, "GET", "/tvdb/search", fn conn -> json(conn, 400, %{}) end)

    assert {:ok, [hit]} = PageReads.search(plugin, ctx, catalog("half lit harbor"))
    assert hit."tmdb-id" == {:some, 880_201}
  end

  test "a blank query never reaches the relay", %{plugin: plugin, ctx: ctx} do
    assert {:ok, []} = PageReads.search(plugin, ctx, catalog("   "))
  end
end
