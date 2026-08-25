defmodule MydiaWeb.MediaLive.Show.HeroPickerModalsTest do
  @moduledoc """
  The hero column's Quality Profile, Library and Collection rows all used to
  be anchored daisyUI dropdowns. They are now buttons that open page-level
  modals, because the hero column is `overflow-y-auto` (see
  `MydiaWeb.MediaLive.Show.Components.hero_section/1`), which clips an
  anchored `.dropdown-content` menu once it runs past the column's remaining
  headroom, exactly the failure mode issue #465 already fixed once for a
  different surface. Confirmed by measuring the real page over CDP, not
  assumed from the CSS alone.

  These tests exercise the round trip through the actual button element
  (rather than pushing the underlying event by name), so a typo in the
  `phx-click` wiring fails loudly.
  """

  # Connected LiveView tests must stay sync: the Postgres sandbox is only
  # shared with the mount process when the case is not async.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures
  import Mydia.CollectionsFixtures
  import MydiaWeb.AuthHelpers

  setup %{conn: conn} do
    admin = admin_user_fixture()
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  describe "quality profile modal" do
    test "the row is a button that opens the modal, and picking a profile closes it", %{
      conn: conn
    } do
      profile = quality_profile_fixture(%{name: "Profile #{System.unique_integer([:positive])}"})
      item = media_item_fixture(%{type: "movie", title: "Picker Movie", year: 2024})

      {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")

      refute has_element?(view, "#quality-profile-modal")

      view
      |> element("button[title='Click to change quality profile']")
      |> render_click()

      assert has_element?(view, "#quality-profile-modal")
      assert has_element?(view, "#quality-profile-modal", profile.name)

      view
      |> element(
        "#quality-profile-modal button[phx-click='update_quality_profile'][phx-value-profile-id='#{profile.id}']"
      )
      |> render_click()

      refute has_element?(view, "#quality-profile-modal")
      assert Mydia.Repo.get!(Mydia.Media.MediaItem, item.id).quality_profile_id == profile.id
    end

    test "Cancel closes the modal without changing anything", %{conn: conn} do
      item = media_item_fixture(%{type: "movie", title: "Cancel Movie", year: 2024})

      {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")

      view
      |> element("button[title='Click to change quality profile']")
      |> render_click()

      assert has_element?(view, "#quality-profile-modal")

      view
      |> element("#quality-profile-modal button", "Cancel")
      |> render_click()

      refute has_element?(view, "#quality-profile-modal")
      assert Mydia.Repo.get!(Mydia.Media.MediaItem, item.id).quality_profile_id == nil
    end
  end

  describe "add to collection modal" do
    test "the row is a button that opens the modal", %{conn: conn, admin: admin} do
      collection = collection_fixture(%{user: admin, name: "My Watchlist"})
      item = media_item_fixture(%{type: "movie", title: "Collectible Movie", year: 2024})

      {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")

      refute has_element?(view, "#add-to-collection-modal")

      view
      |> element("button[phx-click='open_add_to_collection_modal']")
      |> render_click()

      assert has_element?(view, "#add-to-collection-modal")
      assert has_element?(view, "#add-to-collection-modal", collection.name)
    end

    test "picking a collection adds the item and leaves the modal open", %{
      conn: conn,
      admin: admin
    } do
      collection = collection_fixture(%{user: admin, name: "My Watchlist"})
      item = media_item_fixture(%{type: "movie", title: "Collectible Movie 2", year: 2024})

      {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")

      view
      |> element("button[phx-click='open_add_to_collection_modal']")
      |> render_click()

      view
      |> element(
        "#add-to-collection-modal button[phx-click='add_to_collection'][phx-value-collection-id='#{collection.id}']"
      )
      |> render_click()

      # Deliberately stays open: see the regression-guard test below for why.
      assert has_element?(view, "#add-to-collection-modal")

      assert Mydia.Collections.collections_for_item(admin, item.id) |> Enum.map(& &1.id) == [
               collection.id
             ]
    end

    # The regression guard: CollectionEvents.load_collection_data/2 used to
    # unconditionally force show_add_to_collection_modal to false on every
    # call, which was dead weight under the old anchored dropdown (nothing
    # read that assign) but became live and load-bearing the moment the
    # dropdown became this modal. Left unfixed, the very first pick in a
    # session would close the picker, making it impossible to add one item to
    # more than one collection without reopening the modal between every
    # single pick.
    test "toggling membership in two collections in one sitting keeps the modal open between picks",
         %{conn: conn, admin: admin} do
      collection_a = collection_fixture(%{user: admin, name: "Collection A"})
      collection_b = collection_fixture(%{user: admin, name: "Collection B"})
      item = media_item_fixture(%{type: "movie", title: "Multi Collection Movie", year: 2024})

      {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")

      view
      |> element("button[phx-click='open_add_to_collection_modal']")
      |> render_click()

      view
      |> element(
        "#add-to-collection-modal button[phx-click='add_to_collection'][phx-value-collection-id='#{collection_a.id}']"
      )
      |> render_click()

      assert has_element?(view, "#add-to-collection-modal")

      view
      |> element(
        "#add-to-collection-modal button[phx-click='add_to_collection'][phx-value-collection-id='#{collection_b.id}']"
      )
      |> render_click()

      assert has_element?(view, "#add-to-collection-modal")

      assert Mydia.Collections.collections_for_item(admin, item.id)
             |> Enum.map(& &1.id)
             |> Enum.sort() == Enum.sort([collection_a.id, collection_b.id])

      # It does still close, just only from the explicit Close action.
      view
      |> element("#add-to-collection-modal button", "Close")
      |> render_click()

      refute has_element?(view, "#add-to-collection-modal")
    end

    test "before any manual collection exists, the picker still lists the auto-provisioned Favorites",
         %{conn: conn} do
      # Mydia.Collections gets-or-creates a Favorites system collection (type
      # "manual", is_system: true) the first time a user's favorite status is
      # checked, which mount/3 does unconditionally via
      # CollectionEvents.load_collection_data/2. So a brand new user who has
      # never created a collection still sees one option here, not the empty
      # state - that empty state only exists for
      # Modals.add_to_collection_modal/1's own render_component tests (see
      # modals_test.exs), never through this LiveView's mount flow.
      item = media_item_fixture(%{type: "movie", title: "No Collections Movie", year: 2024})

      {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")

      view
      |> element("button[phx-click='open_add_to_collection_modal']")
      |> render_click()

      assert has_element?(view, "#add-to-collection-modal", "Favorites")
      refute has_element?(view, "#add-to-collection-modal", "No collections yet")
    end
  end

  describe "target library modal" do
    test "the row is a button that opens the modal, and picking a library closes it", %{
      conn: conn
    } do
      library_path_fixture(%{type: "movies", path: "/tmp/hero-target-a"})
      library = library_path_fixture(%{type: "movies", path: "/tmp/hero-target-b"})
      item = media_item_fixture(%{type: "movie", title: "Target Library Movie", year: 2024})

      {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")

      refute has_element?(view, "#target-library-modal")

      view
      |> element("button[data-test='target-library']")
      |> render_click()

      assert has_element?(view, "#target-library-modal")
      assert has_element?(view, "#target-library-modal", "hero-target-b")

      view
      |> element(
        "#target-library-modal button[phx-click='update_target_library'][phx-value-library-path-id='#{library.id}']"
      )
      |> render_click()

      refute has_element?(view, "#target-library-modal")
      assert Mydia.Repo.get!(Mydia.Media.MediaItem, item.id).library_path_id == library.id
    end
  end
end
