defmodule Mydia.Plugins.ShelfHostTest do
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Plugins
  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Host
  alias Mydia.Plugins.HostFunctions
  alias Mydia.Plugins.Plugin
  alias Mydia.Plugins.Registry
  alias Mydia.Settings

  @fixtures Path.join([__DIR__, "..", "..", "support", "fixtures", "plugins"])
  @slug "shelf-fixture"

  @grants %{
    "surfaces:shelf" => [],
    "data:search" => [],
    "data:read" => ["watch_history", "media_item"],
    "surfaces:write" => ["media:add"]
  }

  setup do
    {:ok, _} =
      Settings.create_plugin_config(%{
        slug: @slug,
        name: "Shelf Fixture",
        version: "0.0.0",
        source_url: "test",
        manifest: %{"slug" => @slug, "name" => "Shelf Fixture", "version" => "0.0.0"},
        settings: %{"greeting" => "hi"},
        granted_capabilities: %{},
        enabled: true
      })

    {:ok, _} =
      Registry.register(@slug, %Plugin{
        slug: @slug,
        name: "Shelf Fixture",
        enabled: true,
        granted_capabilities: @grants
      })

    bytes = File.read!(Path.join(@fixtures, "shelf_fixture.wasm"))
    {:ok, _} = Host.start_plugin(@slug, bytes, imports: HostFunctions.imports_for(@slug))

    on_exit(fn ->
      Host.stop_plugin(@slug)
      Registry.unregister(@slug)
    end)

    {:ok, user: user_fixture()}
  end

  defp fill(user, shelf, extra \\ %{}) do
    payload =
      Map.merge(%{"shelf" => shelf, "limit" => 12, "config" => %{"greeting" => "hi"}}, extra)

    Host.call(@slug, "fill-shelf", payload,
      handler: :fill_shelf,
      acting_user_id: user.id,
      role: user.role
    )
  end

  test "returns the guest's items as plain maps", %{user: user} do
    assert {:ok, %{items: [first, second, third]}} = fill(user, "fixed")

    assert first == %{
             item: %{media_type: "movie", tmdb_id: 101, tvdb_id: nil, imdb_id: nil},
             reason: "Because you finished Ember Tide"
           }

    assert second.item.media_type == "tv_show"
    assert second.reason == nil
    assert third.item.tmdb_id == 303
  end

  test "the request carries the host's user, exclude list, limit and config", %{user: user} do
    exclude = [
      %{media_type: :movie, tmdb_id: 7, tvdb_id: nil, imdb_id: nil},
      %{media_type: :tv_show, tmdb_id: nil, tvdb_id: 9, imdb_id: nil}
    ]

    assert {:ok, %{items: [item]}} = fill(user, "echo", %{"exclude" => exclude, "limit" => 24})

    assert item.item.tmdb_id == 24
    assert item.reason == ~s(#{user.id}|2|{"greeting":"hi"})
  end

  test "a user id in the payload cannot override the acting user", %{user: user} do
    other = user_fixture()

    assert {:ok, %{items: [item]}} = fill(user, "echo", %{"user_id" => other.id})
    assert String.starts_with?(item.reason, user.id <> "|")
  end

  test "library search runs as the acting user", %{user: user} do
    media_item_fixture(%{title: "Ember Tide", type: "movie"})

    assert {:ok, %{items: [item]}} = fill(user, "search")
    assert item.reason =~ "Ember Tide"
  end

  describe "reads run as the acting user, not the system" do
    defp recategorize(media_item, category) do
      Repo.update_all(from(m in Mydia.Media.MediaItem, where: m.id == ^media_item.id),
        set: [category: to_string(category)]
      )
    end

    defp watch(user, media_item) do
      {:ok, _} =
        Mydia.Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 60,
          duration_seconds: 600
        })
    end

    test "watch history counts only the acting user's rows", %{user: user} do
      one = media_item_fixture(%{type: "movie", title: "Ivory Causeway"})
      two = media_item_fixture(%{type: "movie", title: "Umber Coast"})
      three = media_item_fixture(%{type: "movie", title: "Slate Harbour"})
      other = user_fixture()

      watch(user, one)
      watch(user, two)
      watch(other, one)
      watch(other, two)
      watch(other, three)

      assert {:ok, %{items: [mine]}} = fill(user, "history")
      assert mine.reason == "2"

      assert {:ok, %{items: [theirs]}} = fill(other, "history")
      assert theirs.reason == "3"

      assert {:ok, %{items: [nobody]}} = fill(user_fixture(), "history")
      assert nobody.reason == "0"
    end

    test "search does not return a title outside the user's restriction", %{user: user} do
      media_item_fixture(%{type: "movie", title: "Ember Tide"}) |> recategorize(:movie)

      media_item_fixture(%{type: "movie", title: "Ember Lantern"})
      |> recategorize(:cartoon_movie)

      restricted = restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]})

      assert {:ok, %{items: [seen]}} = fill(restricted, "search")
      assert seen.reason =~ "Ember Lantern"
      refute seen.reason =~ "Ember Tide"

      # Without the restriction both come back, so the filter above is the cause.
      assert {:ok, %{items: [all]}} = fill(user, "search")
      assert all.reason =~ "Ember Lantern"
      assert all.reason =~ "Ember Tide"
    end
  end

  test "a write is refused during a fill", %{user: user} do
    assert {:error, %Error{type: :guest_error, message: message}} = fill(user, "write")
    assert message =~ "Denied"
    assert Mydia.Repo.aggregate(Mydia.Plugins.PendingWrite, :count) == 0
  end

  test "a guest error comes back as a guest error", %{user: user} do
    assert {:error, %Error{type: :guest_error, message: "boom"}} = fill(user, "fail")
  end

  test "a fill without an acting user is refused" do
    assert {:error, %Error{type: :invalid_request}} =
             Host.call(@slug, "fill-shelf", %{"shelf" => "fixed"}, handler: :fill_shelf)
  end

  test "a 1.5 guest cannot be asked to fill a shelf", %{user: user} do
    bytes = File.read!(Path.join(@fixtures, "host_v15_fixture.wasm"))

    {:ok, _} =
      Host.start_plugin("v15-no-shelf", bytes, imports: HostFunctions.imports_for("v15-no-shelf"))

    on_exit(fn -> Host.stop_plugin("v15-no-shelf") end)

    assert {:error, %Error{type: :unsupported}} =
             Host.call("v15-no-shelf", "fill-shelf", %{"shelf" => "fixed"},
               handler: :fill_shelf,
               acting_user_id: user.id
             )
  end

  test "invoke_fill_shelf injects the plugin's settings", %{user: user} do
    assert {:ok, %{items: [item]}} =
             Plugins.invoke_fill_shelf(@slug, "echo", user,
               exclude: [],
               limit: 5,
               now: 1_790_000_000
             )

    assert item.item.tmdb_id == 5
    assert item.reason == ~s(#{user.id}|0|{"greeting":"hi"})
  end
end
