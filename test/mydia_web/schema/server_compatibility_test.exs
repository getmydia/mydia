defmodule MydiaWeb.Schema.ServerCompatibilityTest do
  use MydiaWeb.ConnCase, async: true

  @query """
  query {
    serverCompatibility {
      version
      minPlayerVersion
      recommendedPlayerVersion
    }
  }
  """

  test "resolves without an authenticated user", %{conn: conn} do
    conn = post(conn, "/api/graphql", %{"query" => @query})

    assert %{"data" => %{"serverCompatibility" => compat}} = json_response(conn, 200)
    refute Map.has_key?(json_response(conn, 200), "errors")

    assert compat["minPlayerVersion"] == Mydia.Compatibility.min_player_version()

    assert compat["recommendedPlayerVersion"] ==
             Mydia.Compatibility.recommended_player_version()

    assert is_binary(compat["version"])
    assert compat["version"] != ""
  end
end
