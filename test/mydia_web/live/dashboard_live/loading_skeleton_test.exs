defmodule MydiaWeb.DashboardLive.LoadingSkeletonTest do
  @moduledoc """
  The two rails are separate assigns fed by separate handle_info messages and
  can resolve independently, so each is asserted on its own. A test that only
  checked "both gone after load" would pass with one skeleton wired to the
  other's assign.

  Dashboard has no disconnected-render test: mount/3 sets both loading flags to
  false when not connected, so only the first connected render shows them.
  """

  # async: false - the Postgres non-shared sandbox hides these rows from the
  # LiveView mount process otherwise.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers
  import MydiaWeb.AuthHelpers

  setup %{conn: conn} do
    # DashboardLive.Index unconditionally loads both trending rails on
    # connected mount (#530).
    warm_trending_cache(:movie, [])
    warm_trending_cache(:tv_show, [])

    %{conn: log_in_user(conn, user_fixture())}
  end

  test "both trending rails render a skeleton on the first connected render", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    doc = LazyHTML.from_document(html)

    refute doc |> LazyHTML.query("#trending-movies-skeleton") |> Enum.empty?()
    refute doc |> LazyHTML.query("#trending-tv-skeleton") |> Enum.empty?()
  end

  test "each skeleton uses the rail's own five-column grid", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    doc = LazyHTML.from_document(html)

    [movies_class] =
      doc |> LazyHTML.query("#trending-movies-skeleton") |> LazyHTML.attribute("class")

    [tv_class] = doc |> LazyHTML.query("#trending-tv-skeleton") |> LazyHTML.attribute("class")

    for class <- [movies_class, tv_class] do
      assert class =~ "grid-cols-2"
      assert class =~ "lg:grid-cols-5"
      assert class =~ "gap-3"
    end
  end

  test "both skeletons are gone once the rails settle", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#trending-movies-skeleton")
    refute has_element?(view, "#trending-tv-skeleton")
  end

  test "each skeleton renders as many placeholder cards as the LiveView's trending rail limit",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    doc = LazyHTML.from_document(html)

    movies_cards = doc |> LazyHTML.query("#trending-movies-skeleton div.card") |> Enum.count()
    tv_cards = doc |> LazyHTML.query("#trending-tv-skeleton div.card") |> Enum.count()

    # Asserted against the LiveView's own limit, not a literal, so a change to
    # @trending_rail_limit in index.ex cannot leave this test green while the
    # skeleton and the settled row count drift apart.
    limit = MydiaWeb.DashboardLive.Index.trending_rail_limit()

    assert movies_cards == limit
    assert tv_cards == limit
  end
end
