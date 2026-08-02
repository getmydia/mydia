defmodule MydiaWeb.Schema.ApiKeyTest do
  use MydiaWeb.ConnCase

  alias Mydia.Accounts
  alias Mydia.AccountsFixtures

  @list_api_keys_query """
  query {
    apiKeys {
      id
      name
      keyPrefix
      permissions
      lastUsedAt
      expiresAt
      revokedAt
      insertedAt
    }
  }
  """

  @create_api_key_mutation """
  mutation CreateApiKey($name: String!, $permissions: [String!], $expiresAt: DateTime) {
    createApiKey(name: $name, permissions: $permissions, expiresAt: $expiresAt) {
      apiKey {
        id
        name
        keyPrefix
        permissions
      }
      key
    }
  }
  """

  @revoke_api_key_mutation """
  mutation RevokeApiKey($id: ID!) {
    revokeApiKey(id: $id) {
      id
      revokedAt
    }
  }
  """

  @delete_api_key_mutation """
  mutation DeleteApiKey($id: ID!) {
    deleteApiKey(id: $id)
  }
  """

  describe "apiKeys query" do
    setup do
      user = AccountsFixtures.user_fixture()
      %{user: user}
    end

    test "lists API keys for authenticated user", %{user: user} do
      {:ok, key1, _} = Accounts.create_api_key(user.id, %{name: "Test Key 1"})
      {:ok, key2, _} = Accounts.create_api_key(user.id, %{name: "Test Key 2"})

      result = run_query(@list_api_keys_query, %{}, user)

      assert {:ok, %{data: %{"apiKeys" => keys}}} = result
      assert length(keys) == 2

      key_ids = Enum.map(keys, & &1["id"])
      assert key1.id in key_ids
      assert key2.id in key_ids
    end

    test "returns empty list when user has no keys", %{user: user} do
      result = run_query(@list_api_keys_query, %{}, user)

      assert {:ok, %{data: %{"apiKeys" => []}}} = result
    end

    test "requires authentication" do
      result = run_query(@list_api_keys_query, %{})

      assert {:ok, %{errors: [%{message: message}]}} = result
      # Root-field middleware rejects before the resolver runs, so the unified
      # "Authentication required" message is the expected one now.
      assert message =~ "Authentication required" or message =~ "unauthorized" or
               message =~ "not authenticated"
    end
  end

  describe "createApiKey mutation" do
    setup do
      user = AccountsFixtures.user_fixture()
      %{user: user}
    end

    test "creates API key with valid attributes", %{user: user} do
      variables = %{"name" => "My API Key"}
      result = run_query(@create_api_key_mutation, variables, user)

      assert {:ok, %{data: %{"createApiKey" => response}}} = result
      assert %{"apiKey" => api_key, "key" => plain_key} = response

      assert api_key["name"] == "My API Key"
      assert is_binary(plain_key)
      assert String.starts_with?(plain_key, "mydia_ak_")
      assert String.length(plain_key) == 41
      assert String.starts_with?(plain_key, api_key["keyPrefix"])
    end

    test "creates API key with custom permissions", %{user: user} do
      variables = %{
        "name" => "Admin Key",
        "permissions" => ["read", "write", "admin"]
      }

      result = run_query(@create_api_key_mutation, variables, user)

      assert {:ok, %{data: %{"createApiKey" => response}}} = result
      assert response["apiKey"]["permissions"] == ["read", "write", "admin"]
    end

    test "creates API key with expiration", %{user: user} do
      expires_at = DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)

      variables = %{
        "name" => "Temporary Key",
        "expiresAt" => DateTime.to_iso8601(expires_at)
      }

      result = run_query(@create_api_key_mutation, variables, user)

      assert {:ok, %{data: %{"createApiKey" => _response}}} = result
    end

    test "defaults to read and write permissions", %{user: user} do
      variables = %{"name" => "Default Key"}
      result = run_query(@create_api_key_mutation, variables, user)

      assert {:ok, %{data: %{"createApiKey" => response}}} = result
      assert response["apiKey"]["permissions"] == ["read", "write"]
    end

    test "requires authentication" do
      variables = %{"name" => "Test Key"}
      result = run_query(@create_api_key_mutation, variables)

      assert {:ok, %{errors: [%{message: message}]}} = result
      # Root-field middleware rejects before the resolver runs, so the unified
      # "Authentication required" message is the expected one now.
      assert message =~ "Authentication required" or message =~ "unauthorized" or
               message =~ "not authenticated"
    end

    test "rejects invalid permissions", %{user: user} do
      variables = %{
        "name" => "Bad Key",
        "permissions" => ["read", "invalid"]
      }

      result = run_query(@create_api_key_mutation, variables, user)

      assert {:ok, %{errors: errors}} = result
      assert errors != []
    end
  end

  describe "revokeApiKey mutation" do
    setup do
      user = AccountsFixtures.user_fixture()
      {:ok, api_key, _plain_key} = Accounts.create_api_key(user.id, %{name: "Test Key"})
      %{user: user, api_key: api_key}
    end

    test "revokes API key", %{user: user, api_key: api_key} do
      variables = %{"id" => api_key.id}
      result = run_query(@revoke_api_key_mutation, variables, user)

      assert {:ok, %{data: %{"revokeApiKey" => revoked}}} = result
      assert revoked["id"] == api_key.id
      assert revoked["revokedAt"] != nil
    end

    test "requires authentication", %{api_key: api_key} do
      variables = %{"id" => api_key.id}
      result = run_query(@revoke_api_key_mutation, variables)

      assert {:ok, %{errors: [%{message: message}]}} = result
      # Root-field middleware rejects before the resolver runs, so the unified
      # "Authentication required" message is the expected one now.
      assert message =~ "Authentication required" or message =~ "unauthorized" or
               message =~ "not authenticated"
    end

    test "prevents revoking another user's key" do
      user1 = AccountsFixtures.user_fixture()
      user2 = AccountsFixtures.user_fixture()
      {:ok, api_key, _} = Accounts.create_api_key(user1.id, %{name: "User 1 Key"})

      variables = %{"id" => api_key.id}
      result = run_query(@revoke_api_key_mutation, variables, user2)

      assert {:ok, %{errors: [%{message: message}]}} = result
      assert message =~ "forbidden" or message =~ "not found"
    end
  end

  describe "deleteApiKey mutation" do
    setup do
      user = AccountsFixtures.user_fixture()
      {:ok, api_key, _plain_key} = Accounts.create_api_key(user.id, %{name: "Test Key"})
      %{user: user, api_key: api_key}
    end

    test "deletes API key", %{user: user, api_key: api_key} do
      variables = %{"id" => api_key.id}
      result = run_query(@delete_api_key_mutation, variables, user)

      assert {:ok, %{data: %{"deleteApiKey" => true}}} = result

      # Verify it's actually deleted
      assert Accounts.list_api_keys(user.id) == []
    end

    test "requires authentication", %{api_key: api_key} do
      variables = %{"id" => api_key.id}
      result = run_query(@delete_api_key_mutation, variables)

      assert {:ok, %{errors: [%{message: message}]}} = result
      # Root-field middleware rejects before the resolver runs, so the unified
      # "Authentication required" message is the expected one now.
      assert message =~ "Authentication required" or message =~ "unauthorized" or
               message =~ "not authenticated"
    end

    test "prevents deleting another user's key" do
      user1 = AccountsFixtures.user_fixture()
      user2 = AccountsFixtures.user_fixture()
      {:ok, api_key, _} = Accounts.create_api_key(user1.id, %{name: "User 1 Key"})

      variables = %{"id" => api_key.id}
      result = run_query(@delete_api_key_mutation, variables, user2)

      assert {:ok, %{errors: [%{message: message}]}} = result
      assert message =~ "forbidden" or message =~ "not found"
    end
  end

  # Helper function to run GraphQL queries
  defp run_query(query, variables, user \\ nil) do
    context = if user, do: %{current_user: user}, else: %{}
    Absinthe.run(query, MydiaWeb.Schema, variables: variables, context: context)
  end
end
