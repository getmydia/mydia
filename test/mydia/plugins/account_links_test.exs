defmodule Mydia.Plugins.AccountLinksTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures

  alias Mydia.Plugins.AccountLink
  alias Mydia.Plugins.AccountLinks
  alias Mydia.Plugins.Instances
  alias Mydia.Plugins.Kv
  alias Mydia.Settings

  setup do
    {:ok, _} =
      Settings.create_plugin_config(%{
        slug: "linker",
        name: "Linker",
        version: "1.0.0",
        source_url: "test",
        manifest: %{
          "slug" => "linker",
          "name" => "Linker",
          "version" => "1.0.0",
          "capabilities" => %{}
        },
        granted_capabilities: %{},
        enabled: true
      })

    {:ok, instance} = Instances.create("linker", %{name: "Home"})
    {:ok, other} = Instances.create("linker", %{name: "Cabin"})
    %{instance: instance, other: other}
  end

  defp map_one(instance, user, remote_id \\ "r1", name \\ "Robin") do
    AccountLinks.replace_user_links(
      instance.id,
      [%{remote_account_id: remote_id, remote_username: name, user_id: user.id}],
      :admin_mapped
    )
  end

  describe "credentials" do
    test "put_credential creates then replaces the single owner link", %{instance: i} do
      assert {:ok, %AccountLink{role: :owner, source: :setup, user_id: nil} = first} =
               AccountLinks.put_credential(i.id, :owner, "tok-1")

      assert {:ok, second} = AccountLinks.put_credential(i.id, :owner, "tok-2")
      assert second.id == first.id
      assert AccountLinks.credential(i.id, :owner).access_token == "tok-2"
      assert AccountLinks.credential(i.id, :endpoint) == nil
    end

    test "owner and endpoint credentials coexist", %{instance: i} do
      {:ok, _} = AccountLinks.put_credential(i.id, :owner, "acct")
      {:ok, _} = AccountLinks.put_credential(i.id, :endpoint, "srv")
      assert AccountLinks.credential(i.id, :endpoint).access_token == "srv"
      assert length(AccountLinks.list(i.id)) == 2
    end

    test "inspect never shows the token", %{instance: i} do
      {:ok, link} = AccountLinks.put_credential(i.id, :owner, "super-secret-token")
      refute inspect(link) =~ "super-secret-token"
    end
  end

  describe "replace_user_links/3" do
    test "creates, updates and removes user links for one instance only", %{instance: i, other: o} do
      alice = user_fixture()
      bob = user_fixture()
      {:ok, _} = map_one(o, bob, "r9", "Zed")

      assert {:ok, links} =
               AccountLinks.replace_user_links(
                 i.id,
                 [
                   %{remote_account_id: "r1", remote_username: "Alice P", user_id: alice.id},
                   %{remote_account_id: "r2", remote_username: "Bob P", user_id: bob.id}
                 ],
                 :admin_mapped
               )

      assert links |> Enum.map(& &1.external_user_id) |> Enum.sort() == ["r1", "r2"]

      assert Enum.all?(
               links,
               &(&1.role == :user and &1.source == :admin_mapped and &1.status == :active)
             )

      {:ok, [_]} = map_one(i, alice, "r1", "Alice P")

      assert AccountLinks.user_link(i.id, bob.id) == nil
      assert AccountLinks.user_link(o.id, bob.id).external_user_id == "r9"
    end

    test "keeps the minted token while the same remote account stays mapped", %{instance: i} do
      alice = user_fixture()
      {:ok, [link]} = map_one(i, alice)
      :ok = AccountLinks.set_token(link.id, "minted")

      {:ok, [again]} = map_one(i, alice)
      assert again.id == link.id
      assert AccountLinks.get(again.id).access_token == "minted"
    end

    test "drops the token when a user is remapped to another remote account", %{instance: i} do
      alice = user_fixture()
      {:ok, [link]} = map_one(i, alice, "r1", "A")
      :ok = AccountLinks.set_token(link.id, "minted")

      {:ok, [moved]} = map_one(i, alice, "r2", "B")
      assert moved.external_user_id == "r2"
      assert AccountLinks.get(moved.id).access_token == nil
    end

    test "rejects a remote account mapped to two users", %{instance: i} do
      a = user_fixture()
      b = user_fixture()

      assert {:error, :duplicate_remote_account} =
               AccountLinks.replace_user_links(
                 i.id,
                 [
                   %{remote_account_id: "r1", remote_username: "X", user_id: a.id},
                   %{remote_account_id: "r1", remote_username: "X", user_id: b.id}
                 ],
                 :admin_mapped
               )
    end

    test "rejects one user mapped twice", %{instance: i} do
      a = user_fixture()

      assert {:error, :duplicate_user} =
               AccountLinks.replace_user_links(
                 i.id,
                 [
                   %{remote_account_id: "r1", remote_username: "X", user_id: a.id},
                   %{remote_account_id: "r2", remote_username: "Y", user_id: a.id}
                 ],
                 :admin_mapped
               )
    end
  end

  describe "status and token" do
    test "set_token stores the token and reactivates the link", %{instance: i} do
      u = user_fixture()
      {:ok, [link]} = map_one(i, u)
      :ok = AccountLinks.set_status(link.id, :error, "token_mint_failed")

      assert :ok = AccountLinks.set_token(link.id, "fresh")

      assert %{status: :active, last_error: nil, access_token: "fresh"} =
               AccountLinks.get(link.id)
    end

    test "set_status records the message; unknown ids are not found", %{instance: i} do
      {:ok, link} = AccountLinks.put_credential(i.id, :owner, "t")
      assert :ok = AccountLinks.set_status(link.id, :error, "401 from server")
      assert %{status: :error, last_error: "401 from server"} = AccountLinks.get(link.id)
      assert {:error, :not_found} = AccountLinks.set_status(Ecto.UUID.generate(), :active, nil)
      assert {:error, :not_found} = AccountLinks.set_token(Ecto.UUID.generate(), "x")
      assert {:error, :not_found} = AccountLinks.set_token("not-a-uuid", "x")
    end

    test "mark_errored flips only active user links of the instance", %{instance: i} do
      u = user_fixture()
      v = user_fixture()
      {:ok, _} = map_one(i, u)

      assert AccountLinks.mark_errored(i.id, [u.id, v.id, "not-a-uuid"]) == 1
      assert AccountLinks.user_link(i.id, u.id).status == :error
    end
  end

  describe "lookup and delete" do
    test "get_in_instance scopes by instance", %{instance: i, other: o} do
      {:ok, link} = AccountLinks.put_credential(i.id, :owner, "t")
      assert AccountLinks.get_in_instance(i.id, link.id).id == link.id
      assert AccountLinks.get_in_instance(o.id, link.id) == nil
      assert AccountLinks.get_in_instance(i.id, "not-a-uuid") == nil
    end

    test "list_for_user preloads the instance", %{instance: i} do
      u = user_fixture()
      {:ok, _} = map_one(i, u)
      assert [%AccountLink{instance: %{name: "Home"}}] = AccountLinks.list_for_user(u.id)
    end

    test "delete removes the link and sweeps its legacy store prefix", %{instance: i} do
      {:ok, link} = AccountLinks.put_credential(i.id, :owner, "t")
      {:ok, _} = Kv.set("linker", "conn/#{link.id}/cursor", "1")

      assert :ok = AccountLinks.delete(link)
      assert AccountLinks.get(link.id) == nil
      assert {:ok, nil} = Kv.get("linker", "conn/#{link.id}/cursor")
    end
  end
end
