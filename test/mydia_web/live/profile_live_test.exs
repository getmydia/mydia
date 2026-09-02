defmodule MydiaWeb.ProfileLiveTest do
  # async: false — connected LiveView under the Postgres sandbox (rows inserted
  # in the test must be visible to the mount process).
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)
    %{conn: conn, user: user}
  end

  test "renders the profile page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/profile")

    assert has_element?(view, "#profile-form")
  end

  test "links out to the dedicated Integrations page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/profile")

    # Integrations moved to /integrations; the profile page only points to it.
    assert has_element?(view, "#integrations-link[href='/integrations']")
  end

  test "the theme picker defaults to System with the other options unselected", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/profile")

    assert html =~ ~s(id="theme-picker")

    assert has_element?(
             view,
             "#theme-picker button[phx-value-theme='system'][aria-pressed='true']"
           )

    assert has_element?(
             view,
             "#theme-picker button[phx-value-theme='light'][aria-pressed='false']"
           )

    assert has_element?(
             view,
             "#theme-picker button[phx-value-theme='dark'][aria-pressed='false']"
           )
  end

  test "choosing Dark moves the selection, persists the preference, and pushes the client event",
       %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/profile")

    view
    |> element("#theme-picker button[phx-value-theme='dark']")
    |> render_click()

    # The selection itself is server-rendered from @theme, so a wrong param
    # name or a handle_event clause that stopped matching would leave System
    # selected instead of moving to Dark.
    assert has_element?(
             view,
             "#theme-picker button[phx-value-theme='dark'][aria-pressed='true']"
           )

    assert has_element?(
             view,
             "#theme-picker button[phx-value-theme='system'][aria-pressed='false']"
           )

    # Applying the theme to the page happens client-side (a JS hook flips
    # data-theme), which a server-rendered LiveView test cannot observe
    # directly. What IS observable end to end: the stored preference changed,
    # and the client got told to change it.
    assert user |> Accounts.get_user_preference!() |> UserPreference.theme() == "dark"
    assert_push_event(view, "theme_changed", %{theme: "dark"})
  end
end
