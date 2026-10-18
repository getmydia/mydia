defmodule Mydia.Plugins.ContractV17Test do
  # async: false: starts real pools under the app-wide PoolRegistry.
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures

  alias Mydia.Plugins.Host
  alias Mydia.Plugins.HostFunctions

  @fixtures Path.join([__DIR__, "..", "..", "support", "fixtures", "plugins"])

  defp start(slug, file) do
    bytes = File.read!(Path.join(@fixtures, file))
    {:ok, _} = Host.start_plugin(slug, bytes, imports: HostFunctions.imports_for(slug))
    on_exit(fn -> Host.stop_plugin(slug) end)
  end

  defp fill(slug, user, shelf, extra) do
    payload = Map.merge(%{"shelf" => shelf, "limit" => 12, "config" => %{}}, extra)

    Host.call(slug, "fill-shelf", payload,
      handler: :fill_shelf,
      acting_user_id: user.id,
      role: user.role
    )
  end

  defp entry(attrs) do
    Map.merge(
      %{
        media_type: :movie,
        tmdb_id: nil,
        tvdb_id: nil,
        title: "Untitled",
        year: nil,
        rating: :up,
        via: nil
      },
      attrs
    )
  end

  setup do
    {:ok, user: user_fixture()}
  end

  test "detects a 1.7 guest and still detects 1.6 and 1.5 ones" do
    start("v17-detect", "shelf_fixture_v17.wasm")
    start("v16-still", "shelf_fixture.wasm")
    start("v15-still", "host_v15_fixture.wasm")

    assert Host.contract_version("v17-detect") == :v17
    assert Host.contract_version("v16-still") == :v16
    assert Host.contract_version("v15-still") == :v15
    assert Host.typed_exports?("v17-detect")
  end

  test "a 1.7 guest receives the feedback and every rating round-trips", %{user: user} do
    start("v17-feedback", "shelf_fixture_v17.wasm")

    feedback = [
      entry(%{tmdb_id: 11, title: "The Salt Line", year: 2024, rating: :up, via: :seen}),
      entry(%{tmdb_id: 12, title: "Harbor Lights", rating: :up, via: :added}),
      entry(%{
        media_type: :tv_show,
        tvdb_id: 13,
        title: "Ember Tide",
        year: 2019,
        rating: :down
      })
    ]

    assert {:ok, %{items: items}} =
             fill("v17-feedback", user, "any", %{"feedback" => feedback})

    assert Enum.map(items, & &1.reason) == [
             "up/seen/The Salt Line/2024",
             "up/added/Harbor Lights/none",
             "down/none/Ember Tide/2019"
           ]

    assert [%{item: first}, %{item: second}, %{item: third}] = items
    assert first.tmdb_id == 11
    assert second.tmdb_id == 12
    assert third.media_type == "tv_show"
    assert third.tvdb_id == 13
  end

  test "a 1.7 guest with no feedback gets an empty list", %{user: user} do
    start("v17-empty", "shelf_fixture_v17.wasm")

    assert {:ok, %{items: []}} = fill("v17-empty", user, "any", %{})
    assert {:ok, %{items: []}} = fill("v17-empty", user, "any", %{"feedback" => []})
  end

  test "a 1.6 guest still fills when the payload carries feedback", %{user: user} do
    start("v16-feedback", "shelf_fixture.wasm")

    feedback = [entry(%{tmdb_id: 11, title: "The Salt Line", rating: :down})]

    assert {:ok, %{items: [first, _second, _third]}} =
             fill("v16-feedback", user, "fixed", %{"feedback" => feedback})

    assert first.item.tmdb_id == 101
  end

  test "the host publishes the 1.7, 1.6 and 1.5 namespaces with the same functions" do
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

    v17 = Map.fetch!(imports, "mydia:plugin/host@1.7.0")
    v16 = Map.fetch!(imports, "mydia:plugin/host@1.6.0")
    v15 = Map.fetch!(imports, "mydia:plugin/host@1.5.0")

    assert Map.keys(v17) == Map.keys(v16)
    assert Map.keys(v16) == Map.keys(v15)
  end
end
