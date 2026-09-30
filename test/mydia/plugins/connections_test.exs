defmodule Mydia.Plugins.ConnectionsTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.Plugins.Connections
  alias Mydia.Plugins.Kv
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
          "capabilities" => %{
            "events:subscribe" => ["media_item.added"],
            "users:connections" => []
          }
        },
        granted_capabilities: %{"users:connections" => []},
        enabled: false
      })

    :ok
  end

  # Connections live on the plugin's default instance, and so does their store.
  defp kv_id, do: Mydia.Plugins.Instances.default_instance("connector").id

  setup do
    install!("connector")
    %{user: user_fixture(), other: user_fixture()}
  end

  describe "account link backing" do
    test "connections are user_flow links on the plugin's default instance" do
      user = user_fixture()

      {:ok, conn} =
        Connections.connect("connector", user.id, %{access_token: "t", status: "connected"})

      assert conn.instance_id == Mydia.Plugins.Instances.default_instance("connector").id
      assert conn.role == :user
      assert conn.source == :user_flow
      assert conn.status == :active
    end

    test "owner and endpoint credentials are invisible to connection reads and counts" do
      user = user_fixture()
      instance = Mydia.Plugins.Instances.default_instance("connector")
      {:ok, _} = Mydia.Plugins.AccountLinks.put_credential(instance.id, :owner, "acct")
      {:ok, _} = Mydia.Plugins.AccountLinks.put_credential(instance.id, :endpoint, "srv")

      assert Connections.list_for_plugin("connector") == []
      assert Connections.count_for_plugin("connector") == 0
      assert Connections.connected_user_ids("connector") == []

      {:ok, conn} = Connections.connect("connector", user.id, %{access_token: "t"})
      assert [%{id: id}] = Connections.list_for_plugin("connector")
      assert id == conn.id
      assert Connections.count_for_plugin("connector") == 1
      assert Connections.get_by_id("connector", conn.id).id == conn.id

      owner = Mydia.Plugins.AccountLinks.credential(instance.id, :owner)
      assert Connections.get_by_id("connector", owner.id) == nil
    end
  end

  test "connect/3 returns an error for an unknown status instead of raising", %{user: user} do
    assert {:error, {:invalid_status, "bogus"}} =
             Connections.connect("connector", user.id, %{access_token: "t", status: "bogus"})
  end

  describe "multi_instance plugins" do
    setup do
      {:ok, _} =
        Settings.create_plugin_config(%{
          slug: "multi-conn",
          name: "Multi",
          version: "1.0.0",
          enabled: true,
          manifest: %{"slug" => "multi-conn", "multi_instance" => true}
        })

      :ok
    end

    test "have no default-instance connection and none is created", %{user: user} do
      assert Connections.get("multi-conn", user.id) == nil
      assert {:error, :not_connectable} = Connections.connect("multi-conn", user.id, %{})
      assert Connections.delete("multi-conn", user.id) == :ok
      assert Mydia.Plugins.Instances.list("multi-conn") == []
    end
  end

  describe "connect/3 and reads" do
    test "creates a connection and round-trips identity", %{user: user} do
      assert {:ok, conn} =
               Connections.connect("connector", user.id, %{
                 access_token: "secret-token",
                 external_user_id: "ext-1",
                 external_username: "alice"
               })

      assert conn.status == :active
      assert conn.external_username == "alice"

      fetched = Connections.get("connector", user.id)
      assert fetched.id == conn.id
    end

    test "reconnect updates the existing row (no duplicate)", %{user: user} do
      {:ok, _} = Connections.connect("connector", user.id, %{access_token: "t1"})

      {:ok, _} =
        Connections.connect("connector", user.id, %{access_token: "t2", status: "connected"})

      assert Connections.count_for_plugin("connector") == 1
    end

    test "connect on an uninstalled plugin fails", %{user: user} do
      assert {:error, :not_installed} =
               Connections.connect("ghost", user.id, %{access_token: "t"})
    end

    test "the access token is redacted from struct inspection", %{user: user} do
      {:ok, conn} = Connections.connect("connector", user.id, %{access_token: "super-secret"})
      refute inspect(conn) =~ "super-secret"
    end
  end

  describe "consent boundary (R21)" do
    test "connected_user_ids returns only active connections", %{user: user, other: other} do
      {:ok, _} = Connections.connect("connector", user.id, %{access_token: "t"})
      {:ok, _} = Connections.connect("connector", other.id, %{access_token: "t", status: "error"})

      ids = Connections.connected_user_ids("connector")
      assert user.id in ids
      refute other.id in ids
    end

    test "active? is true only for connected status", %{user: user} do
      {:ok, _} = Connections.connect("connector", user.id, %{access_token: "t"})
      assert Connections.active?("connector", user.id)

      Connections.mark_errored("connector", [user.id])
      refute Connections.active?("connector", user.id)
    end
  end

  describe "mark_errored/2" do
    test "flips only users that hold an active connection", %{user: user, other: other} do
      {:ok, _} = Connections.connect("connector", user.id, %{access_token: "t"})
      # `other` has no connection to this plugin.

      assert Connections.mark_errored("connector", [user.id, other.id, "bogus-id"]) == 1
      assert Connections.get("connector", user.id).status == :error
      assert Connections.get("connector", other.id) == nil
    end
  end

  describe "disconnect and cleanup" do
    test "disconnect sweeps the connection's KV prefix and removes the row", %{user: user} do
      {:ok, conn} = Connections.connect("connector", user.id, %{access_token: "t"})

      {:ok, _} = Kv.set(kv_id(), "conn/#{conn.id}/watermark", "1")
      {:ok, _} = Kv.set(kv_id(), "global", "keep")

      assert :ok = Connections.disconnect("connector", user.id)

      assert Connections.get("connector", user.id) == nil
      assert {:ok, nil} = Kv.get(kv_id(), "conn/#{conn.id}/watermark")
      assert {:ok, "keep"} = Kv.get(kv_id(), "global")
    end

    test "sweep_kv drops each connection's prefix and leaves unscoped keys", %{user: user} do
      {:ok, conn} = Connections.connect("connector", user.id, %{access_token: "t"})
      {:ok, _} = Kv.set(kv_id(), "conn/#{conn.id}/cursor", "x")
      {:ok, _} = Kv.set(kv_id(), "global", "keep")

      assert :ok = Connections.sweep_kv(Connections.list_for_user(user.id))

      assert {:ok, nil} = Kv.get(kv_id(), "conn/#{conn.id}/cursor")
      assert {:ok, "keep"} = Kv.get(kv_id(), "global")
    end

    test "deleting the user cascades the rows and sweep_kv clears their state", %{user: user} do
      {:ok, conn} = Connections.connect("connector", user.id, %{access_token: "t"})
      {:ok, _} = Kv.set(kv_id(), "conn/#{conn.id}/cursor", "x")

      assert {:ok, _} = Mydia.Accounts.delete_user(user)

      assert Connections.get("connector", user.id) == nil
      assert {:ok, nil} = Kv.get(kv_id(), "conn/#{conn.id}/cursor")
    end

    # `media_requests.requester_id` is `on_delete: :restrict`, so a user who has
    # ever requested media cannot be deleted. Nothing here runs in a transaction,
    # so a KV sweep that ran before `Repo.delete/1` would already be committed by
    # the time the database rejects the delete, leaving a live user whose plugin
    # state had been destroyed out from under them.
    test "a rejected delete leaves the user's plugin state intact", %{user: user} do
      {:ok, conn} = Connections.connect("connector", user.id, %{access_token: "t"})
      {:ok, _} = Kv.set(kv_id(), "conn/#{conn.id}/cursor", "x")

      {:ok, _request} =
        Mydia.MediaRequests.create_request(Scope.unrestricted(), %{
          media_type: "movie",
          title: "Restricting Request",
          tmdb_id: 603,
          requester_id: user.id
        })

      assert_raise Ecto.ConstraintError, fn -> Mydia.Accounts.delete_user(user) end

      assert Mydia.Accounts.get_user!(user.id)
      assert Connections.get("connector", user.id)
      assert {:ok, "x"} = Kv.get(kv_id(), "conn/#{conn.id}/cursor")
    end
  end
end
