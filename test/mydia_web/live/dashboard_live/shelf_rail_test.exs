defmodule MydiaWeb.DashboardLive.ShelfRailTest do
  use MydiaWeb.ConnCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MetadataStub
  import Mydia.SettingsFixtures
  import Mydia.ShelfHelpers

  alias Mydia.Accounts
  alias Mydia.Accounts.Scope
  alias Mydia.MetadataStubProvider
  alias Mydia.Jobs.ShelfFill
  alias Mydia.Plugins.ShelfItem
  alias Mydia.Plugins.Shelves
  alias Mydia.Repo

  @rail "#shelf-shelf-test-picks"

  setup %{conn: conn} do
    register_shelf_plugin!()
    user = user_fixture(%{role: "user"})
    # Only this widget, so the page makes no trending lookups against the relay.
    {:ok, _} = Accounts.put_home_widgets(user, [:shelves])

    {:ok, conn: log_in_user(conn, user), user: user}
  end

  defp fresh_shelf(user) do
    now = DateTime.utc_now()
    shelf_fixture(user, filled_at: now, stale_at: DateTime.add(now, 3_600))
  end

  test "an empty shelf renders nothing and asks for a fill", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, @rail)
    assert [%Oban.Job{}] = all_enqueued(worker: ShelfFill)
    assert [%{stale?: true}] = Shelves.list_for(user, :home)
  end

  test "stored picks render with their reasons and no fill is requested", %{
    conn: conn,
    user: user
  } do
    shelf = fresh_shelf(user)

    item =
      shelf_item_fixture(shelf, %{
        title: "Ember Tide",
        reason: "Because you finished Glass Meridian"
      })

    shelf_item_fixture(shelf, %{
      position: 1,
      provider_id: 102,
      title: "The Long Thaw",
      reason: nil
    })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#{@rail} h2", "Picked for you")
    assert has_element?(view, "#{@rail}-item-#{item.id} p", "Because you finished Glass Meridian")
    assert has_element?(view, "#shelf-up-#{item.id}")
    assert has_element?(view, "#shelf-down-#{item.id}")
    refute has_element?(view, "#{@rail} button", "Not interested")
    assert all_enqueued(worker: ShelfFill) == []
  end

  test "every card reserves its reason slot and the row does not stretch cards", %{
    conn: conn,
    user: user
  } do
    shelf = fresh_shelf(user)
    with_reason = shelf_item_fixture(shelf, %{reason: "Because you finished Glass Meridian"})

    without_reason =
      shelf_item_fixture(shelf, %{
        position: 1,
        provider_id: 102,
        title: "The Long Thaw",
        reason: nil
      })

    {:ok, view, _html} = live(conn, ~p"/")

    # The reason slot is the same fixed box with or without text, so the
    # thumbs line up across the row.
    for item <- [with_reason, without_reason] do
      assert has_element?(view, "#{@rail}-item-#{item.id} p.line-clamp-3.h-\\[3\\.0938rem\\]")
    end

    # A stretched flex item gives the card's h-full a definite height to grow
    # into, which pushes the reason out of view.
    assert has_element?(view, "#{@rail} .overflow-x-auto.items-start")
  end

  test "thumbs down removes the card, records :down and offers Undo", %{conn: conn, user: user} do
    shelf = fresh_shelf(user)
    item = shelf_item_fixture(shelf)
    keep = shelf_item_fixture(shelf, %{position: 1, provider_id: 102, title: "The Long Thaw"})

    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#shelf-undo")
    view |> element("#shelf-down-#{item.id}") |> render_click()

    refute has_element?(view, "#{@rail}-item-#{item.id}")
    assert has_element?(view, "#{@rail}-item-#{keep.id}")
    assert Repo.get(ShelfItem, item.id) == nil
    assert [%{rating: :down}] = Shelves.feedback(shelf)
    assert has_element?(view, "#shelf-undo")
  end

  test "thumbs up removes the card and records :up via :seen", %{conn: conn, user: user} do
    shelf = fresh_shelf(user)
    item = shelf_item_fixture(shelf)

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#shelf-up-#{item.id}") |> render_click()

    refute has_element?(view, "#{@rail}-item-#{item.id}")
    assert [%{rating: :up, via: :seen}] = Shelves.feedback(shelf)
  end

  test "Undo brings the card back and clears the rating", %{conn: conn, user: user} do
    # A fill stamps the shelf and its items with one instant; undo restores
    # only a card from the current fill.
    now = DateTime.utc_now()
    shelf = shelf_fixture(user, filled_at: now, stale_at: DateTime.add(now, 3_600))
    item = shelf_item_fixture(shelf, %{inserted_at: now, updated_at: now})

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#shelf-down-#{item.id}") |> render_click()
    refute has_element?(view, "#{@rail}-item-#{item.id}")

    view |> element("#shelf-undo") |> render_click()

    assert has_element?(view, "#{@rail}-item-#{item.id}")
    refute has_element?(view, "#shelf-undo")
    assert Shelves.feedback(shelf) == []
  end

  test "an unknown rating is ignored", %{conn: conn, user: user} do
    shelf = fresh_shelf(user)
    item = shelf_item_fixture(shelf)

    {:ok, view, _html} = live(conn, ~p"/")
    render_click(view, "rate_shelf_item", %{"id" => item.id, "rating" => "sideways"})

    assert has_element?(view, "#{@rail}-item-#{item.id}")
    assert Shelves.feedback(shelf) == []
  end

  describe "details dialog" do
    setup :setup_metadata_stub

    test "opened from a shelf card it offers thumbs that rate and close", %{
      conn: conn,
      user: user
    } do
      shelf = fresh_shelf(user)

      item =
        shelf_item_fixture(shelf, %{provider_id: MetadataStubProvider.movie_tmdb_id()})

      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "show_details", %{
        "id" => to_string(item.provider_id),
        "type" => "movie"
      })

      assert has_element?(view, "#detail-shelf-up")
      assert has_element?(view, "#detail-shelf-down")

      view |> element("#detail-shelf-down") |> render_click()

      refute has_element?(view, "#detail-shelf-down")
      refute has_element?(view, "#{@rail}-item-#{item.id}")
      assert [%{rating: :down}] = Shelves.feedback(shelf)
    end

    test "opened for a title on no shelf it offers no thumbs", %{conn: conn, user: user} do
      shelf = fresh_shelf(user)
      shelf_item_fixture(shelf, %{provider_id: 999_001})

      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "show_details", %{
        "id" => to_string(MetadataStubProvider.movie_tmdb_id()),
        "type" => "movie"
      })

      refute has_element?(view, "#detail-shelf-up")
      refute has_element?(view, "#detail-shelf-down")
    end
  end

  describe "adding from a shelf" do
    setup :setup_metadata_stub

    setup %{conn: conn} do
      admin = user_fixture(%{role: "admin"})
      {:ok, _} = Accounts.put_home_widgets(admin, [:shelves])
      library_path_fixture(%{type: :movies})
      quality_profile_fixture()
      %{conn: log_in_user(conn, admin), admin: admin}
    end

    test "records a good pick and swaps the thumbs for the noted line", %{
      conn: conn,
      admin: admin
    } do
      shelf = fresh_shelf(admin)
      id = MetadataStubProvider.movie_tmdb_id()
      item = shelf_item_fixture(shelf, %{provider_id: id})
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "add_to_library", %{"ref" => "tmdb:#{id}", "media_type" => "movie"})
      wait_until(fn -> Shelves.feedback(shelf) != [] end)

      assert [%{rating: :up, via: :added}] = Shelves.feedback(shelf)
      assert has_element?(view, "#{@rail}-item-#{item.id}")
      assert has_element?(view, "#shelf-noted-#{item.id}")
      refute has_element?(view, "#shelf-up-#{item.id}")
    end

    test "a title on no shelf records nothing", %{conn: conn, admin: admin} do
      shelf = fresh_shelf(admin)
      other = shelf_item_fixture(shelf, %{provider_id: 999_001})
      {:ok, view, _html} = live(conn, ~p"/")
      id = MetadataStubProvider.movie_tmdb_id()

      render_click(view, "add_to_library", %{"ref" => "tmdb:#{id}", "media_type" => "movie"})
      wait_until(fn -> Mydia.Media.find_by_external_ids(Scope.unrestricted(), %{tmdb: id}) end)
      # The add's handle_info finished once a later round trip is answered.
      render(view)

      assert Shelves.feedback(shelf) == []
      assert has_element?(view, "#shelf-up-#{other.id}")
    end

    test "requesting a shelf title as a guest also records a good pick", %{conn: conn} do
      guest = user_fixture(%{role: "guest"})
      {:ok, _} = Accounts.put_home_widgets(guest, [:shelves])
      shelf = fresh_shelf(guest)
      id = MetadataStubProvider.movie_tmdb_id()
      item = shelf_item_fixture(shelf, %{provider_id: id})

      {:ok, view, _html} = live(log_in_user(build_conn(), guest), ~p"/")

      render_click(view, "request_media", %{"ref" => "tmdb:#{id}", "media_type" => "movie"})
      wait_until(fn -> Shelves.feedback(shelf) != [] end)

      assert [%{rating: :up, via: :added}] = Shelves.feedback(shelf)
      assert has_element?(view, "#shelf-noted-#{item.id}")
    end
  end

  defp wait_until(fun, retries \\ 200) do
    cond do
      fun.() -> :ok
      retries == 0 -> flunk("condition not met in time")
      true -> Process.sleep(10) && wait_until(fun, retries - 1)
    end
  end

  test "a finished fill swaps the rail in without a reload", %{conn: conn, user: user} do
    shelf = fresh_shelf(user)
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, @rail)

    item = shelf_item_fixture(shelf)
    Phoenix.PubSub.broadcast(Mydia.PubSub, Shelves.topic(user.id), {:shelf_updated, shelf.id})

    assert has_element?(view, "#{@rail}-item-#{item.id}")
  end

  test "the widget can be hidden from Customize Home", %{conn: conn, user: user} do
    shelf_item_fixture(fresh_shelf(user))
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, @rail)

    render_click(view, "open_edit_home")
    assert has_element?(view, "#edit-home-widget-shelves")

    render_click(view, "toggle_home_widget", %{"key" => "shelves"})
    refute has_element?(view, @rail)
  end

  test "a rating for someone else's item changes nothing", %{conn: conn} do
    other = shelf_item_fixture(fresh_shelf(user_fixture()))
    {:ok, view, _html} = live(conn, ~p"/")

    render_click(view, "rate_shelf_item", %{"id" => other.id, "rating" => "down"})

    assert Repo.get(ShelfItem, other.id)
  end
end
