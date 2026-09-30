defmodule Mydia.Plugins.HostFunctionsLinksTest do
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures

  alias Mydia.Plugins.AccountLinks
  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Host
  alias Mydia.Plugins.HostFunctions
  alias Mydia.Plugins.Instances
  alias Mydia.Plugins.Plugin
  alias Mydia.Plugins.Registry
  alias Mydia.Settings

  @slug "linkhost"
  @fixture Path.expand("../../support/fixtures/plugins/host_v14_fixture.wasm", __DIR__)
  @links_grant %{"net:http" => ["127.0.0.1"], "users:connections" => []}
  @plex_conn %{
    "type" => "none",
    "auth_header" => "X-Plex-Token: {token}",
    "method" => "GET",
    "headers" => %{}
  }

  defp gate_opts, do: [resolver: fn _ -> {:ok, [{127, 0, 0, 1}]} end, allow_private: true]

  defp plugin(granted, connection \\ @plex_conn) do
    %Plugin{
      slug: @slug,
      name: "Link host",
      enabled: true,
      entrypoint: "handle",
      granted_capabilities: granted,
      connection: connection
    }
  end

  defp get_request(url, headers \\ %{}),
    do: %{"url" => url, "method" => "GET", "headers" => headers}

  setup do
    {:ok, _} =
      Settings.create_plugin_config(%{
        slug: @slug,
        name: "Link host",
        version: "1.0.0",
        source_url: "test",
        manifest: %{
          "slug" => @slug,
          "name" => "Link host",
          "version" => "1.0.0",
          "capabilities" => %{}
        },
        granted_capabilities: %{},
        enabled: true
      })

    {:ok, instance} = Instances.create(@slug, %{name: "Main"})
    {:ok, other} = Instances.create(@slug, %{name: "Other"})
    {:ok, owner} = AccountLinks.put_credential(instance.id, :owner, "acct-token")
    %{instance: instance, other: other, owner: owner}
  end

  describe "links_list/2" do
    test "returns identity and status only, for this instance", %{instance: i, other: o} do
      user = user_fixture()
      {:ok, _} = AccountLinks.put_credential(o.id, :owner, "elsewhere")

      {:ok, _} =
        AccountLinks.replace_user_links(
          i.id,
          [%{remote_account_id: "r1", remote_username: "Robin", user_id: user.id}],
          :admin_mapped
        )

      assert {:ok, records} = HostFunctions.links_list(plugin(@links_grant), i)
      assert length(records) == 2

      user_record = Enum.find(records, &(&1.role == :user))
      assert user_record[:"user-id"] == {:some, user.id}
      assert user_record[:"external-user-id"] == {:some, "r1"}
      assert user_record.status == :active
      refute inspect(records) =~ "acct-token"
    end

    test "requires users:connections", %{instance: i} do
      assert {:error, %Error{type: :capability_denied}} =
               HostFunctions.links_list(plugin(%{"net:http" => ["127.0.0.1"]}), i)
    end
  end

  describe "link_request/5" do
    setup do
      %{bypass: Bypass.open()}
    end

    test "injects the manifest header and strips the guest's copy", %{
      bypass: b,
      instance: i,
      owner: owner
    } do
      parent = self()

      Bypass.expect_once(b, "GET", "/library/sections", fn conn ->
        send(parent, {:token, Plug.Conn.get_req_header(conn, "x-plex-token")})
        Plug.Conn.resp(conn, 200, ~s({"ok":true}))
      end)

      request =
        get_request("http://127.0.0.1:#{b.port}/library/sections", %{
          "X-PLEX-TOKEN" => "guest-forged"
        })

      assert {:ok, %{"status" => 200}} =
               HostFunctions.link_request(plugin(@links_grant), i, owner.id, request, gate_opts())

      assert_received {:token, ["acct-token"]}
    end

    test "defaults to bearer when the plugin declares no connection", %{
      bypass: b,
      instance: i,
      owner: owner
    } do
      parent = self()

      Bypass.expect_once(b, "GET", "/x", fn conn ->
        send(parent, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
        Plug.Conn.resp(conn, 200, "{}")
      end)

      assert {:ok, _} =
               HostFunctions.link_request(
                 plugin(@links_grant, nil),
                 i,
                 owner.id,
                 get_request("http://127.0.0.1:#{b.port}/x", %{"Authorization" => "Bearer forged"}),
                 gate_opts()
               )

      assert_received {:auth, ["Bearer acct-token"]}
    end

    test "a link from another instance is not found", %{instance: i, other: o} do
      {:ok, foreign} = AccountLinks.put_credential(o.id, :owner, "x")

      assert {:error, %Error{type: :not_found}} =
               HostFunctions.link_request(
                 plugin(@links_grant),
                 i,
                 foreign.id,
                 get_request("http://127.0.0.1:1/x"),
                 gate_opts()
               )
    end

    test "a disabled or token-less link is denied", %{instance: i, owner: owner} do
      :ok = AccountLinks.set_status(owner.id, :disabled, nil)

      assert {:error, %Error{type: :capability_denied}} =
               HostFunctions.link_request(
                 plugin(@links_grant),
                 i,
                 owner.id,
                 get_request("http://127.0.0.1:1/x"),
                 gate_opts()
               )

      user = user_fixture()

      {:ok, [pending]} =
        AccountLinks.replace_user_links(
          i.id,
          [%{remote_account_id: "r1", remote_username: "R", user_id: user.id}],
          :admin_mapped
        )

      assert {:error, %Error{type: :capability_denied, message: msg}} =
               HostFunctions.link_request(
                 plugin(@links_grant),
                 i,
                 pending.id,
                 get_request("http://127.0.0.1:1/x"),
                 gate_opts()
               )

      assert msg =~ "no token"
    end

    test "requires net:http as well as users:connections", %{instance: i, owner: owner} do
      assert {:error, %Error{type: :capability_denied}} =
               HostFunctions.link_request(
                 plugin(%{"users:connections" => []}),
                 i,
                 owner.id,
                 get_request("http://127.0.0.1:1/x"),
                 gate_opts()
               )
    end
  end

  describe "1.1-1.3 connections stay user-only" do
    test "connections_list omits owner and endpoint credentials and disabled links", %{
      instance: i
    } do
      {:ok, _} = AccountLinks.put_credential(i.id, :endpoint, "srv")
      user = user_fixture()
      gone = user_fixture()

      {:ok, [_, disabled]} =
        AccountLinks.replace_user_links(
          i.id,
          [
            %{remote_account_id: "r1", remote_username: "A", user_id: user.id},
            %{remote_account_id: "r2", remote_username: "B", user_id: gone.id}
          ],
          :admin_mapped
        )
        |> then(fn {:ok, links} -> {:ok, Enum.sort_by(links, & &1.external_user_id)} end)

      :ok = AccountLinks.set_status(disabled.id, :disabled, nil)

      assert {:ok, [record]} = HostFunctions.connections_list(plugin(@links_grant), i)
      assert record[:"user-id"] == user.id
    end

    test "connection_request refuses an owner credential", %{instance: i, owner: owner} do
      assert {:error, %Error{type: :not_found}} =
               HostFunctions.connection_request(
                 plugin(@links_grant),
                 owner.id,
                 get_request("http://127.0.0.1:1/x"),
                 [instance: i] ++ gate_opts()
               )
    end
  end

  describe "propose_accounts/3" do
    test "stores remote accounts on the instance", %{instance: i} do
      accounts = [%{id: "r1", name: "Robin", admin: true}, %{id: "r2", name: "Sam", admin: false}]
      assert :ok = HostFunctions.propose_accounts(plugin(@links_grant), i, accounts)

      assert Instances.get!(i.id).remote_accounts == [
               %{"id" => "r1", "name" => "Robin", "admin" => true},
               %{"id" => "r2", "name" => "Sam", "admin" => false}
             ]
    end

    test "caps the list at 500 and rejects malformed entries", %{instance: i} do
      too_many = for n <- 1..501, do: %{id: "r#{n}", name: "N", admin: false}

      assert {:error, %Error{type: :invalid_request}} =
               HostFunctions.propose_accounts(plugin(@links_grant), i, too_many)

      assert {:error, %Error{type: :invalid_request}} =
               HostFunctions.propose_accounts(plugin(@links_grant), i, [
                 %{id: "", name: "x", admin: false}
               ])
    end
  end

  describe "set_link_token/4 and set_link_status/5" do
    test "only touch links of the calling instance", %{instance: i, other: o} do
      {:ok, foreign} = AccountLinks.put_credential(o.id, :owner, "x")

      assert {:error, %Error{type: :not_found}} =
               HostFunctions.set_link_token(plugin(@links_grant), i, foreign.id, "t")

      assert {:error, %Error{type: :not_found}} =
               HostFunctions.set_link_status(plugin(@links_grant), i, foreign.id, :error, :none)
    end

    test "update the link", %{instance: i} do
      user = user_fixture()

      {:ok, [link]} =
        AccountLinks.replace_user_links(
          i.id,
          [%{remote_account_id: "r1", remote_username: "R", user_id: user.id}],
          :admin_mapped
        )

      assert :ok = HostFunctions.set_link_token(plugin(@links_grant), i, link.id, "minted")
      assert AccountLinks.get(link.id).access_token == "minted"

      assert :ok =
               HostFunctions.set_link_status(
                 plugin(@links_grant),
                 i,
                 link.id,
                 :error,
                 {:some, "401"}
               )

      assert %{status: :error, last_error: "401"} = AccountLinks.get(link.id)
    end

    test "reject an empty or oversized token", %{instance: i, owner: owner} do
      assert {:error, %Error{type: :invalid_request}} =
               HostFunctions.set_link_token(plugin(@links_grant), i, owner.id, "")

      assert {:error, %Error{type: :invalid_request}} =
               HostFunctions.set_link_token(
                 plugin(@links_grant),
                 i,
                 owner.id,
                 String.duplicate("a", 4097)
               )
    end
  end

  describe "through a real 1.4 guest" do
    setup do
      {:ok, _} =
        Host.start_plugin(@slug, File.read!(@fixture),
          imports: HostFunctions.imports_for(@slug, gate_opts())
        )

      {:ok, _} = Registry.register(@slug, plugin(@links_grant))

      on_exit(fn ->
        Host.stop_plugin(@slug)
        Registry.clear()
      end)

      :ok
    end

    test "links-list and propose-accounts marshal across the boundary", %{instance: i} do
      assert {:ok, %{"links" => [%{"role" => "owner", "status" => "active", "user_id" => nil}]}} =
               Host.call(@slug, "handle", %{"event" => "links_list"}, instance_id: i.id)

      accounts = [%{"id" => "r1", "name" => "Robin", "admin" => true}]

      assert {:ok, %{"ok" => true}} =
               Host.call(
                 @slug,
                 "handle",
                 %{"event" => "propose_accounts", "accounts" => accounts},
                 instance_id: i.id
               )

      assert [%{"id" => "r1", "admin" => true}] = Instances.get!(i.id).remote_accounts
    end

    test "set-link-status marshals the enum and option", %{instance: i, owner: owner} do
      assert {:ok, %{"ok" => true}} =
               Host.call(
                 @slug,
                 "handle",
                 %{
                   "event" => "set_link_status",
                   "link_id" => owner.id,
                   "status" => "error",
                   "message" => "remote said 401"
                 },
                 instance_id: i.id
               )

      assert %{status: :error, last_error: "remote said 401"} = AccountLinks.get(owner.id)
    end

    test "link-request injects the token for the guest", %{instance: i, owner: owner} do
      bypass = Bypass.open()
      parent = self()

      Bypass.expect_once(bypass, "GET", "/ping", fn conn ->
        send(parent, {:token, Plug.Conn.get_req_header(conn, "x-plex-token")})
        Plug.Conn.resp(conn, 204, "")
      end)

      assert {:ok, %{"status" => 204}} =
               Host.call(
                 @slug,
                 "handle",
                 %{
                   "event" => "link_request",
                   "link_id" => owner.id,
                   "url" => "http://127.0.0.1:#{bypass.port}/ping"
                 },
                 instance_id: i.id
               )

      assert_received {:token, ["acct-token"]}
    end

    test "a link op with no instance in the invocation is not found" do
      assert {:error, %Error{type: :guest_error, message: msg}} =
               Host.call(@slug, "handle", %{"event" => "links_list"})

      assert msg =~ "NotFound"
    end
  end
end
