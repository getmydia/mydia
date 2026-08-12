defmodule Mydia.MediaServer.UserLinksTest do
  # DataCase rather than ExUnit.Case: link_user/4 writes media_server_user_links.
  use Mydia.DataCase, async: true

  alias Mydia.MediaServer.RemoteAccount
  alias Mydia.MediaServer.UserLinks
  alias Mydia.Settings
  alias Mydia.Settings.MediaServerConfig

  setup do
    %{bypass: Bypass.open(), user: Mydia.AccountsFixtures.user_fixture(%{username: "tonix"})}
  end

  describe "list_remote_accounts/2" do
    test "normalises Jellyfin accounts", %{bypass: bypass} do
      stub_json(bypass, "GET", "/Users", [
        %{"Id" => "guid-1", "Name" => "Tonix"},
        %{"Id" => "guid-2", "Name" => "Kid"}
      ])

      assert {:ok, accounts} = UserLinks.list_remote_accounts(jellyfin_config(bypass))
      assert Enum.map(accounts, & &1.id) == ["guid-1", "guid-2"]
      assert Enum.map(accounts, & &1.name) == ["Tonix", "Kid"]
    end

    test "normalises Plex Home profiles, keeping the owner flag", %{bypass: bypass} do
      stub_json(bypass, "GET", "/api/v2/home/users", %{
        "users" => [
          %{"id" => 1, "username" => "owner", "admin" => true},
          %{"id" => 2, "username" => "kid", "admin" => false}
        ]
      })

      assert {:ok, accounts} =
               UserLinks.list_remote_accounts(plex_config(bypass), plex_opts(bypass))

      assert Enum.map(accounts, & &1.id) == ["1", "2"]
      assert Enum.map(accounts, & &1.admin?) == [true, false]
    end
  end

  describe "link_user/4 on Jellyfin" do
    test "stores the account GUID and leaves the token nil",
         %{bypass: bypass, user: user} do
      config = jellyfin_config(bypass)
      account = %RemoteAccount{id: "guid-1", name: "Tonix"}

      assert {:ok, link} = UserLinks.link_user(config, user.id, account)

      assert link.remote_user_id == "guid-1"
      assert link.remote_username == "Tonix"
      # Jellyfin has no per-user token, so the identity is the GUID alone. A
      # token here could only be some other account's.
      assert link.access_token == nil
      assert reload(config, user).access_token == nil
    end

    test "clears a token an earlier write left behind", %{bypass: bypass, user: user} do
      config = jellyfin_config(bypass)

      {:ok, _stale} =
        Settings.upsert_media_server_user_link(%{
          media_server_config_id: config.id,
          user_id: user.id,
          remote_user_id: "guid-old",
          remote_username: "Old",
          access_token: "some-other-accounts-token",
          enabled: true
        })

      assert {:ok, _link} =
               UserLinks.link_user(config, user.id, %RemoteAccount{
                 id: "guid-1",
                 name: "Tonix"
               })

      link = reload(config, user)
      assert link.remote_user_id == "guid-1"
      assert link.access_token == nil
    end
  end

  describe "link_user/4 on Plex" do
    test "stores the freshly minted token next to the account it belongs to",
         %{bypass: bypass, user: user} do
      config = plex_config(bypass)
      stub_json(bypass, "POST", "/api/v2/home/users/2/switch", %{"authToken" => "kid-token"})

      {:ok, _owner_link} =
        Settings.upsert_media_server_user_link(%{
          media_server_config_id: config.id,
          user_id: user.id,
          remote_user_id: "1",
          remote_username: "owner",
          access_token: "owner-token",
          enabled: true
        })

      assert {:ok, _link} =
               UserLinks.link_user(
                 config,
                 user.id,
                 %RemoteAccount{id: "2", name: "kid"},
                 plex_opts(bypass)
               )

      link = reload(config, user)

      # Both columns move together. A link holding the owner's token while
      # naming the kid's profile would file the owner's history under the kid.
      assert link.remote_user_id == "2"
      assert link.access_token == "kid-token"
    end

    test "writes nothing when the token cannot be minted", %{bypass: bypass, user: user} do
      config = plex_config(bypass)

      Bypass.stub(bypass, "POST", "/api/v2/home/users/2/switch", fn conn ->
        Plug.Conn.resp(conn, 500, "")
      end)

      assert {:error, %Mydia.MediaServer.Error{}} =
               UserLinks.link_user(
                 config,
                 user.id,
                 %RemoteAccount{id: "2", name: "kid"},
                 plex_opts(bypass)
               )

      assert Settings.list_media_server_user_links(config.id) == []
    end

    test "leaves an existing link untouched when the token cannot be minted",
         %{bypass: bypass, user: user} do
      config = plex_config(bypass)

      Bypass.stub(bypass, "POST", "/api/v2/home/users/2/switch", fn conn ->
        Plug.Conn.resp(conn, 500, "")
      end)

      {:ok, _owner_link} =
        Settings.upsert_media_server_user_link(%{
          media_server_config_id: config.id,
          user_id: user.id,
          remote_user_id: "1",
          remote_username: "owner",
          access_token: "owner-token",
          enabled: true
        })

      assert {:error, _reason} =
               UserLinks.link_user(
                 config,
                 user.id,
                 %RemoteAccount{id: "2", name: "kid"},
                 plex_opts(bypass)
               )

      link = reload(config, user)
      assert link.remote_user_id == "1"
      assert link.access_token == "owner-token"
    end
  end

  describe "link_user/4 with :replaces" do
    test "reassigning a mapping to another Mydia user moves it, never claims twice",
         %{bypass: bypass, user: user} do
      config = jellyfin_config(bypass)
      other = Mydia.AccountsFixtures.user_fixture(%{username: "sarah"})
      account = %RemoteAccount{id: "guid-1", name: "Tonix"}

      assert {:ok, original} = UserLinks.link_user(config, user.id, account)

      assert {:ok, moved} = UserLinks.link_user(config, other.id, account, replaces: original)

      assert [only] = Settings.list_media_server_user_links(config.id)
      assert only.id == moved.id
      assert only.user_id == other.id
      assert only.remote_user_id == "guid-1"
    end

    test "a move onto a user who already has a mapping is refused, not silently collapsed",
         %{bypass: bypass, user: user} do
      # Editing A -> X onto Mydia user B, when B already has B -> Y, deleted A's
      # row while the upsert overwrote B's. Two mappings became one and the
      # operator was told the save succeeded.
      config = jellyfin_config(bypass)
      other = Mydia.AccountsFixtures.user_fixture(%{username: "sarah"})

      assert {:ok, a_link} =
               UserLinks.link_user(config, user.id, %RemoteAccount{id: "guid-x", name: "X"})

      assert {:ok, b_link} =
               UserLinks.link_user(config, other.id, %RemoteAccount{id: "guid-y", name: "Y"})

      assert {:error, :user_already_mapped} =
               UserLinks.link_user(config, other.id, %RemoteAccount{id: "guid-x", name: "X"},
                 replaces: a_link
               )

      links = Settings.list_media_server_user_links(config.id)
      assert length(links) == 2
      assert Enum.find(links, &(&1.id == a_link.id)).user_id == user.id
      assert Enum.find(links, &(&1.id == b_link.id)).remote_user_id == "guid-y"
    end

    test "a failed mint leaves the mapping it would have replaced in place",
         %{bypass: bypass, user: user} do
      config = plex_config(bypass)
      other = Mydia.AccountsFixtures.user_fixture(%{username: "sarah"})

      Bypass.stub(bypass, "POST", "/api/v2/home/users/2/switch", fn conn ->
        Plug.Conn.resp(conn, 500, "")
      end)

      {:ok, original} =
        Settings.upsert_media_server_user_link(%{
          media_server_config_id: config.id,
          user_id: user.id,
          remote_user_id: "1",
          remote_username: "owner",
          access_token: "owner-token",
          enabled: true
        })

      opts = Keyword.put(plex_opts(bypass), :replaces, original)

      assert {:error, _reason} =
               UserLinks.link_user(config, other.id, %RemoteAccount{id: "2", name: "kid"}, opts)

      assert [kept] = Settings.list_media_server_user_links(config.id)
      assert kept.id == original.id
      assert kept.access_token == "owner-token"
    end
  end

  test "an account already mapped to another user is refused, not reassigned",
       %{bypass: bypass, user: user} do
    config = jellyfin_config(bypass)
    other = Mydia.AccountsFixtures.user_fixture(%{username: "kid"})
    account = %RemoteAccount{id: "guid-1", name: "Tonix"}

    assert {:ok, _link} = UserLinks.link_user(config, user.id, account)

    # Both users would otherwise import the same account's history, which is the
    # same merge this mapping exists to prevent, just from the other direction.
    assert {:error, :account_already_mapped} = UserLinks.link_user(config, other.id, account)

    assert [link] = Settings.list_media_server_user_links(config.id)
    assert link.user_id == user.id
  end

  test "re-saving a user's own mapping is not treated as a claim by someone else",
       %{bypass: bypass, user: user} do
    config = jellyfin_config(bypass)
    account = %RemoteAccount{id: "guid-1", name: "Tonix"}

    assert {:ok, _link} = UserLinks.link_user(config, user.id, account)
    assert {:ok, _link} = UserLinks.link_user(config, user.id, account)
  end

  test "a provider without per-user accounts is refused rather than guessed at",
       %{user: user} do
    config = %MediaServerConfig{id: Ecto.UUID.generate(), name: "Other", type: nil}

    assert {:error, {:unsupported_provider, nil}} =
             UserLinks.link_user(config, user.id, %RemoteAccount{id: "x", name: "x"})
  end

  defp reload(config, user) do
    config.id
    |> Settings.list_media_server_user_links()
    |> Enum.find(&(&1.user_id == user.id))
  end

  defp jellyfin_config(bypass) do
    create_config(%{
      type: :jellyfin,
      url: "http://127.0.0.1:#{bypass.port}",
      token: "api-key"
    })
  end

  defp plex_config(bypass) do
    create_config(%{
      type: :plex,
      url: "http://127.0.0.1:#{bypass.port}",
      token: "account-token"
    })
  end

  defp create_config(attrs) do
    {:ok, config} =
      Settings.create_media_server_config(
        Map.put(attrs, :name, "Server #{System.unique_integer([:positive])}")
      )

    config
  end

  # plex_tv_base is the /api/v2 root, the same shape as Plex.Home's default.
  defp plex_opts(bypass), do: [plex_tv_base: "http://127.0.0.1:#{bypass.port}/api/v2"]

  # Req only decodes a body the response declares as JSON.
  defp stub_json(bypass, method, path, body) do
    Bypass.stub(bypass, method, path, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end
end
