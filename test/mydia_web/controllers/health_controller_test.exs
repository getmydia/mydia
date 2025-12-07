defmodule MydiaWeb.HealthControllerTest do
  use MydiaWeb.ConnCase

  describe "GET /health" do
    test "returns health status with expected fields", %{conn: conn} do
      conn = get(conn, ~p"/health")
      response = json_response(conn, 200)

      assert response["status"] == "ok"
      assert response["service"] == "mydia"
      assert is_binary(response["version"])
      assert is_boolean(response["dev_mode"])
      assert is_binary(response["timestamp"])
    end

    test "returns valid ISO8601 timestamp", %{conn: conn} do
      conn = get(conn, ~p"/health")
      response = json_response(conn, 200)

      assert {:ok, _datetime, _offset} = DateTime.from_iso8601(response["timestamp"])
    end
  end
end
