defmodule MydiaWeb.PlayerDisabledTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  setup %{conn: conn} do
    start_supervised!(Mydia.Indexers.Health)
    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  describe "with the player off" do
    setup do
      disable_player()
    end

    for path <- [
          "/devices",
          "/admin/config/remote-access",
          "/admin/dashboard",
          "/admin/transcodes",
          "/play/movie/00000000-0000-0000-0000-000000000000"
        ] do
      test "#{path} redirects home with a flash", %{conn: conn} do
        assert {:error, {:redirect, %{to: "/", flash: flash}}} = live(conn, unquote(path))
        assert flash["error"] =~ "player is disabled"
      end
    end
  end

  describe "with the player on" do
    test "/devices mounts", %{conn: conn} do
      assert {:ok, _view, _html} = live(conn, "/devices")
    end
  end
end
