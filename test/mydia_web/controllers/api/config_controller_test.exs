defmodule MydiaWeb.Api.ConfigControllerTest do
  use MydiaWeb.ConnCase, async: true

  setup do
    # Regular user token
    {_user, user_token} = create_user_and_token()
    # Admin user token
    {_admin, admin_token} = create_user_and_token(%{role: "admin"})

    {:ok, user_token: user_token, admin_token: admin_token}
  end

  describe "GET /api/v1/config" do
    test "returns all configuration settings for admin", %{conn: conn, admin_token: admin_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{admin_token}")
        |> get("/api/v1/config")

      response = json_response(conn, 200)
      assert is_list(response["data"])
      # Should have some settings
      assert length(response["data"]) > 0

      # Each setting should have expected keys
      first_setting = hd(response["data"])
      assert Map.has_key?(first_setting, "key")
      assert Map.has_key?(first_setting, "value")
      assert Map.has_key?(first_setting, "source")
    end

    test "rejects non-admin users", %{conn: conn, user_token: user_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{user_token}")
        |> get("/api/v1/config")

      # Should get 403 Forbidden (non-admin users are not allowed)
      assert conn.status == 403
    end

    test "requires authentication", %{conn: conn} do
      conn = get(conn, "/api/v1/config")

      # Should get 401 Unauthorized or redirect
      assert conn.status in [401, 302]
    end
  end

  describe "GET /api/v1/config/:key" do
    test "returns specific configuration setting for admin", %{
      conn: conn,
      admin_token: admin_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{admin_token}")
        |> get("/api/v1/config/server.port")

      response = json_response(conn, 200)
      assert response["data"]["key"] == "server.port"
      assert Map.has_key?(response["data"], "value")
      assert Map.has_key?(response["data"], "source")
    end

    test "rejects non-admin users", %{conn: conn, user_token: user_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{user_token}")
        |> get("/api/v1/config/server.port")

      # Should get 403 Forbidden
      assert conn.status == 403
    end

    test "requires authentication", %{conn: conn} do
      conn = get(conn, "/api/v1/config/server.port")

      # Should get 401 Unauthorized or redirect
      assert conn.status in [401, 302]
    end
  end

  describe "PUT /api/v1/config/:key" do
    test "updates configuration setting for admin", %{conn: conn, admin_token: admin_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{admin_token}")
        |> put_req_header("content-type", "application/json")
        |> put("/api/v1/config/general.test_setting", %{
          value: "test_value",
          description: "A test setting"
        })

      response = json_response(conn, 200)
      assert response["message"] =~ "successfully"
    end

    test "returns 422 for missing value", %{conn: conn, admin_token: admin_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{admin_token}")
        |> put_req_header("content-type", "application/json")
        |> put("/api/v1/config/general.test_setting", %{})

      assert json_response(conn, 422)["error"] == "Validation failed"
    end

    test "rejects non-admin users", %{conn: conn, user_token: user_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{user_token}")
        |> put_req_header("content-type", "application/json")
        |> put("/api/v1/config/general.test_setting", %{value: "test"})

      # Should get 403 Forbidden
      assert conn.status == 403
    end

    test "requires authentication", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put("/api/v1/config/general.test_setting", %{value: "test"})

      # Should get 401 Unauthorized or redirect
      assert conn.status in [401, 302]
    end
  end

  describe "DELETE /api/v1/config/:key" do
    test "deletes database override for admin", %{conn: conn, admin_token: admin_token} do
      # First create a setting
      conn
      |> put_req_header("authorization", "Bearer #{admin_token}")
      |> put_req_header("content-type", "application/json")
      |> put("/api/v1/config/general.delete_test_setting", %{
        value: "temp_value"
      })

      # Now delete it
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{admin_token}")
        |> delete("/api/v1/config/general.delete_test_setting")

      response = json_response(conn, 200)
      assert response["message"] =~ "removed"
      assert response["key"] == "general.delete_test_setting"
    end

    test "returns 404 for non-existent setting", %{conn: conn, admin_token: admin_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{admin_token}")
        |> delete("/api/v1/config/nonexistent.setting.key.xyz")

      assert json_response(conn, 404)["error"] =~ "No database override"
    end

    test "rejects non-admin users", %{conn: conn, user_token: user_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{user_token}")
        |> delete("/api/v1/config/general.some_setting")

      # Should get 403 Forbidden
      assert conn.status == 403
    end

    test "requires authentication", %{conn: conn} do
      conn = delete(conn, "/api/v1/config/general.some_setting")

      # Should get 401 Unauthorized or redirect
      assert conn.status in [401, 302]
    end
  end

  describe "POST /api/v1/config/test-connection" do
    test "returns not implemented status for admin", %{conn: conn, admin_token: admin_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{admin_token}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/config/test-connection", %{type: "download_client", id: "some-id"})

      # This endpoint is not yet implemented
      response = json_response(conn, 501)
      assert response["error"] =~ "not yet implemented"
    end

    test "rejects non-admin users", %{conn: conn, user_token: user_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{user_token}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/config/test-connection", %{type: "download_client", id: "some-id"})

      # Should get 403 Forbidden
      assert conn.status == 403
    end

    test "requires authentication", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/config/test-connection", %{})

      # Should get 401 Unauthorized or redirect
      assert conn.status in [401, 302]
    end
  end
end
