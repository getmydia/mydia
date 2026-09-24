defmodule MydiaWeb.MediaLive.LibraryFilterTest do
  # async: false, because the Postgres non-shared sandbox hides these rows from
  # the LiveView mount process otherwise. Same reason as size_sort_test.exs.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures
  import Mydia.AccountsFixtures
  import MydiaWeb.AuthHelpers

  setup %{conn: conn} do
    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  test "hidden when only one library fits the page", %{conn: conn} do
    library_path_fixture(%{type: "movies"})
    library_path_fixture(%{type: "series"})

    {:ok, view, _html} = live(conn, ~p"/movies")

    refute has_element?(view, "#library-filter-select")
  end

  test "a series library is not offered on /movies", %{conn: conn} do
    a = library_path_fixture(%{type: "movies"})
    b = library_path_fixture(%{type: "movies"})
    s = library_path_fixture(%{type: "series"})

    {:ok, view, _html} = live(conn, ~p"/movies")

    assert has_element?(view, "#library-filter-select option[value='#{a.id}']")
    assert has_element?(view, "#library-filter-select option[value='#{b.id}']")
    refute has_element?(view, "#library-filter-select option[value='#{s.id}']")
  end

  test "choosing a library narrows the listing", %{conn: conn} do
    a = library_path_fixture(%{type: "movies"})
    b = library_path_fixture(%{type: "movies"})
    in_a = media_item_fixture(%{type: "movie", title: "Glasswing"})
    media_file_fixture(%{media_item_id: in_a.id, library_path_id: a.id})
    in_b = media_item_fixture(%{type: "movie", title: "Moth Harbour"})
    media_file_fixture(%{media_item_id: in_b.id, library_path_id: b.id})

    {:ok, view, _html} = live(conn, ~p"/movies")

    view
    |> element("#library-filter-form")
    |> render_change(%{"library" => a.id})

    assert has_element?(view, "#media_items-#{in_a.id}")
    refute has_element?(view, "#media_items-#{in_b.id}")
  end

  test "an unknown library id is ignored", %{conn: conn} do
    a = library_path_fixture(%{type: "movies"})
    b = library_path_fixture(%{type: "movies"})
    in_a = media_item_fixture(%{type: "movie", title: "Glasswing"})
    media_file_fixture(%{media_item_id: in_a.id, library_path_id: a.id})
    in_b = media_item_fixture(%{type: "movie", title: "Moth Harbour"})
    media_file_fixture(%{media_item_id: in_b.id, library_path_id: b.id})

    {:ok, view, _html} = live(conn, ~p"/movies")

    view
    |> element("#library-filter-form")
    |> render_change(%{"library" => Ecto.UUID.generate()})

    assert has_element?(view, "#media_items-#{in_a.id}")
    assert has_element?(view, "#media_items-#{in_b.id}")
  end
end
