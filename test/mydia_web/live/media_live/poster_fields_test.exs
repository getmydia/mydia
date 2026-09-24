defmodule MydiaWeb.MediaLive.PosterFieldsTest do
  @moduledoc """
  The library poster fields preference gates every optional element on a
  grid card (status badge, category, year, episode count, and the two badges
  added for issue #917: content rating and show status). This is the LiveView
  wiring test; `Mydia.Accounts.PosterFields` and `UserPreference.poster_fields/1`
  already have their own unit tests.
  """

  use MydiaWeb.ConnCase

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures
  import MydiaWeb.AuthHelpers

  alias Mydia.Accounts
  alias Mydia.Accounts.PosterFields
  alias Mydia.Accounts.UserPreference

  setup %{conn: conn} do
    admin = admin_user_fixture()
    conn = log_in_user(conn, admin)

    show =
      media_item_fixture(%{
        title: "The Quiet Harbor",
        type: "tv_show",
        year: 2019,
        metadata: %{
          "media_type" => "tv_show",
          "provider" => "tvdb",
          "provider_id" => "900001",
          "title" => "The Quiet Harbor",
          "status" => "Ended",
          "content_rating" => "TV-14"
        }
      })

    %{conn: conn, admin: admin, show: show}
  end

  test "content rating and show status badges are off by default", %{conn: conn, show: show} do
    {:ok, view, _html} = live(conn, ~p"/tv")

    refute has_element?(view, "#content-rating-#{show.id}")
    refute has_element?(view, "#show-status-#{show.id}")
    assert has_element?(view, "#poster-fields-form")
  end

  test "enabling fields renders both badges and persists the choice", %{
    conn: conn,
    admin: admin,
    show: show
  } do
    {:ok, view, _html} = live(conn, ~p"/tv")

    view
    |> form("#poster-fields-form", %{"fields" => ["year", "content_rating", "show_status"]})
    |> render_change()

    assert has_element?(view, "#content-rating-#{show.id}")
    assert has_element?(view, "#show-status-#{show.id}")

    assert admin
           |> Accounts.get_user_preference!()
           |> UserPreference.poster_fields() == [:year, :content_rating, :show_status]
  end

  test "disabling everything empties the stored list and hides the year", %{
    conn: conn,
    admin: admin,
    show: show
  } do
    {:ok, view, _html} = live(conn, ~p"/tv")

    view
    |> form("#poster-fields-form", %{"fields" => [""]})
    |> render_change()

    refute has_element?(view, "#card-year-#{show.id}")

    assert admin
           |> Accounts.get_user_preference!()
           |> UserPreference.poster_fields() == []
  end

  test "reset restores the default field set", %{conn: conn, admin: admin, show: show} do
    {:ok, view, _html} = live(conn, ~p"/tv")

    view
    |> form("#poster-fields-form", %{"fields" => ["year", "content_rating", "show_status"]})
    |> render_change()

    assert has_element?(view, "#content-rating-#{show.id}")

    view
    |> element("#poster-fields-reset")
    |> render_click()

    refute has_element?(view, "#content-rating-#{show.id}")
    refute has_element?(view, "#show-status-#{show.id}")

    assert admin
           |> Accounts.get_user_preference!()
           |> UserPreference.poster_fields() == PosterFields.default_keys()
  end

  test "a preference set before mount renders its badges immediately", %{
    conn: conn,
    admin: admin,
    show: show
  } do
    {:ok, _} =
      Accounts.update_preference(Accounts.get_user_preference!(admin), %{
        "poster_fields" => ["content_rating", "show_status"]
      })

    {:ok, view, _html} = live(conn, ~p"/tv")

    assert has_element?(view, "#content-rating-#{show.id}")
    assert has_element?(view, "#show-status-#{show.id}")
  end

  test "the list view hides the poster fields menu", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tv")

    render_click(view, "toggle_view", %{"mode" => "list"})

    refute has_element?(view, "#poster-fields-menu")
  end

  test "turning off playback and quality hides the poster badges container", %{conn: conn} do
    movie = media_item_fixture(%{title: "Silver Static", type: "movie", year: 2021})
    media_file_fixture(%{media_item_id: movie.id, resolution: "1080p"})

    {:ok, view, _html} = live(conn, ~p"/movies")

    assert has_element?(view, "#poster-badges-#{movie.id}")

    view
    |> form("#poster-fields-form", %{"fields" => ["status", "category", "year", "episodes"]})
    |> render_change()

    refute has_element?(view, "#poster-badges-#{movie.id}")
  end
end
