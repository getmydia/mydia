defmodule MydiaWeb.MediaAccessMissingScopeTest do
  use MydiaWeb.ConnCase, async: true

  import Mydia.MediaFixtures

  alias Mydia.Accounts.Scope
  alias MydiaWeb.MediaAccess
  alias MydiaWeb.MissingScopeProbe

  setup do
    MissingScopeProbe.attach()
  end

  test "a conn with no scope is denied and the gap is reported", %{conn: conn} do
    file = media_file_fixture()

    assert :denied = MediaAccess.authorize_media_file(conn, file)
    assert_received {:missing_scope, %{stacktrace: [_ | _]}}
  end

  test "an unrestricted scope is allowed and nothing is reported", %{conn: conn} do
    file = media_file_fixture()
    conn = Plug.Conn.assign(conn, :current_scope, Scope.unrestricted())

    assert :ok = MediaAccess.authorize_media_file(conn, file)
    refute_received {:missing_scope, _}
  end

  test "the scope-taking variant reports a nil scope too" do
    file = media_file_fixture()

    assert :denied = MediaAccess.authorize_media_file_for_scope(nil, file)
    assert_received {:missing_scope, _}
  end
end
