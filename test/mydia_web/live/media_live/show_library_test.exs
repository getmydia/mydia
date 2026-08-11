defmodule MydiaWeb.MediaLive.ShowLibraryTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.SettingsFixtures
  import Mydia.MediaFixtures

  setup %{conn: conn} do
    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  test "shows the resolved library and its reason", %{conn: conn} do
    library = library_path_fixture(%{type: "movies"})
    {:ok, library} = Mydia.Settings.set_default_library(library, :movies)
    item = media_item_fixture(%{type: "movie", title: "Shown Movie", year: 2024})

    {:ok, view, _html} = live(conn, ~p"/movies/#{item.id}")

    assert has_element?(view, "[data-test='target-library']")
    assert render(view) =~ Path.basename(library.path)
    assert render(view) =~ "library default"
  end

  test "changing the library writes library_path_id", %{conn: conn} do
    _first = library_path_fixture(%{type: "movies", path: "/tmp/aaa-first"})
    second = library_path_fixture(%{type: "movies", path: "/tmp/zzz-second"})
    item = media_item_fixture(%{type: "movie", title: "Retargeted", year: 2024})

    {:ok, view, _html} = live(conn, ~p"/movies/#{item.id}")

    render_click(view, "update_target_library", %{"library-path-id" => to_string(second.id)})

    assert Mydia.Repo.get!(Mydia.Media.MediaItem, item.id).library_path_id == second.id
  end

  test "clearing the library returns the item to automatic resolution", %{conn: conn} do
    library = library_path_fixture(%{type: "movies"})
    _other = library_path_fixture(%{type: "movies"})

    item =
      media_item_fixture(%{
        type: "movie",
        title: "Cleared",
        year: 2024,
        library_path_id: library.id
      })

    {:ok, view, _html} = live(conn, ~p"/movies/#{item.id}")

    render_click(view, "update_target_library", %{"library-path-id" => ""})

    assert Mydia.Repo.get!(Mydia.Media.MediaItem, item.id).library_path_id == nil
  end
end
