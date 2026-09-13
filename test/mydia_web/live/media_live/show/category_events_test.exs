defmodule MydiaWeb.MediaLive.Show.CategoryEventsTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures

  alias Mydia.Media
  alias Mydia.Media.MediaItem
  alias Mydia.Repo

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)
    %{conn: conn, user: user}
  end

  test "saving a new category updates the badge and database", %{conn: conn} do
    item = media_item_fixture(%{type: "movie", title: "Cinder Lantern", year: 2024})

    {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")

    view |> element("button[phx-click='show_category_modal'].w-full") |> render_click()
    assert has_element?(view, "#category-override-form")

    view
    |> form("#category-override-form", %{
      "media_item" => %{"category" => "anime_movie", "category_override" => "false"}
    })
    |> render_submit()

    refute has_element?(view, "#category-override-form")
    assert render(view) =~ "Anime"
    assert Repo.get!(MediaItem, item.id).category == "anime_movie"
  end

  test "locking category persists override and shows pencil icon", %{conn: conn} do
    item = media_item_fixture(%{type: "movie", title: "Harbor Lights", year: 2024})

    {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")

    view |> element("button[phx-click='show_category_modal'].w-full") |> render_click()

    view
    |> form("#category-override-form", %{
      "media_item" => %{"category" => "cartoon_movie", "category_override" => "true"}
    })
    |> render_submit()

    updated = Repo.get!(MediaItem, item.id)
    assert updated.category == "cartoon_movie"
    assert updated.category_override == true
    assert render(view) =~ "Cartoon (Manual override)"
  end

  test "reset to auto clears override", %{conn: conn} do
    item = media_item_fixture(%{type: "movie", title: "Tidepool Academy", year: 2024})
    {:ok, locked} = Media.update_category(item, :cartoon_movie, override: true)

    {:ok, view, _html} = live(conn, ~p"/media/#{locked.id}")

    view |> element("button[phx-click='show_category_modal'].w-full") |> render_click()
    assert has_element?(view, "button", "Reset to Auto")

    view |> element("button", "Reset to Auto") |> render_click()

    updated = Repo.get!(MediaItem, item.id)
    assert updated.category_override == false
    refute has_element?(view, "#category-override-form")
  end
end
