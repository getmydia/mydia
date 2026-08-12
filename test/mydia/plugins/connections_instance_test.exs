defmodule Mydia.Plugins.ConnectionsInstanceTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures

  alias Mydia.Plugins.Connections
  alias Mydia.Settings

  defp install!(slug) do
    {:ok, _} =
      Settings.create_plugin_config(%{
        slug: slug,
        name: slug,
        version: "1.0.0",
        source_url: "test",
        manifest: %{
          "slug" => slug,
          "name" => slug,
          "version" => "1.0.0",
          "capabilities" => %{"users:connections" => []}
        },
        granted_capabilities: %{"users:connections" => []},
        enabled: false
      })

    :ok
  end

  setup do
    install!("srv")
    %{user: user_fixture()}
  end

  test "creates an instance-scoped connection with no user" do
    assert {:ok, conn} =
             Connections.upsert("srv", %{
               scope: "instance",
               label: "Living room",
               base_urls: ["http://10.0.0.5:32400", "http://plex.local:32400"],
               access_token: "tok",
               auth_kind: "header",
               auth_key: "X-Plex-Token"
             })

    assert conn.scope == "instance"
    assert is_nil(conn.user_id)
    assert conn.base_urls == ["http://10.0.0.5:32400", "http://plex.local:32400"]
    assert conn.auth_key == "X-Plex-Token"
  end

  test "two instance connections coexist under one slug" do
    {:ok, _} =
      Connections.upsert("srv", %{
        scope: "instance",
        label: "A",
        base_urls: ["http://a.test"],
        access_token: "t"
      })

    {:ok, _} =
      Connections.upsert("srv", %{
        scope: "instance",
        label: "B",
        base_urls: ["http://b.test"],
        access_token: "t"
      })

    assert length(Connections.list_instance_for_plugin("srv")) == 2
  end

  test "the same label upserts rather than duplicating" do
    {:ok, first} =
      Connections.upsert("srv", %{
        scope: "instance",
        label: "A",
        base_urls: ["http://a.test"],
        access_token: "t"
      })

    {:ok, second} =
      Connections.upsert("srv", %{
        scope: "instance",
        label: "A",
        base_urls: ["http://a2.test"],
        access_token: "t"
      })

    assert first.id == second.id
    assert second.base_urls == ["http://a2.test"]
    assert length(Connections.list_instance_for_plugin("srv")) == 1
  end

  test "an instance connection is not attributed to any user", %{user: user} do
    {:ok, _} =
      Connections.upsert("srv", %{
        scope: "instance",
        label: "A",
        base_urls: ["http://a.test"],
        access_token: "t"
      })

    assert Connections.connected_user_ids("srv") == []
    assert Connections.list_for_user(user.id) == []
  end

  test "user-scoped connections still work and carry a label", %{user: user} do
    {:ok, conn} =
      Connections.upsert("srv", %{
        scope: "user",
        user_id: user.id,
        label: "Living room",
        access_token: "user-tok"
      })

    assert conn.scope == "user"
    assert conn.user_id == user.id
    assert Connections.connected_user_ids("srv") == [user.id]
  end

  test "disabled is an accepted status" do
    assert {:ok, conn} =
             Connections.upsert("srv", %{
               scope: "instance",
               label: "Off",
               base_urls: ["http://a.test"],
               access_token: "t",
               status: "disabled"
             })

    assert conn.status == "disabled"
  end

  test "set_resolved_base_url/2 caches and clears the winner" do
    {:ok, conn} =
      Connections.upsert("srv", %{
        scope: "instance",
        label: "A",
        base_urls: ["http://a.test"],
        access_token: "t"
      })

    {:ok, cached} = Connections.set_resolved_base_url(conn, "http://a.test")
    assert cached.resolved_base_url == "http://a.test"

    {:ok, cleared} = Connections.set_resolved_base_url(cached, nil)
    assert is_nil(cleared.resolved_base_url)
  end
end
