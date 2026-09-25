defmodule MydiaWeb.Plugs.GridDensityCookieTest do
  use MydiaWeb.ConnCase, async: true

  alias MydiaWeb.Plugs.GridDensityCookie

  defp call(conn, session \\ %{}) do
    conn
    |> init_test_session(session)
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

  # The cookie is the source of truth. The session outlives it, so a cleared or
  # expired cookie must not leave a copied density winning on the next render.
  test "clears a stale session density when the cookie is gone", %{conn: conn} do
    conn = call(conn, %{grid_density: "dense"})

    assert get_session(conn, "grid_density") == nil
  end

  test "clears a stale session density when the cookie is invalid", %{conn: conn} do
    conn =
      conn
      |> put_req_cookie("mydia_grid_density", "tiny")
      |> call(%{grid_density: "dense"})

    assert get_session(conn, "grid_density") == nil
  end

  # Rewriting the session on every request would re-sign and resend the
  # session cookie on every page load for no change.
  test "does not touch the session when it already matches the cookie", %{conn: conn} do
    # init_test_session/2 already marks a seeded session as written, so compare
    # the conn before and after the plug rather than reading that flag.
    before =
      conn
      |> put_req_cookie("mydia_grid_density", "dense")
      |> init_test_session(%{grid_density: "dense"})
      |> fetch_cookies()

    assert GridDensityCookie.call(before, GridDensityCookie.init([])) == before
  end

  test "does not touch a session that never had a density", %{conn: conn} do
    refute call(conn).private[:plug_session_info]
  end
end
