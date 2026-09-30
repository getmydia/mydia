defmodule Mydia.Plugins.GrantsTest do
  use Mydia.DataCase, async: true

  import Ecto.Query
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

  test "a malformed stored ceiling fails closed", %{user: user} do
    :ok = Grants.grant("helper", user.id, "media:add", "always", "s1")

    config = Settings.get_plugin_config_by_slug("helper")
    {:ok, _} = Settings.update_plugin_config(config, %{role_ceilings: %{"user" => "bogus"}})

    assert Grants.allowed_choices("helper", user.role) == []
    refute Grants.granted?("helper", user.id, "media:add", "s1")
  end

  test "list_for_user omits session grants", %{user: user} do
    :ok = Grants.grant("helper", user.id, "media:add", "session", "s1")
    :ok = Grants.grant("helper", user.id, "collections:write", "always", "s1")

    assert [%{surface: "collections:write", scope: "always"}] = Grants.list_for_user(user.id)
  end

  test "prune_sessions drops other sessions' grants for the plugin only", %{user: user} do
    :ok = Grants.grant("helper", user.id, "media:add", "session", "old")
    :ok = Grants.grant("helper", user.id, "collections:write", "session", "current")
    :ok = Grants.grant("helper", user.id, "collections:favorite", "always", "old")
    :ok = Grants.grant("other", user.id, "media:add", "session", "old")

    :ok = Grants.prune_sessions(user.id, "helper", "current")

    refute Grants.granted?("helper", user.id, "media:add", "old")
    assert Grants.granted?("helper", user.id, "collections:write", "current")
    assert Grants.granted?("helper", user.id, "collections:favorite", "new")
    assert Repo.get_by(Mydia.Plugins.WriteGrant, plugin_slug: "other", session_id: "old")
  end

  test "purge removes the slug's grants and pending writes only", %{user: user} do
    :ok = Grants.grant("helper", user.id, "media:add", "always", "s1")
    :ok = Grants.grant("helper", user.id, "collections:write", "session", "s1")
    :ok = Grants.grant("other", user.id, "media:add", "always", "s1")

    expires = DateTime.add(DateTime.utc_now(), 3600) |> DateTime.truncate(:second)

    for slug <- ["helper", "other"] do
      {:ok, _} =
        %Mydia.Plugins.PendingWrite{}
        |> Mydia.Plugins.PendingWrite.changeset(%{
          plugin_slug: slug,
          user_id: user.id,
          session_id: "s1",
          op: "media_add",
          surface: "media:add",
          args: %{},
          description: "d",
          expires_at: expires
        })
        |> Repo.insert()
    end

    :ok = Grants.purge("helper")

    refute Repo.exists?(from g in Mydia.Plugins.WriteGrant, where: g.plugin_slug == "helper")
    assert Repo.exists?(from g in Mydia.Plugins.WriteGrant, where: g.plugin_slug == "other")

    refute Repo.exists?(from p in Mydia.Plugins.PendingWrite, where: p.plugin_slug == "helper")
    assert Repo.exists?(from p in Mydia.Plugins.PendingWrite, where: p.plugin_slug == "other")
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
