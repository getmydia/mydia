defmodule MydiaWeb.Api.LibraryExportControllerTest do
  use MydiaWeb.ConnCase, async: true

  import Mydia.MediaFixtures

  alias Mydia.Accounts

  # A browser navigation sends this; the :api pipeline's accepts plug must let it through.
  @browser_accept "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

  setup do
    media_item_fixture(%{type: "movie", title: "Copper Sky", tmdb_id: 900_020})
    {admin, token} = MydiaWeb.AuthHelpers.create_user_and_token(%{role: "admin"})
    %{admin: admin, token: token}
  end

  defp authed(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("accept", @browser_accept)
  end

  test "defaults to a JSON attachment", %{conn: conn, token: token} do
    conn = conn |> authed(token) |> get(~p"/api/v1/library/export")

    assert conn.status == 200
    assert [ct] = get_resp_header(conn, "content-type")
    assert ct =~ "application/json"
    assert [cd] = get_resp_header(conn, "content-disposition")
    assert cd =~ ~r/^attachment; filename="mydia-library-\d{4}-\d{2}-\d{2}\.json"$/

    assert %{"format" => "mydia-library", "items" => [%{"title" => "Copper Sky"}]} =
             Jason.decode!(conn.resp_body)
  end

  test "serves CSV when asked", %{conn: conn, token: token} do
    conn = conn |> authed(token) |> get(~p"/api/v1/library/export?format=csv")

    assert conn.status == 200
    assert [ct] = get_resp_header(conn, "content-type")
    assert ct =~ "text/csv"
    assert [cd] = get_resp_header(conn, "content-disposition")
    assert cd =~ ~r/filename="mydia-library-\d{4}-\d{2}-\d{2}\.csv"$/
    assert conn.resp_body =~ "Copper Sky"
  end

  test "rejects an unknown format with 400", %{conn: conn, token: token} do
    conn = conn |> authed(token) |> get(~p"/api/v1/library/export?format=xml")
    assert %{"error" => _} = json_response(conn, 400)
  end

  test "accepts an admin API key", %{conn: conn, admin: admin} do
    {:ok, _record, plain_key} = Accounts.create_api_key(admin.id, %{name: "Export Key"})

    conn =
      conn
      |> put_req_header("x-api-key", plain_key)
      |> get(~p"/api/v1/library/export")

    assert conn.status == 200
  end

  test "forbids non-admins", %{conn: conn} do
    {_user, token} = MydiaWeb.AuthHelpers.create_user_and_token(%{role: "user"})
    conn = conn |> authed(token) |> get(~p"/api/v1/library/export")
    assert conn.status == 403
  end

  test "requires authentication", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/library/export")
    assert conn.status == 401
  end
end
