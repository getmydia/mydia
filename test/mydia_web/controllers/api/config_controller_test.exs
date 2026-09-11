defmodule MydiaWeb.Api.ConfigControllerTest do
  use MydiaWeb.ConnCase, async: true

  setup do
    {_admin, token} = MydiaWeb.AuthHelpers.create_user_and_token(%{role: "admin"})
    {:ok, token: token}
  end

  describe "PUT /api/v1/config/:key" do
    test "accepts a value with no description", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put("/api/v1/config/media.auto_search_on_add", %{"value" => "false"})

      assert json_response(conn, 200)
    end

    # The row's category is what the admin settings page groups by, and the
    # admin toggle and the migration both file this key under remote_access.
    test "files a new remote_access.enabled row under remote_access", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put("/api/v1/config/remote_access.enabled", %{"value" => "false"})

      assert json_response(conn, 200)

      assert %{value: "false", category: :remote_access} =
               Mydia.Settings.get_config_setting_by_key("remote_access.enabled")
    end
  end
end
