defmodule MydiaWeb.DashboardLive.ShelfRailTest do
  use MydiaWeb.ConnCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.ShelfHelpers

  alias Mydia.Accounts
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
    assert has_element?(view, "#shelf-dismiss-#{item.id}")
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
    # dismiss buttons line up across the row.
    for item <- [with_reason, without_reason] do
      assert has_element?(view, "#{@rail}-item-#{item.id} p.line-clamp-3.h-\\[3\\.0938rem\\]")
    end

    # A stretched flex item gives the card's h-full a definite height to grow
    # into, which pushes the reason out of view.
    assert has_element?(view, "#{@rail} .overflow-x-auto.items-start")
  end

  test "Not interested removes the card and records the dismissal", %{conn: conn, user: user} do
    shelf = fresh_shelf(user)
    item = shelf_item_fixture(shelf)
    keep = shelf_item_fixture(shelf, %{position: 1, provider_id: 102, title: "The Long Thaw"})

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#shelf-dismiss-#{item.id}") |> render_click()

    refute has_element?(view, "#{@rail}-item-#{item.id}")
    assert has_element?(view, "#{@rail}-item-#{keep.id}")
    assert Repo.get(ShelfItem, item.id) == nil
    assert MapSet.size(Shelves.dismissed_keys(shelf)) == 1
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

  test "a dismiss for someone else's item changes nothing", %{conn: conn} do
    other = shelf_item_fixture(fresh_shelf(user_fixture()))
    {:ok, view, _html} = live(conn, ~p"/")

    render_click(view, "dismiss_shelf_item", %{"id" => other.id})

    assert Repo.get(ShelfItem, other.id)
  end
end
