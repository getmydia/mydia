defmodule MydiaWeb.ChangelogBannerTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.Accounts
  alias Mydia.Changelog

  setup %{conn: conn} do
    unique_id = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "banner_#{unique_id}@example.com",
        username: "banner_#{unique_id}",
        password_hash: "$2b$12$test",
        role: "admin"
      })

    {:ok, token, _claims} = Mydia.Auth.Guardian.encode_and_sign(user)

    conn =
      conn
      |> init_test_session(%{})
      |> put_session(:guardian_default_token, token)
      |> put_req_header("authorization", "Bearer #{token}")

    %{conn: conn, user: user}
  end

  test "shows the banner to a user who is behind", %{conn: conn, user: user} do
    {:ok, _} = Accounts.mark_changelog_seen(user, "0.2.0")

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#changelog-banner")
    assert has_element?(view, "#changelog-banner", Changelog.latest())
  end

  test "shows no banner to a user who is current", %{conn: conn, user: user} do
    {:ok, _} = Accounts.mark_changelog_seen(user, Changelog.latest())

    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#changelog-banner")
  end

  test "adopts the newest version silently on first mount", %{conn: conn, user: user} do
    assert Accounts.last_seen_changelog_version(user) == nil

    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#changelog-banner")
    assert Accounts.last_seen_changelog_version(user) == Changelog.latest()
  end

  test "dismissing hides the banner and persists", %{conn: conn, user: user} do
    {:ok, _} = Accounts.mark_changelog_seen(user, "0.2.0")

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#changelog-banner")

    view |> element("#changelog-dismiss") |> render_click()

    refute has_element?(view, "#changelog-banner")
    assert Accounts.last_seen_changelog_version(user) == Changelog.latest()
  end

  test "the banner survives a remount until dismissed", %{conn: conn, user: user} do
    {:ok, _} = Accounts.mark_changelog_seen(user, "0.2.0")

    {:ok, first, _html} = live(conn, ~p"/")
    assert has_element?(first, "#changelog-banner")

    {:ok, second, _html} = live(conn, ~p"/downloads")
    assert has_element?(second, "#changelog-banner")
  end
end
