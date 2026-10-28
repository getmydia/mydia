defmodule Mydia.Plugins.ContractV18Test do
  # async: false: starts real pools under the app-wide PoolRegistry and points
  # the global metadata relay URL at a Bypass server.
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures

  alias Mydia.Plugins.Host
  alias Mydia.Plugins.HostFunctions
  alias Mydia.Plugins.PageReads
  alias Mydia.Plugins.Plugin
  alias Mydia.Plugins.Registry
  alias Mydia.RelayStubHelpers

  @fixtures Path.join([__DIR__, "..", "..", "support", "fixtures", "plugins"])
  @grants %{"surfaces:shelf" => [], "data:search" => []}

  defp start(slug, file) do
    {:ok, _} =
      Registry.register(slug, %Plugin{
        slug: slug,
        name: slug,
        enabled: true,
        granted_capabilities: @grants
      })

    bytes = File.read!(Path.join(@fixtures, file))
    {:ok, _} = Host.start_plugin(slug, bytes, imports: HostFunctions.imports_for(slug))

    on_exit(fn ->
      Host.stop_plugin(slug)
      Registry.unregister(slug)
    end)
  end

  defp fill(slug, user, shelf) do
    Host.call(slug, "fill-shelf", %{"shelf" => shelf, "limit" => 12, "config" => %{}},
      handler: :fill_shelf,
      acting_user_id: user.id,
      role: user.role
    )
  end

  defp stub_movies(bypass) do
    Bypass.stub(bypass, "GET", "/tmdb/movies/search", fn conn ->
      body = %{
        "results" => [
          %{"id" => 880_301, "title" => "Lantern Shoals", "vote_count" => 2785},
          %{"id" => 880_302, "title" => "Lantern Shoals"}
        ]
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  setup do
    {:ok, user: user_fixture(), bypass: RelayStubHelpers.point_relay_at_bypass()}
  end

  test "detects a 1.8 guest" do
    start("v18-detect", "shelf_fixture_v18.wasm")

    assert Host.contract_version("v18-detect") == :v18
    assert Host.typed_exports?("v18-detect")
  end

  test "a 1.8 guest's catalog hits carry the vote count", %{user: user, bypass: bypass} do
    stub_movies(bypass)
    start("v18-votes", "shelf_fixture_v18.wasm")

    assert {:ok, %{items: items}} = fill("v18-votes", user, "lantern shoals")

    assert Enum.map(items, & &1.reason) == ["Lantern Shoals/2785", "Lantern Shoals/none"]
  end

  test "search/3 keeps the 1.7 hit shape", %{user: user, bypass: bypass} do
    stub_movies(bypass)

    plugin = %Plugin{slug: "old", name: "Old", enabled: true, granted_capabilities: @grants}
    ctx = %{handler: :fill_shelf, acting_user_id: user.id, role: user.role, slug: "old"}
    req = %{kind: :catalog, query: "lantern shoals", "media-type": {:some, "movie"}, limit: :none}

    assert {:ok, [old | _]} = PageReads.search(plugin, ctx, req)
    refute Map.has_key?(old, :"vote-count")

    assert {:ok, [new | _]} = PageReads.search_with_votes(plugin, ctx, req)
    assert new."vote-count" == {:some, 2785}
  end

  test "a 1.7 guest still fills through the old search shape", %{user: user} do
    start("v17-still", "shelf_fixture_v17.wasm")

    assert Host.contract_version("v17-still") == :v17
    assert {:ok, %{items: []}} = fill("v17-still", user, "any")
  end

  test "only the 1.8 namespace serves the vote-count search" do
    imports =
      HostFunctions.imports_for("any").(%{
        slug: "any",
        instance_id: nil,
        invocation_id: "i",
        test_run: false,
        handler: :on_event,
        acting_user_id: nil,
        role: nil,
        session_id: nil
      })

    v18 = Map.fetch!(imports, "mydia:plugin/host@1.8.0")
    v17 = Map.fetch!(imports, "mydia:plugin/host@1.7.0")

    assert Map.keys(v18) == Map.keys(v17)
    refute Map.fetch!(v18, "search") == Map.fetch!(v17, "search")
  end
end
