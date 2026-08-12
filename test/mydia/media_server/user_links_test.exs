defmodule Mydia.MediaServer.UserLinksTest do
  # DataCase rather than ExUnit.Case: apply_mapping/3 writes media_server_user_links.
  use Mydia.DataCase, async: true

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
      # The account id a link stores is the profile's uuid, never the numeric id
      # beside it: the switch endpoint that mints a per-profile token answers 404
      # for the numeric one, so a link built on it could never sync at all.
      stub_home_users(bypass)

      assert {:ok, accounts} =
               UserLinks.list_remote_accounts(plex_config(bypass), plex_opts(bypass))

      assert Enum.map(accounts, & &1.id) == ["uuid-owner", "uuid-kid"]
      assert Enum.map(accounts, & &1.admin?) == [true, false]
    end
  end

  describe "apply_mapping/3 on Jellyfin" do
    setup %{bypass: bypass} do
      stub_json(bypass, "GET", "/Users", [
        %{"Id" => "guid-1", "Name" => "Tonix"},
        %{"Id" => "guid-2", "Name" => "Kid"}
      ])

      {:ok, config: jellyfin_config(bypass)}
    end

    test "stores the account GUID and leaves the token nil", %{config: config, user: user} do
      # Jellyfin issues no per-user tokens, so the GUID is the whole identity and
      # a token here could only be another account's.
      assert {:ok, [link]} = UserLinks.apply_mapping(config, %{"guid-1" => user.id})

      assert link.user_id == user.id
      assert link.remote_user_id == "guid-1"
      assert link.remote_username == "Tonix"
      assert is_nil(link.access_token)
    end

    test "refuses to point two accounts at one Mydia user", %{config: config, user: user} do
      assert {:error, :duplicate_user} =
               UserLinks.apply_mapping(config, %{"guid-1" => user.id, "guid-2" => user.id})

      assert Settings.list_media_server_user_links(config.id) == []
    end

    test "an account id the server does not list is ignored", %{config: config, user: user} do
      assert {:ok, []} = UserLinks.apply_mapping(config, %{"guid-forged" => user.id})
      assert Settings.list_media_server_user_links(config.id) == []
    end

    test "swapping two users' accounts is applied, not refused", %{config: config, user: user} do
      other = Mydia.AccountsFixtures.user_fixture(%{username: "kid"})

      assert {:ok, _} =
               UserLinks.apply_mapping(config, %{"guid-1" => user.id, "guid-2" => other.id})

      # The per-row claim guard would read this as a double claim while the rows
      # it is about to overwrite are still there. What has to hold is the final
      # state, and the final state here is fine.
      assert {:ok, _} =
               UserLinks.apply_mapping(config, %{"guid-1" => other.id, "guid-2" => user.id})

      links = Settings.list_media_server_user_links(config.id)
      assert Enum.find(links, &(&1.user_id == user.id)).remote_user_id == "guid-2"
      assert Enum.find(links, &(&1.user_id == other.id)).remote_user_id == "guid-1"
    end
  end

  describe "apply_mapping/3 on Plex" do
    setup %{bypass: bypass} do
      stub_home_users(bypass)

      {:ok, config: plex_config(bypass)}
    end

    test "links a profile whose name matches no Mydia user at all",
         %{bypass: bypass, config: config, user: user} do
      # Auto-matching only fires when Plex and Mydia agree on a name. People
      # name Plex profiles after people and their Mydia account "admin", so on
      # most installs it matches nothing and there was no other way to link.
      Bypass.expect(bypass, "POST", "/api/v2/home/users/uuid-kid/switch", fn conn ->
        json(conn, %{"authToken" => "kid-token"})
      end)

      assert {:ok, [link]} =
               UserLinks.apply_mapping(config, %{"uuid-kid" => user.id}, plex_opts(bypass))

      assert link.user_id == user.id
      assert link.remote_user_id == "uuid-kid"
      assert link.remote_username == "kid"
      # The token names the same account as remote_user_id. A link claiming one
      # account while holding another's credential syncs the wrong history.
      assert link.access_token == "kid-token"
    end

    test "removes the link for a profile the operator unmapped",
         %{bypass: bypass, config: config, user: user} do
      stub_switch(bypass, "uuid-kid", "kid-token")

      assert {:ok, [_link]} =
               UserLinks.apply_mapping(config, %{"uuid-kid" => user.id}, plex_opts(bypass))

      assert {:ok, []} = UserLinks.apply_mapping(config, %{"uuid-kid" => nil}, plex_opts(bypass))
      assert Settings.list_media_server_user_links(config.id) == []
    end

    test "refuses to point two profiles at one Mydia user",
         %{bypass: bypass, config: config, user: user} do
      # The links table is unique on (config, user), so this would not fail
      # loudly: the second profile would overwrite the first and one of them
      # would sit in the UI looking linked while syncing nothing.
      assert {:error, :duplicate_user} =
               UserLinks.apply_mapping(
                 config,
                 %{"uuid-owner" => user.id, "uuid-kid" => user.id},
                 plex_opts(bypass)
               )
    end

    test "a failed token mint leaves the existing mapping untouched",
         %{bypass: bypass, config: config, user: user} do
      # Deleting before minting meant a mint that failed had already unlinked
      # somebody who was syncing fine, and the operator saw only an error.
      stub_switch(bypass, "uuid-kid", "kid-token")

      Bypass.stub(
        bypass,
        "POST",
        "/api/v2/home/users/uuid-owner/switch",
        &Plug.Conn.resp(&1, 500, "")
      )

      owner = Mydia.AccountsFixtures.user_fixture(%{username: "owner"})

      assert {:ok, [_]} =
               UserLinks.apply_mapping(config, %{"uuid-kid" => user.id}, plex_opts(bypass))

      # Unmap the kid and map the owner in one save. The owner's mint fails, so
      # the save must not have unlinked the kid on its way there.
      assert {:error, _} =
               UserLinks.apply_mapping(
                 config,
                 %{"uuid-owner" => owner.id, "uuid-kid" => nil},
                 plex_opts(bypass)
               )

      assert [link] = Settings.list_media_server_user_links(config.id)
      assert link.user_id == user.id
      assert link.remote_user_id == "uuid-kid"
      assert link.access_token == "kid-token"
    end

    test "re-saving an unchanged mapping does not mint a fresh token",
         %{bypass: bypass, config: config, user: user} do
      {:ok, switches} = Agent.start_link(fn -> 0 end)

      Bypass.stub(bypass, "POST", "/api/v2/home/users/uuid-kid/switch", fn conn ->
        Agent.update(switches, &(&1 + 1))
        json(conn, %{"authToken" => "kid-token"})
      end)

      assert {:ok, [_]} =
               UserLinks.apply_mapping(config, %{"uuid-kid" => user.id}, plex_opts(bypass))

      assert {:ok, [_]} =
               UserLinks.apply_mapping(config, %{"uuid-kid" => user.id}, plex_opts(bypass))

      assert Agent.get(switches, & &1) == 1
    end

    test "moving a profile to a different user mints that profile's token afresh",
         %{bypass: bypass, config: config, user: user} do
      # The reuse path matches on the account *and* the user, so a repoint never
      # carries the previous holder's credential onto the new row.
      stub_switch(bypass, "uuid-kid", "kid-token")
      other = Mydia.AccountsFixtures.user_fixture(%{username: "sarah"})

      assert {:ok, [first]} =
               UserLinks.apply_mapping(config, %{"uuid-kid" => user.id}, plex_opts(bypass))

      assert first.access_token == "kid-token"

      assert {:ok, [moved]} =
               UserLinks.apply_mapping(config, %{"uuid-kid" => other.id}, plex_opts(bypass))

      assert moved.user_id == other.id
      assert moved.remote_user_id == "uuid-kid"
      assert moved.access_token == "kid-token"
      assert [^moved] = Settings.list_media_server_user_links(config.id)
    end
  end

  test "a provider without per-user accounts is refused rather than guessed at",
       %{user: user} do
    config = %MediaServerConfig{id: Ecto.UUID.generate(), name: "Other", type: nil}

    assert {:error, {:unsupported_provider, nil}} =
             UserLinks.apply_mapping(config, %{"x" => user.id})
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

  defp stub_home_users(bypass) do
    stub_json(bypass, "GET", "/api/v2/home/users", %{
      "users" => [
        %{"id" => 1, "uuid" => "uuid-owner", "username" => "owner", "admin" => true},
        %{"id" => 2, "uuid" => "uuid-kid", "username" => "kid", "admin" => false}
      ]
    })
  end

  defp stub_switch(bypass, account_id, token) do
    Bypass.stub(bypass, "POST", "/api/v2/home/users/#{account_id}/switch", fn conn ->
      json(conn, %{"authToken" => token})
    end)
  end

  # Req only decodes a body the response declares as JSON.
  defp stub_json(bypass, method, path, body) do
    Bypass.stub(bypass, method, path, fn conn -> json(conn, body) end)
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end
end
