defmodule MydiaWeb.MediaTokenPrivilegeEscalationTest do
  @moduledoc """
  End-to-end regression coverage for T-108 (docs/superpowers/security-review):
  a media token must never reach an admin-gated operation or mint an API key.

  Before the fix, `:api_auth` mounted `MydiaWeb.Plugs.MediaAuth` with no
  `permissions:` option, so `required_permissions` defaulted to `[]` and the
  permission check was a structural no-op
  (`has_required_permissions?(_claims, []), do: true`). MediaAuth then called
  `Guardian.Plug.put_current_resource(device.user)`, which
  `MydiaWeb.Plugs.EnsureRole` and every GraphQL resolver treated identically
  to a real session or API key. A media token is a 24-hour, URL-exposed
  credential every paired device holds, minted with no narrower permission
  tier in practice (see `Mydia.RemoteAccess.MediaToken`), so this let a leaked
  or logged token belonging to an admin's device fully manage the DB-overlay
  config API and mint a permanent, non-expiring API key with attacker-chosen
  permissions.

  These tests go through the real router/endpoint pipeline (`post`/`get`
  against `/api/v1/...` and `/api/graphql`), not the plug or resolver in
  isolation, so they also exercise the router restructuring: `:api_auth` no
  longer mounts MediaAuth at all, and the two routes that still need
  media-token compatibility (offline-download file fetch, streaming) moved to
  their own narrowly permission-scoped pipelines.
  """

  use MydiaWeb.ConnCase, async: false

  alias Mydia.Accounts
  alias Mydia.RemoteAccess.{MediaToken, RemoteDevice}

  @create_api_key_mutation """
  mutation CreateApiKey($name: String!, $permissions: [String!]) {
    createApiKey(name: $name, permissions: $permissions) {
      apiKey { id }
      key
    }
  }
  """

  setup do
    # A media token is only honoured while remote access is on, and the flag
    # is cached in :persistent_term, so it must be set explicitly rather than
    # inherited from whichever test file ran first.
    reset_remote_access()
    on_exit(&reset_remote_access/0)
    set_remote_access(true)

    admin = create_admin_user()
    device = create_device(admin)
    # No opts: this is exactly how Mydia.RemoteAccess.Pairing.generate_media_token/1
    # mints every media token in production -- full default permissions, no
    # caller ever exercises a narrower tier.
    {:ok, token, _claims} = MediaToken.create_token(device)

    %{admin: admin, device: device, token: token}
  end

  describe "the admin config API (the config-mutation sink named in T-108)" do
    test "a media token cannot read the config list", %{conn: conn, token: token} do
      conn = get(conn, "/api/v1/config?token=#{token}")

      assert conn.status == 401
    end

    test "a media token cannot write a config key", %{conn: conn, token: token} do
      conn =
        put(conn, "/api/v1/config/some.key?token=#{token}", %{"value" => "attacker-controlled"})

      assert conn.status == 401
    end
  end

  describe "GraphQL createApiKey (the durable-credential sink named in T-108)" do
    test "a media token cannot authenticate the request at all", %{conn: conn, token: token} do
      variables = %{"name" => "Escalated Key", "permissions" => ["read", "write", "admin"]}

      conn =
        post(conn, "/api/graphql?token=#{token}", %{
          query: @create_api_key_mutation,
          variables: variables
        })

      body = json_response(conn, 200)
      assert %{"errors" => [%{"message" => message} | _]} = body
      assert message =~ "Authentication required"
      refute Map.has_key?(body, "data") and get_in(body, ["data", "createApiKey"]) != nil
    end

    test "no API key is created for the device's user", %{conn: conn, token: token, admin: admin} do
      variables = %{"name" => "Escalated Key", "permissions" => ["read", "write", "admin"]}

      post(conn, "/api/graphql?token=#{token}", %{
        query: @create_api_key_mutation,
        variables: variables
      })

      assert Accounts.list_api_keys(admin.id) == []
    end
  end

  describe "general /api/v1 management routes a media token was never meant to reach" do
    test "a media token cannot list download clients", %{conn: conn, token: token} do
      conn = get(conn, "/api/v1/downloads/clients?token=#{token}")

      assert conn.status == 401
    end

    test "a media token cannot list indexers", %{conn: conn, token: token} do
      conn = get(conn, "/api/v1/indexers?token=#{token}")

      assert conn.status == 401
    end
  end

  describe "routes a media token still legitimately authenticates" do
    test "the offline-download file endpoint still accepts the token", %{
      conn: conn,
      token: token
    } do
      conn = get(conn, "/api/v1/download/job/#{Ecto.UUID.generate()}/file?token=#{token}")

      # 404 (job not found), not 401/403: proves the pipeline authenticated
      # the request and let it reach DownloadController at all.
      assert conn.status == 404
    end

    # refreshMediaToken is how the Flutter player actually keeps a media
    # token alive (player/lib/core/auth/media_token_service.dart) -- and it
    # is deliberately public (MydiaWeb.Schema's @public_fields), trusting the
    # token argument itself rather than context[:current_user]. It never
    # relied on MediaAuth setting current_user, so removing MediaAuth from
    # :api_auth does not touch this: it is proof that the fix does not break
    # the one real GraphQL/media-token interaction the player has.
    test "refreshMediaToken over the real router still works with only a media token", %{
      conn: conn,
      token: token
    } do
      mutation = """
      mutation RefreshMediaToken($token: String!) {
        refreshMediaToken(token: $token) {
          token
          permissions
        }
      }
      """

      conn =
        post(conn, "/api/graphql", %{query: mutation, variables: %{"token" => token}})

      body = json_response(conn, 200)
      assert %{"data" => %{"refreshMediaToken" => %{"token" => new_token}}} = body
      assert is_binary(new_token)
    end
  end

  defp create_device(user, attrs \\ %{}) do
    default_attrs = %{
      device_name: "Escalation Test Device #{System.unique_integer([:positive])}",
      platform: "ios",
      token: "device-token-#{System.unique_integer([:positive])}",
      user_id: user.id
    }

    struct!(RemoteDevice)
    |> RemoteDevice.changeset(Map.merge(default_attrs, attrs))
    |> Mydia.Repo.insert!()
  end
end
