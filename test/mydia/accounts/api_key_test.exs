defmodule Mydia.Accounts.ApiKeyTest do
  use Mydia.DataCase

  alias Mydia.Accounts
  alias Mydia.AccountsFixtures

  describe "create_api_key/2" do
    setup do
      user = AccountsFixtures.user_fixture()
      %{user: user}
    end

    test "creates an API key with valid attributes", %{user: user} do
      attrs = %{name: "Test API Key"}

      assert {:ok, api_key, plain_key} = Accounts.create_api_key(user.id, attrs)
      assert api_key.name == "Test API Key"
      assert api_key.user_id == user.id
      assert is_binary(plain_key)
      assert String.starts_with?(plain_key, "mydia_ak_")
      # "mydia_ak_" (9) + 32 chars
      assert String.length(plain_key) == 41
    end

    test "creates an API key with custom permissions", %{user: user} do
      attrs = %{name: "Admin Key", permissions: ["read", "write", "admin"]}

      assert {:ok, api_key, _plain_key} = Accounts.create_api_key(user.id, attrs)
      assert api_key.permissions == ["read", "write", "admin"]
    end

    test "creates an API key with expiration", %{user: user} do
      expires_at = DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)
      attrs = %{name: "Temporary Key", expires_at: expires_at}

      assert {:ok, api_key, _plain_key} = Accounts.create_api_key(user.id, attrs)
      assert api_key.expires_at == expires_at
    end

    test "defaults to read and write permissions", %{user: user} do
      attrs = %{name: "Default Key"}

      assert {:ok, api_key, _plain_key} = Accounts.create_api_key(user.id, attrs)
      assert api_key.permissions == ["read", "write"]
    end

    test "stores key prefix for display", %{user: user} do
      attrs = %{name: "Test Key"}

      assert {:ok, api_key, plain_key} = Accounts.create_api_key(user.id, attrs)
      assert String.starts_with?(api_key.key_prefix, "mydia_ak_")
      # "mydia_ak_" (9) + 8 chars
      assert String.length(api_key.key_prefix) == 17
      # Prefix should match the beginning of the plain key
      assert String.starts_with?(plain_key, api_key.key_prefix)
    end

    test "hashes the API key", %{user: user} do
      attrs = %{name: "Test Key"}

      assert {:ok, api_key, plain_key} = Accounts.create_api_key(user.id, attrs)
      assert is_binary(api_key.key_hash)
      # The plain key should not be stored
      assert api_key.key == nil
      # But we should be able to verify it
      assert Argon2.verify_pass(plain_key, api_key.key_hash)
    end

    test "rejects invalid permissions", %{user: user} do
      attrs = %{name: "Bad Key", permissions: ["read", "invalid"]}

      assert {:error, changeset} = Accounts.create_api_key(user.id, attrs)
      errors = errors_on(changeset).permissions
      assert errors != []
      assert hd(errors) =~ "contains invalid permissions"
    end
  end

  describe "list_api_keys/1" do
    setup do
      user = AccountsFixtures.user_fixture()
      %{user: user}
    end

    test "returns all API keys for a user", %{user: user} do
      {:ok, key1, _} = Accounts.create_api_key(user.id, %{name: "Key 1"})
      {:ok, key2, _} = Accounts.create_api_key(user.id, %{name: "Key 2"})

      keys = Accounts.list_api_keys(user.id)
      assert length(keys) == 2
      assert Enum.any?(keys, &(&1.id == key1.id))
      assert Enum.any?(keys, &(&1.id == key2.id))
    end

    test "returns empty list when user has no keys", %{user: user} do
      assert Accounts.list_api_keys(user.id) == []
    end

    test "only returns keys for the specified user" do
      user1 = AccountsFixtures.user_fixture()
      user2 = AccountsFixtures.user_fixture()

      {:ok, _key1, _} = Accounts.create_api_key(user1.id, %{name: "User 1 Key"})
      {:ok, _key2, _} = Accounts.create_api_key(user2.id, %{name: "User 2 Key"})

      user1_keys = Accounts.list_api_keys(user1.id)
      assert length(user1_keys) == 1
      assert hd(user1_keys).name == "User 1 Key"
    end
  end

  describe "verify_api_key/1" do
    setup do
      user = AccountsFixtures.user_fixture()
      {:ok, api_key, plain_key} = Accounts.create_api_key(user.id, %{name: "Test Key"})
      %{user: user, api_key: api_key, plain_key: plain_key}
    end

    test "returns user and api_key for valid key", %{user: user, plain_key: plain_key} do
      assert {:ok, verified_user, api_key} = Accounts.verify_api_key(plain_key)
      assert verified_user.id == user.id
      assert api_key.name == "Test Key"
    end

    test "returns error for invalid key" do
      assert {:error, :invalid_key} = Accounts.verify_api_key("invalid_key")
    end

    test "updates last_used_at timestamp", %{plain_key: plain_key, api_key: original_key} do
      {:ok, _user, _api_key} = Accounts.verify_api_key(plain_key)

      # Reload the api_key from database to get updated timestamp
      reloaded = Accounts.get_api_key!(original_key.id)
      assert reloaded.last_used_at != nil

      # Verify timestamp is recent (within last 5 seconds)
      now = DateTime.utc_now()
      diff = DateTime.diff(now, reloaded.last_used_at, :second)
      assert diff < 5
    end

    test "rejects revoked key", %{plain_key: plain_key, api_key: api_key} do
      {:ok, _} = Accounts.revoke_api_key(api_key)
      assert {:error, :invalid_key} = Accounts.verify_api_key(plain_key)
    end

    test "rejects expired key", %{user: user} do
      # Create an expired key
      expires_at = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)

      {:ok, _api_key, plain_key} =
        Accounts.create_api_key(user.id, %{name: "Expired Key", expires_at: expires_at})

      assert {:error, :invalid_key} = Accounts.verify_api_key(plain_key)
    end
  end

  describe "revoke_api_key/1" do
    setup do
      user = AccountsFixtures.user_fixture()
      {:ok, api_key, plain_key} = Accounts.create_api_key(user.id, %{name: "Test Key"})
      %{user: user, api_key: api_key, plain_key: plain_key}
    end

    test "revokes an API key", %{api_key: api_key} do
      assert {:ok, revoked_key} = Accounts.revoke_api_key(api_key)
      assert revoked_key.revoked_at != nil
    end

    test "prevents verification of revoked key", %{api_key: api_key, plain_key: plain_key} do
      {:ok, _} = Accounts.revoke_api_key(api_key)
      assert {:error, :invalid_key} = Accounts.verify_api_key(plain_key)
    end
  end

  describe "delete_api_key/1" do
    setup do
      user = AccountsFixtures.user_fixture()
      {:ok, api_key, _plain_key} = Accounts.create_api_key(user.id, %{name: "Test Key"})
      %{user: user, api_key: api_key}
    end

    test "deletes an API key", %{api_key: api_key, user: user} do
      assert {:ok, _} = Accounts.delete_api_key(api_key)
      assert Accounts.list_api_keys(user.id) == []
    end
  end
end
