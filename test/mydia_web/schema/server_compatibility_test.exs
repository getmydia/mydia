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

  @instance_query """
  query {
    serverCompatibility {
      instanceId
    }
  }
  """

  describe "instanceId" do
    test "is null before remote access has ever been enabled", %{conn: conn} do
      conn = post(conn, "/api/graphql", %{"query" => @instance_query})

      assert %{"data" => %{"serverCompatibility" => %{"instanceId" => nil}}} =
               json_response(conn, 200)
    end

    test "is the remote access instance id once one exists", %{conn: conn} do
      {:ok, config} = Mydia.RemoteAccess.initialize_config()

      conn = post(conn, "/api/graphql", %{"query" => @instance_query})

      assert %{"data" => %{"serverCompatibility" => %{"instanceId" => id}}} =
               json_response(conn, 200)

      assert id == config.instance_id
    end
  end
end
