defmodule Mydia.Plugins.GrantsTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures

  alias Mydia.Plugins.Grants
  alias Mydia.Settings

  setup do
    {:ok, _} =
      Settings.create_plugin_config(%{
        slug: "helper",
        name: "Helper",
        version: "0.1.0",
        source_url: "test",
        manifest: %{"slug" => "helper", "name" => "Helper", "version" => "0.1.0"},
        granted_capabilities: %{},
        enabled: true
      })

    {:ok, user: user_fixture()}
  end

  test "default ceilings" do
    assert Grants.ceiling("helper", "admin") == "always"
    assert Grants.ceiling("helper", "user") == "always"
    assert Grants.ceiling("helper", "guest") == "session"
    assert Grants.ceiling("helper", "readonly") == "none"
    assert Grants.allowed_choices("helper", "guest") == ["once", "session"]
    assert Grants.allowed_choices("helper", "readonly") == []
  end

  test "admins can lower a ceiling" do
    {:ok, _} = Grants.put_ceilings("helper", %{"user" => "once"})
    assert Grants.ceiling("helper", "user") == "once"
    assert Grants.ceiling("helper", "admin") == "always"
  end

  test "put_ceilings rejects unknown roles and scopes" do
    assert {:error, _} = Grants.put_ceilings("helper", %{"user" => "forever"})
    assert {:error, _} = Grants.put_ceilings("helper", %{"owner" => "always"})
  end

  test "once records nothing", %{user: user} do
    assert :ok = Grants.grant("helper", user.id, "collections:write", "once", "s1")
    refute Grants.granted?("helper", user.id, "collections:write", "s1")
  end

  test "session grants hold for their session only", %{user: user} do
    assert :ok = Grants.grant("helper", user.id, "collections:write", "session", "s1")
    assert Grants.granted?("helper", user.id, "collections:write", "s1")
    refute Grants.granted?("helper", user.id, "collections:write", "s2")
    refute Grants.granted?("helper", user.id, "media:add", "s1")
  end

  test "always grants hold across sessions and are idempotent", %{user: user} do
    assert :ok = Grants.grant("helper", user.id, "media:add", "always", "s1")
    assert :ok = Grants.grant("helper", user.id, "media:add", "always", "s9")
    assert Grants.granted?("helper", user.id, "media:add", "s2")
    assert [_one] = Grants.list_for_user(user.id)
  end

  test "a grant above the current ceiling stops counting", %{user: user} do
    :ok = Grants.grant("helper", user.id, "media:add", "always", "s1")
    {:ok, _} = Grants.put_ceilings("helper", %{"user" => "session"})
    refute Grants.granted?("helper", user.id, "media:add", "s2")
  end

  test "revoke deletes only the user's own grant", %{user: user} do
    :ok = Grants.grant("helper", user.id, "media:add", "always", "s1")
    [grant] = Grants.list_for_user(user.id)
    other = user_fixture()

    assert {:error, :not_found} = Grants.revoke(other.id, grant.id)
    assert :ok = Grants.revoke(user.id, grant.id)
    assert Grants.list_for_user(user.id) == []
  end
end
