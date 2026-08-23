defmodule MydiaWeb.SessionControllerTest do
  @moduledoc """
  Login form and session behavior.

  Relocated from `test/mydia_web/features/auth_test.exs` and
  `smoke_test.exs`. None of this needs a browser: the form is a plain
  POST and the session is a cookie. Logging in *through the rendered form*
  is still covered in the browser by `MydiaWeb.Features.AuthTest`, which is
  where the JS can actually break.
  """

  use MydiaWeb.ConnCase, async: false

  import Mydia.AccountsFixtures

  describe "GET /auth/local/login" do
    test "renders the login form once a user exists", %{conn: conn} do
      _existing = user_fixture()

      conn = get(conn, "/auth/local/login")

      html = html_response(conn, 200)
      assert html =~ "user[username]"
      assert html =~ "user[password]"
    end

    test "redirects to first-time setup when no users exist", %{conn: conn} do
      # SessionController.new/2 sends visitors to /setup when the instance is
      # empty. Every browser test used to create a throwaway user to dodge
      # this; asserting it directly is cheaper and documents the behavior.
      conn = get(conn, "/auth/local/login")

      assert redirected_to(conn) == "/setup"
    end

    test "renders a non-empty page title", %{conn: conn} do
      _existing = user_fixture()

      conn = get(conn, "/auth/local/login")

      html = html_response(conn, 200)
      assert [title] = Regex.run(~r{<title[^>]*>([^<]*)</title>}, html, capture: :all_but_first)
      assert String.trim(title) != ""
    end
  end

  describe "POST /auth/local/login" do
    test "rejects an unknown username without redirecting", %{conn: conn} do
      _existing = user_fixture()

      conn =
        post(conn, "/auth/local/login", %{
          "user" => %{"username" => "no-such-user", "password" => "wrong-password"}
        })

      assert html_response(conn, 200) =~ "Invalid username or password"
    end

    test "rejects a wrong password for a real user", %{conn: conn} do
      user = user_fixture()

      conn =
        post(conn, "/auth/local/login", %{
          "user" => %{"username" => user.username, "password" => "definitely-not-the-password"}
        })

      assert html_response(conn, 200) =~ "Invalid username or password"
    end
  end

  describe "session persistence" do
    test "an authenticated session survives across requests", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())

      conn = get(conn, "/movies")
      assert html_response(conn, 200)

      conn = get(conn, "/downloads")
      assert html_response(conn, 200)

      conn = get(conn, "/")
      assert html_response(conn, 200)
    end

    test "an unauthenticated request to the dashboard is redirected", %{conn: conn} do
      _existing = user_fixture()

      conn = get(conn, "/")

      assert redirected_to(conn) =~ "/auth"
    end
  end
end
