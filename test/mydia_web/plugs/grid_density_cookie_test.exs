defmodule MydiaWeb.Plugs.GridDensityCookieTest do
  use MydiaWeb.ConnCase, async: true

  alias MydiaWeb.Plugs.GridDensityCookie

  defp call(conn) do
    conn
    |> init_test_session(%{})
    |> GridDensityCookie.call(GridDensityCookie.init([]))
  end

  test "copies a valid cookie into the session", %{conn: conn} do
    conn = conn |> put_req_cookie("mydia_grid_density", "dense") |> call()

    assert get_session(conn, "grid_density") == "dense"
  end

  test "ignores an unknown value", %{conn: conn} do
    conn = conn |> put_req_cookie("mydia_grid_density", "tiny") |> call()

    assert get_session(conn, "grid_density") == nil
  end

  test "leaves the session alone when there is no cookie", %{conn: conn} do
    assert conn |> call() |> get_session("grid_density") == nil
  end
end
