defmodule MydiaWeb.ProfileLive.LanguageTest do
  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  test "offers Automatic plus every available locale", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/profile")

    assert has_element?(view, "#interface-language-select option[value='auto']")
    assert has_element?(view, "#interface-language-select option[value='en']")
    assert has_element?(view, "#interface-language-select option[value='es']")
  end

  test "choosing a language persists it and reloads the page", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/profile")

    assert {:error, {:redirect, %{to: "/profile"}}} =
             view
             |> form("#interface-language-form", %{"interface_language" => "es"})
             |> render_change()

    assert user |> Accounts.get_user_preference!() |> UserPreference.interface_language() == "es"
  end
end
