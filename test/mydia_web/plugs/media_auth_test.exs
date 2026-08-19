defmodule MydiaWeb.Plugs.MediaAuthTest do
  use MydiaWeb.ConnCase, async: false

  alias Mydia.RemoteAccess.{MediaToken, RemoteDevice}
  alias Mydia.Accounts
  alias Mydia.Repo
  alias MydiaWeb.Plugs.MediaAuth

  describe "call/2 with valid token in Authorization header" do
    setup do
      user = create_user()
      device = create_device(user)
      {:ok, token, _claims} = MediaToken.create_token(device)

      %{user: user, device: device, token: token}
    end

    test "authenticates request and assigns device and user", %{
      conn: conn,
      token: token,
      device: device,
      user: user
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> MediaAuth.call([])

      refute conn.halted
      assert conn.assigns.media_device.id == device.id
      assert conn.assigns.media_user.id == user.id
      assert conn.assigns.media_token_claims["typ"] == "media_access"
    end

    test "allows request with sufficient permissions", %{conn: conn, device: device} do
      {:ok, token, _claims} = MediaToken.create_token(device, permissions: ["stream", "download"])

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> MediaAuth.call(permissions: ["stream"])

      refute conn.halted
      assert conn.assigns.media_device.id == device.id
    end
  end

  describe "call/2 with valid token in query parameter" do
    setup do
      user = create_user()
      device = create_device(user)
      {:ok, token, _claims} = MediaToken.create_token(device)

      %{user: user, device: device, token: token}
    end

    test "authenticates request via query param", %{
      conn: conn,
      token: token,
      device: device,
      user: user
    } do
      conn =
        conn
        |> Map.put(:query_params, %{"token" => token})
        |> MediaAuth.call([])

      refute conn.halted
      assert conn.assigns.media_device.id == device.id
      assert conn.assigns.media_user.id == user.id
    end

    test "prefers Authorization header over query param", %{conn: conn, device: device} do
      {:ok, header_token, _claims} = MediaToken.create_token(device)

      # Create a different token for query param
      device2 = create_device(create_user())
      {:ok, query_token, _claims} = MediaToken.create_token(device2)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{header_token}")
        |> Map.put(:query_params, %{"token" => query_token})
        |> MediaAuth.call([])

      refute conn.halted
      # Should use the header token (device)
      assert conn.assigns.media_device.id == device.id
    end
  end

  describe "call/2 with missing token" do
    test "passes through to allow other auth mechanisms", %{conn: conn} do
      # When no media token is provided, the plug passes through
      # to allow other authentication mechanisms (JWT, API key, etc.) to work
      conn = MediaAuth.call(conn, [])

      refute conn.halted
      # conn should be unchanged
      refute Map.has_key?(conn.assigns, :media_device)
      refute Map.has_key?(conn.assigns, :media_user)
    end
  end

  describe "call/2 with invalid token" do
    test "returns 401 for malformed token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid.token.here")
        |> MediaAuth.call([])

      assert conn.halted
      assert conn.status == 401

      response = Jason.decode!(conn.resp_body)
      assert response["error"] == "Unauthorized"
      assert response["message"] == "Invalid token"
    end

    test "returns 401 for empty token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer ")
        |> MediaAuth.call([])

      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "call/2 with expired token" do
    setup do
      # Clear token cache to ensure we don't hit stale cached entries
      Mydia.Media.TokenCache.clear()

      user = create_user()
      device = create_device(user)
      {:ok, token, _claims} = MediaToken.create_token(device, ttl: {1, :second})
      # Wait for token to expire (allowed_drift is 0 in test config,
      # 2000ms for reliable expiry through the TokenCache path)
      Process.sleep(2000)

      %{token: token}
    end

    test "returns 401 unauthorized", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> MediaAuth.call([])

      assert conn.halted
      assert conn.status == 401

      response = Jason.decode!(conn.resp_body)
      assert response["error"] == "Unauthorized"
      assert response["message"] == "Token expired"
    end
  end

  describe "call/2 with revoked device" do
    setup do
      user = create_user()
      device = create_device(user)
      {:ok, token, _claims} = MediaToken.create_token(device)

      # Revoke the device
      device
      |> RemoteDevice.revoke_changeset()
      |> Repo.update!()

      %{token: token}
    end

    test "returns 403 forbidden", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> MediaAuth.call([])

      assert conn.halted
      assert conn.status == 403

      response = Jason.decode!(conn.resp_body)
      assert response["error"] == "Forbidden"
      assert response["message"] == "Device access revoked"
    end
  end

  describe "call/2 with non-existent device" do
    setup do
      user = create_user()
      device = create_device(user)
      {:ok, token, _claims} = MediaToken.create_token(device)

      # Delete the device
      Mydia.Repo.delete!(device)

      %{token: token}
    end

    test "returns 401 unauthorized", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> MediaAuth.call([])

      assert conn.halted
      assert conn.status == 401

      response = Jason.decode!(conn.resp_body)
      assert response["error"] == "Unauthorized"
      assert response["message"] == "Invalid device"
    end
  end

  describe "call/2 with permission requirements" do
    setup do
      user = create_user()
      device = create_device(user)
      %{user: user, device: device}
    end

    test "allows request when all required permissions are present", %{
      conn: conn,
      device: device
    } do
      {:ok, token, _claims} =
        MediaToken.create_token(device, permissions: ["stream", "download", "thumbnails"])

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> MediaAuth.call(permissions: ["stream", "download"])

      refute conn.halted
      assert conn.assigns.media_device.id == device.id
    end

    test "rejects request when required permission is missing", %{conn: conn, device: device} do
      {:ok, token, _claims} = MediaToken.create_token(device, permissions: ["stream"])

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> MediaAuth.call(permissions: ["download"])

      assert conn.halted
      assert conn.status == 403

      response = Jason.decode!(conn.resp_body)
      assert response["error"] == "Forbidden"
      assert response["message"] == "Insufficient permissions"
    end

    test "rejects request when some required permissions are missing", %{
      conn: conn,
      device: device
    } do
      {:ok, token, _claims} = MediaToken.create_token(device, permissions: ["stream"])

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> MediaAuth.call(permissions: ["stream", "download"])

      assert conn.halted
      assert conn.status == 403

      response = Jason.decode!(conn.resp_body)
      assert response["message"] == "Insufficient permissions"
    end
  end

  describe "init/1" do
    test "returns options unchanged" do
      opts = [permissions: ["stream"]]
      assert MediaAuth.init(opts) == opts
    end

    test "returns empty list when no options provided" do
      assert MediaAuth.init([]) == []
    end
  end

  # Test Helpers

  defp create_user(attrs \\ %{}) do
    default_attrs = %{
      email: "user-#{System.unique_integer([:positive])}@example.com",
      username: "user#{System.unique_integer([:positive])}",
      password: "password123",
      role: "user"
    }

    {:ok, user} =
      default_attrs
      |> Map.merge(attrs)
      |> Accounts.create_user()

    user
  end

  defp create_device(user, attrs \\ %{}) do
    default_attrs = %{
      device_name: "Test Device #{System.unique_integer([:positive])}",
      platform: "ios",
      token: "device-token-#{System.unique_integer([:positive])}",
      user_id: user.id
    }

    # Use struct!/1 to avoid cyclic dependency
    device_module = RemoteDevice

    struct!(device_module)
    |> device_module.changeset(Map.merge(default_attrs, attrs))
    |> Mydia.Repo.insert!()
  end
end
