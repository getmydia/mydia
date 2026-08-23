defmodule MydiaWeb.RouteAuthorizationTest do
  @moduledoc """
  The route/role matrix, at the layer that can actually afford it.

  These assertions previously lived in `test/mydia_web/features/auth_test.exs`
  and ran in a real browser, where each one cost seconds. Nothing about
  "role X lands on or off URL Y" needs a browser: the redirect is decided by
  a plug and an on_mount hook, both reachable from ConnTest/LiveViewTest.

  Companion to `MydiaWeb.Live.UserAuthTest`, which covers the on_mount hooks
  directly. This file covers the concrete routes users actually hit.
  """

  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  # live_session :authenticated — guarded only by :ensure_authenticated
  @authenticated_routes ["/", "/movies", "/downloads", "/calendar"]

  # live_session :admin — guarded by {:ensure_role, :admin}
  @admin_live_routes ["/admin/config", "/admin/users", "/admin/requests"]

  describe "unauthenticated visitors" do
    for route <- @authenticated_routes do
      test "#{route} redirects to login", %{conn: conn} do
        # A user must exist, or SessionController.new/2 redirects to /setup
        # instead and the assertion below reads confusingly.
        _existing = user_fixture()

        assert {:error, {:redirect, redirect}} = live(conn, unquote(route))
        assert redirect.to == "/auth/login"
      end
    end

    for route <- @admin_live_routes do
      test "#{route} redirects to login rather than leaking its existence", %{conn: conn} do
        _existing = user_fixture()

        assert {:error, {:redirect, redirect}} = live(conn, unquote(route))
        assert redirect.to == "/auth/login"
      end
    end
  end

  describe "authenticated non-admin roles" do
    for role <- ["user", "readonly", "guest"] do
      test "a #{role} can reach the dashboard", %{conn: conn} do
        conn = log_in_user(conn, user_fixture(%{role: unquote(role)}))

        assert {:ok, _view, _html} = live(conn, "/")
      end

      for route <- @admin_live_routes do
        test "a #{role} is redirected away from #{route}", %{conn: conn} do
          conn = log_in_user(conn, user_fixture(%{role: unquote(role)}))

          assert {:error, {:redirect, redirect}} = live(conn, unquote(route))
          assert redirect.to == "/"
        end
      end
    end

    test "a user role can reach the non-admin protected pages", %{conn: conn} do
      conn = log_in_user(conn, user_fixture(%{role: "user"}))

      assert {:ok, _view, _html} = live(conn, "/movies")
      assert {:ok, _view, _html} = live(conn, "/downloads")
    end
  end

  describe "admins" do
    for route <- @authenticated_routes do
      test "an admin can reach #{route}", %{conn: conn} do
        conn = log_in_user(conn, admin_user_fixture())

        assert {:ok, _view, _html} = live(conn, unquote(route))
      end
    end

    for route <- @admin_live_routes do
      test "an admin can reach #{route}", %{conn: conn} do
        conn = log_in_user(conn, admin_user_fixture())

        assert {:ok, _view, _html} = live(conn, unquote(route))
      end
    end
  end

  # /admin and /admin/status are RedirectController actions behind the
  # :require_admin plug, not LiveViews. They need ConnTest, not live/2.
  describe "/admin controller redirects" do
    test "an admin is forwarded to the consolidated config page", %{conn: conn} do
      conn = log_in_user(conn, admin_user_fixture())

      conn = get(conn, "/admin")

      assert redirected_to(conn) == "/admin/config"
    end

    test "a non-admin is redirected away from /admin", %{conn: conn} do
      conn = log_in_user(conn, user_fixture(%{role: "user"}))

      conn = get(conn, "/admin")

      assert redirected_to(conn) == "/"
    end
  end
end
