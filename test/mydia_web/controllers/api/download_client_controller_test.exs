defmodule MydiaWeb.Api.DownloadClientControllerTest do
  # async: false because start_supervised!(ClientHealth) needs database access
  use MydiaWeb.ConnCase, async: false

  # Need to start the ClientHealth GenServer for these tests since it's disabled in test config
  setup do
    # Start the health monitors for this test
    start_supervised!(Mydia.Downloads.ClientHealth)

    {_user, token} = create_user_and_token()
    client = create_test_download_client()

    {:ok, token: token, client: client}
  end

  describe "GET /api/v1/downloads/clients" do
    test "lists all download clients with health status", %{
      conn: conn,
      token: token,
      client: client
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/downloads/clients")

      response = json_response(conn, 200)
      assert is_list(response["data"])
      assert length(response["data"]) >= 1

      # Find our test client in the list
      test_client = Enum.find(response["data"], &(&1["id"] == client.id))
      assert test_client != nil
      assert test_client["name"] == client.name
      assert test_client["type"] == "transmission"
      assert test_client["enabled"] == true
      assert is_map(test_client["health"])
    end

    test "requires authentication", %{conn: conn} do
      conn = get(conn, "/api/v1/downloads/clients")

      # Should get 401 Unauthorized or redirect
      assert conn.status in [401, 302]
    end
  end

  describe "GET /api/v1/downloads/clients/:id" do
    test "returns client details with health status", %{conn: conn, token: token, client: client} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/downloads/clients/#{client.id}")

      response = json_response(conn, 200)
      assert response["data"]["id"] == client.id
      assert response["data"]["name"] == client.name
      assert response["data"]["type"] == "transmission"
      assert response["data"]["enabled"] == true
      assert response["data"]["host"] == "localhost"
      assert response["data"]["port"] == 9091
      assert is_map(response["data"]["health"])
    end

    test "returns 404 for non-existent client", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/downloads/clients/00000000-0000-0000-0000-000000000000")

      assert json_response(conn, 404)["error"] == "Download client not found"
    end

    test "requires authentication", %{conn: conn, client: client} do
      conn = get(conn, "/api/v1/downloads/clients/#{client.id}")

      # Should get 401 Unauthorized or redirect
      assert conn.status in [401, 302]
    end
  end

  describe "POST /api/v1/downloads/clients/:id/test" do
    test "tests client connection and returns health", %{conn: conn, token: token, client: client} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/downloads/clients/#{client.id}/test")

      response = json_response(conn, 200)
      assert is_map(response["data"])
      # Health check should include status
      assert Map.has_key?(response["data"], "status") or
               Map.has_key?(response["data"], :status)
    end

    test "returns 404 for non-existent client", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/downloads/clients/00000000-0000-0000-0000-000000000000/test")

      assert json_response(conn, 404)["error"] == "Download client not found"
    end

    test "requires authentication", %{conn: conn, client: client} do
      conn = post(conn, "/api/v1/downloads/clients/#{client.id}/test")

      # Should get 401 Unauthorized or redirect
      assert conn.status in [401, 302]
    end
  end

  describe "POST /api/v1/downloads/clients/refresh" do
    test "initiates health check refresh", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/downloads/clients/refresh")

      response = json_response(conn, 202)
      assert response["message"] == "Health check refresh initiated"
    end

    test "requires authentication", %{conn: conn} do
      conn = post(conn, "/api/v1/downloads/clients/refresh")

      # Should get 401 Unauthorized or redirect
      assert conn.status in [401, 302]
    end
  end
end
