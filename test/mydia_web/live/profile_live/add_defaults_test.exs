defmodule MydiaWeb.ProfileLive.AddDefaultsTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference

  setup %{conn: conn} do
    user = user_fixture(%{role: "admin"})
    %{conn: log_in_user(conn, user), user: user}
  end

  test "renders the add-defaults form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/profile")

    assert has_element?(view, "#profile-add-defaults-form")
    assert has_element?(view, "#profile-add-defaults-form.space-y-4")
    assert has_element?(view, "#profile-add-defaults-form label.block")

    assert has_element?(
             view,
             "#profile-add-defaults-form select.w-full[name='add_movie_library_path_id']"
           )

    assert has_element?(view, "#profile-add-defaults-form label span.label", "Movie library")
    refute has_element?(view, "#profile-add-defaults-form .form-control")
    refute has_element?(view, "#profile-add-defaults-form .label-text")
  end

  test "saving a season monitoring override persists it", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/profile")

    view
    |> form("#profile-add-defaults-form", %{"add_season_monitoring" => "first"})
    |> render_change()

    pref = Accounts.get_user_preference!(user)
    assert UserPreference.add_season_monitoring(pref) == "first"
  end

  test "an empty selection clears the override back to inherit", %{conn: conn, user: user} do
    pref = Accounts.get_user_preference!(user)

    {:ok, _} =
      Accounts.update_preference(pref, %{"preferences" => %{"add_season_monitoring" => "first"}})

    {:ok, view, _html} = live(conn, ~p"/profile")

    view
    |> form("#profile-add-defaults-form", %{"add_season_monitoring" => ""})
    |> render_change()

    pref = Accounts.get_user_preference!(user)
    assert UserPreference.add_season_monitoring(pref) == nil
  end

  test "saving monitored-on-add as true persists true, not a falsy placeholder",
       %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/profile")

    view
    |> form("#profile-add-defaults-form", %{"add_monitored" => "true"})
    |> render_change()

    pref = Accounts.get_user_preference!(user)
    assert UserPreference.add_monitored(pref) == true
  end

  test "saving monitored-on-add as false persists false, not inherit", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/profile")

    view
    |> form("#profile-add-defaults-form", %{"add_monitored" => "false"})
    |> render_change()

    pref = Accounts.get_user_preference!(user)
    assert UserPreference.add_monitored(pref) == false
  end

  test "saving search-on-add as true persists true, not a falsy placeholder",
       %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/profile")

    view
    |> form("#profile-add-defaults-form", %{"add_search_on_add" => "true"})
    |> render_change()

    pref = Accounts.get_user_preference!(user)
    assert UserPreference.add_search_on_add(pref) == true
  end

  test "saving search-on-add as false persists false, not inherit", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/profile")

    view
    |> form("#profile-add-defaults-form", %{"add_search_on_add" => "false"})
    |> render_change()

    pref = Accounts.get_user_preference!(user)
    assert UserPreference.add_search_on_add(pref) == false
  end

  test "saving a movie library override persists the id, not the display text",
       %{conn: conn, user: user} do
    library = library_path_fixture(%{type: "movies"})

    {:ok, view, _html} = live(conn, ~p"/profile")

    view
    |> form("#profile-add-defaults-form", %{"add_movie_library_path_id" => library.id})
    |> render_change()

    pref = Accounts.get_user_preference!(user)
    assert UserPreference.add_library_path_id(pref, :movie) == library.id
  end
end
