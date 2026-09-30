defmodule MydiaWeb.PwaLayoutTest do
  @moduledoc """
  Markup the installed iOS app depends on. iOS reads these tags once at
  "Add to Home Screen" time, so a regression only shows on a fresh install.
  """
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  setup %{conn: conn} do
    conn = log_in_user(conn, user_fixture(%{role: "admin"}))
    {:ok, conn: conn}
  end

  test "root layout links the opaque 180px touch icon", %{conn: conn} do
    doc = conn |> get(~p"/calendar") |> html_response(200) |> LazyHTML.from_document()

    icon = LazyHTML.query(doc, ~s|link[rel="apple-touch-icon"]|)
    assert LazyHTML.attribute(icon, "href") == ["/images/icons/apple-touch-icon.png"]
    assert LazyHTML.attribute(icon, "sizes") == ["180x180"]
  end

  test "root layout paints the theme background before the stylesheet loads", %{conn: conn} do
    doc = conn |> get(~p"/calendar") |> html_response(200) |> LazyHTML.from_document()

    style = doc |> LazyHTML.query("head style#launch-background") |> LazyHTML.text()
    assert style =~ "#0f172a"
    assert style =~ ~s|[data-theme="mydia-light"]|
    assert style =~ "#f8fafc"
  end

  test "mobile header and drawer clear the iOS status bar", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/calendar")

    assert has_element?(view, "#mobile-header[class*='pt-[env(safe-area-inset-top']")
    assert has_element?(view, "#sidebar-brand[class*='pt-[calc(1rem+env(safe-area-inset-top']")
  end

  test "root layout mounts one install sheet outside the LiveView", %{conn: conn} do
    doc = conn |> get(~p"/calendar") |> html_response(200) |> LazyHTML.from_document()

    assert doc
           |> LazyHTML.query("body > pwa-install#pwa-install[use-local-storage]")
           |> Enum.count() == 1

    assert doc |> LazyHTML.query("[data-phx-session] pwa-install") |> Enum.count() == 0
  end

  test "account menu has a hidden Install app item driven by the hook", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/calendar")

    assert has_element?(
             view,
             ~s|li#user-menu-install.hidden[phx-hook="PwaInstallMenuItem"][phx-update="ignore"] button#user-menu-install-button|,
             "Install app"
           )
  end
end
