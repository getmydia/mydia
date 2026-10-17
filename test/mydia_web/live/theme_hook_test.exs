defmodule MydiaWeb.ThemeHookTest do
  # async: false: connected LiveView under the Postgres sandbox.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)
    %{conn: conn, user: user}
  end

  defp html_attr(html, name) do
    html |> LazyHTML.from_document() |> LazyHTML.query("html") |> LazyHTML.attribute(name)
  end

  defp set_prefs(user, delta) do
    {:ok, _} = user |> Accounts.get_user_preference!() |> Accounts.update_preference(delta)
  end

  describe "root layout" do
    test "a fixed mode renders data-theme on the server", %{conn: conn, user: user} do
      set_prefs(user, %{"theme" => "dark", "dark_theme" => "dracula"})
      html = conn |> get(~p"/") |> html_response(200)

      assert html_attr(html, "data-theme") == ["dracula"]
      assert html_attr(html, "data-color-scheme") == ["dark"]
      assert html_attr(html, "data-theme-mode") == ["dark"]
      assert html_attr(html, "data-theme-source") == ["user"]
    end

    test "system mode renders both slots and leaves data-theme to the browser",
         %{conn: conn, user: user} do
      set_prefs(user, %{"light_theme" => "nord", "dark_theme" => "mocha"})
      html = conn |> get(~p"/") |> html_response(200)

      assert html_attr(html, "data-theme") == []
      assert html_attr(html, "data-color-scheme") == []
      assert html_attr(html, "data-light-theme") == ["nord"]
      assert html_attr(html, "data-dark-theme") == ["mocha"]
    end
  end

  test "a logged-out page renders the defaults" do
    # The login form only renders once a user exists.
    _existing = Mydia.AccountsFixtures.user_fixture()
    html = build_conn() |> get("/auth/local/login") |> html_response(200)

    assert html_attr(html, "data-theme-source") == ["default"]
    assert html_attr(html, "data-light-theme") == ["mydia-light"]
    assert html_attr(html, "data-dark-theme") == ["mydia-dark"]
  end

  describe "theme events from any LiveView" do
    test "set_theme_mode persists and pushes the full selection", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/movies")

      render_hook(view, "set_theme_mode", %{"mode" => "light"})

      assert user |> Accounts.get_user_preference!() |> UserPreference.theme() == "light"

      assert_push_event(view, "theme_changed", %{
        mode: "light",
        light_theme: "mydia-light",
        dark_theme: "mydia-dark"
      })
    end

    test "the header toggle sets the mode", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/movies")

      view
      |> element("#theme-toggle button[phx-value-mode='dark']")
      |> render_click()

      assert user |> Accounts.get_user_preference!() |> UserPreference.theme() == "dark"
      assert_push_event(view, "theme_changed", %{mode: "dark"})
    end

    test "update_theme_slot stores the theme for that slot", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/movies")

      render_hook(view, "update_theme_slot", %{"slot" => "dark", "theme" => "dracula"})

      selection = user |> Accounts.get_user_preference!() |> UserPreference.theme_selection()
      assert selection.dark.id == "dracula"
      assert_push_event(view, "theme_changed", %{dark_theme: "dracula"})
    end

    test "an invalid theme is refused without changing anything", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/movies")

      render_hook(view, "update_theme_slot", %{"slot" => "light", "theme" => "dracula"})

      assert user |> Accounts.get_user_preference!() |> UserPreference.theme_selection() ==
               Mydia.Accounts.Themes.default_selection()

      refute_push_event(view, "theme_changed", %{})
    end
  end
end
