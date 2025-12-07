defmodule MydiaWeb.Api.IndexerControllerTest do
  # async: false because start_supervised!(Indexers.Health) needs database access
  use MydiaWeb.ConnCase, async: false

  # Need to start the Health GenServer for these tests since it's disabled in test config
  setup do
    # Start the health monitors for this test
    start_supervised!(Mydia.Indexers.Health)

    {_user, token} = create_user_and_token()
    indexer = create_test_indexer()

    {:ok, token: token, indexer: indexer}
  end

  describe "GET /api/v1/indexers" do
    test "lists all indexers with health status", %{conn: conn, token: token, indexer: indexer} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/indexers")

      response = json_response(conn, 200)
      assert is_list(response["data"])
      assert length(response["data"]) >= 1

      # Find our test indexer in the list
      test_indexer = Enum.find(response["data"], &(&1["id"] == indexer.id))
      assert test_indexer != nil
      assert test_indexer["name"] == indexer.name
      assert test_indexer["type"] == "prowlarr"
      assert test_indexer["enabled"] == true
      assert is_map(test_indexer["health"])
    end

    test "requires authentication", %{conn: conn} do
      conn = get(conn, "/api/v1/indexers")

      # Should get 401 Unauthorized or redirect
      assert conn.status in [401, 302]
    end
  end

  describe "GET /api/v1/indexers/:id" do
    test "returns indexer details with health status", %{
      conn: conn,
      token: token,
      indexer: indexer
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/indexers/#{indexer.id}")

      response = json_response(conn, 200)
      assert response["data"]["id"] == indexer.id
      assert response["data"]["name"] == indexer.name
      assert response["data"]["type"] == "prowlarr"
      assert response["data"]["enabled"] == true
      assert response["data"]["base_url"] == "http://localhost:9696"
      # API key should be masked
      assert response["data"]["api_key"] == "***"
      assert is_map(response["data"]["health"])
      assert is_map(response["data"]["rate_limit_stats"])
    end

    test "returns 404 for non-existent indexer", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/indexers/00000000-0000-0000-0000-000000000000")

      assert json_response(conn, 404)["error"] == "Indexer not found"
    end

    test "requires authentication", %{conn: conn, indexer: indexer} do
      conn = get(conn, "/api/v1/indexers/#{indexer.id}")

      # Should get 401 Unauthorized or redirect
      assert conn.status in [401, 302]
    end
  end

  describe "POST /api/v1/indexers/:id/test" do
    test "tests indexer connection and returns health", %{
      conn: conn,
      token: token,
      indexer: indexer
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/indexers/#{indexer.id}/test")

      response = json_response(conn, 200)
      assert is_map(response["data"])
      # Health check should include status
      assert Map.has_key?(response["data"], "status") or
               Map.has_key?(response["data"], :status)
    end

    test "returns 404 for non-existent indexer", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/indexers/00000000-0000-0000-0000-000000000000/test")

      assert json_response(conn, 404)["error"] == "Indexer not found"
    end

    test "requires authentication", %{conn: conn, indexer: indexer} do
      conn = post(conn, "/api/v1/indexers/#{indexer.id}/test")

      # Should get 401 Unauthorized or redirect
      assert conn.status in [401, 302]
    end
  end

  describe "POST /api/v1/indexers/refresh" do
    test "initiates health check refresh", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/indexers/refresh")

      response = json_response(conn, 202)
      assert response["message"] == "Health check refresh initiated"
    end

    test "requires authentication", %{conn: conn} do
      conn = post(conn, "/api/v1/indexers/refresh")

      # Should get 401 Unauthorized or redirect
      assert conn.status in [401, 302]
    end
  end

  describe "POST /api/v1/indexers/:id/reset-failures" do
    test "resets failure counter for indexer", %{conn: conn, token: token, indexer: indexer} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/indexers/#{indexer.id}/reset-failures")

      response = json_response(conn, 200)
      assert response["message"] == "Failure counter reset successfully"
    end

    test "returns 404 for non-existent indexer", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/indexers/00000000-0000-0000-0000-000000000000/reset-failures")

      assert json_response(conn, 404)["error"] == "Indexer not found"
    end

    test "requires authentication", %{conn: conn, indexer: indexer} do
      conn = post(conn, "/api/v1/indexers/#{indexer.id}/reset-failures")

      # Should get 401 Unauthorized or redirect
      assert conn.status in [401, 302]
    end
  end
end
