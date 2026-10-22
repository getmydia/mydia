defmodule MydiaWeb.ProfileLive.TimeDisplayTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  test "renders the date and time settings", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/profile")

    assert has_element?(view, "#time-display-form #time-zone-select")
    assert has_element?(view, "#clock-format-picker")
    assert has_element?(view, "#time-display-preview time[datetime]")
  end

  test "choosing a zone and a 24-hour clock persists and re-renders", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/profile")

    view
    |> form("#time-display-form", %{"time_zone" => "Europe/Rome"})
    |> render_change()

    view
    |> element("#clock-format-picker [phx-value-clock='24']")
    |> render_click()

    pref = Accounts.get_user_preference!(user)
    assert UserPreference.time_zone(pref) == "Europe/Rome"
    assert UserPreference.clock_format(pref) == "24"

    refute view |> element("#time-display-preview time") |> render() =~ ~r/[AP]M/
  end

  test "the empty option clears the override back to the server default", %{
    conn: conn,
    user: user
  } do
    {:ok, _} =
      user
      |> Accounts.get_user_preference!()
      |> Accounts.update_preference(%{"time_zone" => "Asia/Tokyo"})

    {:ok, view, _html} = live(conn, ~p"/profile")

    view
    |> form("#time-display-form", %{"time_zone" => ""})
    |> render_change()

    assert user |> Accounts.get_user_preference!() |> UserPreference.time_zone() == nil
  end
end
