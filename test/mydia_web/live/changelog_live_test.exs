defmodule MydiaWeb.ChangelogLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.Accounts
  alias Mydia.Changelog
  alias MydiaWeb.ChangelogLive

  setup %{conn: conn} do
    unique_id = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "clpage_#{unique_id}@example.com",
        username: "clpage_#{unique_id}",
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

  test "lists every bundled release", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/changelog")

    assert has_element?(view, "#changelog-entries")

    for entry <- Enum.take(Changelog.entries(), 5) do
      assert has_element?(view, "##{ChangelogLive.Index.entry_id(entry.version_string)}")
    end
  end

  test "marks the user as seen on visit", %{conn: conn, user: user} do
    {:ok, _} = Accounts.mark_changelog_seen(user, "0.2.0")

    {:ok, _view, _html} = live(conn, ~p"/changelog")

    assert Accounts.last_seen_changelog_version(user) == Changelog.latest()
  end

  test "hides the banner while on the page itself", %{conn: conn, user: user} do
    {:ok, _} = Accounts.mark_changelog_seen(user, "0.2.0")

    {:ok, view, _html} = live(conn, ~p"/changelog")

    refute has_element?(view, "#changelog-banner")
  end

  test "flags unread releases as new", %{conn: conn, user: user} do
    {:ok, _} = Accounts.mark_changelog_seen(user, "0.2.0")

    {:ok, view, _html} = live(conn, ~p"/changelog")

    latest_id = ChangelogLive.Index.entry_id(Changelog.latest())
    assert has_element?(view, "##{latest_id} .badge", "New")
  end

  test "requires authentication", %{} do
    conn = Phoenix.ConnTest.build_conn()
    assert {:error, {:redirect, %{to: "/auth/login"}}} = live(conn, ~p"/changelog")
  end
end
