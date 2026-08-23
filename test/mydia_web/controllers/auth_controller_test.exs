defmodule MydiaWeb.AuthControllerTest do
  use MydiaWeb.ConnCase

  alias Mydia.Auth.Guardian

  describe "GET /auth/logout" do
    test "ends the session: guardian_default_token cleared, current_resource nil afterwards", %{
      conn: conn
    } do
      user = create_test_user(%{password: "testpassword123"})

      conn = init_test_session(conn, %{})

      # Log in through the real controller flow (not a test shortcut), so the
      # session ends up in exactly the shape a browser session would.
      login_conn =
        post(conn, ~p"/auth/local/login", %{
          "user" => %{"username" => user.username, "password" => "testpassword123"}
        })

      assert redirected_to(login_conn) == "/"

      # Prove the session actually authenticates before logout, so a later
      # failure demonstrates logout revoked it rather than the login never
      # having worked in the first place.
      authed_conn = login_conn |> recycle() |> get(~p"/")
      assert %Mydia.Accounts.User{} = Guardian.Plug.current_resource(authed_conn)

      logout_conn = login_conn |> recycle() |> get(~p"/auth/logout")

      # This is the crux of T-010: router.ex previously declared the dynamic
      # "/:provider" route before the literal "/logout" route in the same
      # scope, so GET /auth/logout dispatched to AuthController.request/2
      # instead of AuthController.logout/2. request/2 also redirects to
      # "/auth/login" when OIDC isn't configured (the default), so a
      # same-path-only assertion would pass even under the bug. The
      # assertions below check that the session was actually torn down, not
      # just that the response landed on a login-shaped URL.
      assert redirected_to(logout_conn) == "/"
      assert get_session(logout_conn, :guardian_default_token) == nil
      assert get_session(logout_conn, :guardian_token) == nil
      assert Guardian.Plug.current_resource(logout_conn) == nil

      # And the session is unusable for a follow-up request, exactly as a
      # browser would make one after clicking "Logout".
      after_logout_conn = logout_conn |> recycle() |> get(~p"/")
      assert redirected_to(after_logout_conn) == ~p"/auth/login"
    end
  end
end
