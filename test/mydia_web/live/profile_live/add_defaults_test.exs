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
end
