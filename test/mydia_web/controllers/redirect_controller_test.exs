defmodule MydiaWeb.RedirectControllerTest do
  @moduledoc """
  The permanent redirects that keep admin bookmarks from before the flat
  `/admin/<slug>` URLs working.
  """

  use MydiaWeb.ConnCase, async: false

  import Mydia.AccountsFixtures

  describe "as an admin" do
    setup %{conn: conn} do
      %{conn: log_in_user(conn, admin_user_fixture())}
    end

    test "/admin moves permanently to Status", %{conn: conn} do
      assert conn |> get("/admin") |> redirected_to(301) == "/admin/status"
    end

    test "/admin/config moves permanently to Quality", %{conn: conn} do
      assert conn |> get("/admin/config") |> redirected_to(301) == "/admin/quality"
    end

    test "a slug query param on bare /admin/config does not act as a path", %{conn: conn} do
      assert conn |> get("/admin/config?slug[]=trash") |> redirected_to(301) == "/admin/quality"
    end

    for {tab, target} <- [
          {"clients", "/admin/clients"},
          {"indexers", "/admin/indexers"},
          {"quality", "/admin/quality"},
          {"library", "/admin/library-paths"},
          {"media_servers", "/admin/media-servers"},
          {"remote_access", "/admin/remote-access"},
          {"general", "/admin/settings"},
          {"not-a-tab", "/admin/quality"}
        ] do
      test "/admin/config?tab=#{tab} moves permanently to #{target}", %{conn: conn} do
        assert conn |> get("/admin/config", tab: unquote(tab)) |> redirected_to(301) ==
                 unquote(target)
      end
    end

    for {legacy, target} <- [
          {"/admin/config/trash", "/admin/trash"},
          {"/admin/config/status", "/admin/status"},
          {"/admin/config/library-paths", "/admin/library-paths"},
          {"/admin/config/api-keys", "/admin/api-keys"}
        ] do
      test "#{legacy} moves permanently to #{target}", %{conn: conn} do
        assert conn |> get(unquote(legacy)) |> redirected_to(301) == unquote(target)
      end
    end

    test "an /admin/config path that is not a registered page is a 404", %{conn: conn} do
      assert conn |> get("/admin/config/bogus") |> html_response(404)
      assert conn |> get("/admin/config/trash/extra") |> html_response(404)
    end
  end

  test "a non-admin is sent home before any legacy lookup", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())

    assert conn |> get("/admin/config/trash") |> redirected_to() == "/"
  end
end
