defmodule MydiaWeb.Plugs.EnsureRoleTest do
  use MydiaWeb.ConnCase, async: true

  alias Mydia.Auth.Guardian
  alias MydiaWeb.Plugs.EnsureRole

  # EnsureRole's JSON-vs-HTML error branch keys off conn.path_info starting
  # with "api" (see MydiaWeb.Plugs.EnsureRole.get_format/1). A bare test conn
  # has empty path_info, which would route a denial through put_flash/redirect
  # instead -- fine functionally, but put_flash raises unless flash has been
  # fetched. Every real caller of :require_admin in the router is under
  # "/api/..." or "/admin/..."; this matches the API shape, which is also
  # what T-108's actual sink (/api/v1/config) uses.
  defp call(conn, required_roles) do
    conn
    |> Map.put(:path_info, ["api", "v1", "config"])
    |> EnsureRole.call(EnsureRole.init(required_roles))
  end

  describe "call/2 with a real session/API-key resource" do
    test "allows an admin through :admin", %{conn: conn} do
      admin = create_admin_user()
      conn = conn |> Guardian.Plug.put_current_resource(admin) |> call(:admin)

      refute conn.halted
    end

    test "rejects a plain user from :admin", %{conn: conn} do
      user = create_test_user()
      conn = conn |> Guardian.Plug.put_current_resource(user) |> call(:admin)

      assert conn.halted
      assert conn.status == 403
    end
  end

  describe "call/2 with a media-token-derived resource (T-108)" do
    # This is the regression test for the core of T-108: a media token is a
    # 24-hour, URL-exposed credential every paired device holds, minted with
    # no narrower permission tier in practice (see
    # Mydia.RemoteAccess.MediaToken). Guardian.Plug.current_resource/1 alone
    # cannot tell a media-token-derived resource apart from a real session's
    # -- both resolve to the same %User{} struct -- so without the
    # media_token_auth check, an admin's own paired device could satisfy
    # :require_admin and reach the full config-management API
    # (PUT/DELETE /api/v1/config/:key) using nothing but its media token.
    #
    # Proven to fail without the fix: reverting EnsureRole.call/2 to drop the
    # `!media_token_derived?(conn)` clause (leaving only
    # `user && has_required_role?(...)`) makes this test pass an admin
    # through even with `media_token_auth: true` set, since the plug never
    # looks at that assign. Confirmed by temporarily reverting during
    # development; router.ex no longer mounts MediaAuth on :api_auth, but
    # this plug-level test does not depend on that -- it calls EnsureRole
    # directly, the same way MediaAuth would leave the connection.
    test "refuses to grant :admin from an admin's media-token-derived resource", %{conn: conn} do
      admin = create_admin_user()

      conn =
        conn
        |> Guardian.Plug.put_current_resource(admin)
        |> Plug.Conn.assign(:media_token_auth, true)
        |> call(:admin)

      assert conn.halted
      assert conn.status == 403
    end

    test "still refuses a non-admin's media-token-derived resource from :admin", %{conn: conn} do
      user = create_test_user()

      conn =
        conn
        |> Guardian.Plug.put_current_resource(user)
        |> Plug.Conn.assign(:media_token_auth, true)
        |> call(:admin)

      assert conn.halted
      assert conn.status == 403
    end
  end
end
