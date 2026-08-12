defmodule Mydia.MediaServer.Plex.HomeTest do
  # DataCase rather than ExUnit.Case: seed_links/2 persists user links.
  use Mydia.DataCase, async: true

  alias Mydia.MediaServer.Plex.Home
  alias Mydia.Settings.MediaServerConfig

  setup do
    bypass = Bypass.open()
    config = %MediaServerConfig{name: "Storage", type: :plex, token: "account-token"}
    # plex_tv_base is the /api/v2 root (same shape as @plex_api_base in Home).
    {:ok, bypass: bypass, config: config, base: "http://127.0.0.1:#{bypass.port}/api/v2"}
  end

  test "identifies a Home user by uuid, not by the numeric id", %{
    bypass: bypass,
    config: config,
    base: base
  } do
    # The switch endpoint 404s on the numeric id, so taking `id` here meant no
    # per-user token could ever be minted and no matched link was ever created.
    Bypass.stub(bypass, "GET", "/api/v2/home/users", fn conn ->
      body =
        Jason.encode!(%{
          "users" => [
            %{"id" => 1, "uuid" => "uuid-owner", "username" => "owner", "admin" => true},
            %{"id" => 2, "uuid" => "uuid-kid", "username" => "kid", "admin" => false}
          ]
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, body)
    end)

    assert {:ok, users} = Home.list_users(config, plex_tv_base: base)
    assert length(users) == 2
    assert Enum.find(users, &(&1.username == "kid")).plex_account_id == "uuid-kid"
  end

  test "names a managed profile by its title when it has no username", %{
    bypass: bypass,
    config: config,
    base: base
  } do
    # Managed and guest profiles come back with a null username; only `title` is
    # set, and that is most of a household.
    Bypass.stub(bypass, "GET", "/api/v2/home/users", fn conn ->
      body =
        Jason.encode!(%{
          "users" => [
            %{
              "id" => 2,
              "uuid" => "uuid-camille",
              "username" => nil,
              "title" => "Camille",
              "admin" => false
            }
          ]
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, body)
    end)

    assert {:ok, [user]} = Home.list_users(config, plex_tv_base: base)
    assert user.username == "Camille"
    assert user.plex_account_id == "uuid-camille"
  end

  test "an account without Plex Home returns an empty list, not an error",
       %{bypass: bypass, config: config, base: base} do
    Bypass.stub(bypass, "GET", "/api/v2/home/users", fn conn ->
      Plug.Conn.resp(conn, 404, "")
    end)

    assert {:ok, []} = Home.list_users(config, plex_tv_base: base)
  end

  describe "token_for/3" do
    test "mints a per-user token by switching to the home user",
         %{bypass: bypass, config: config, base: base} do
      Bypass.expect(bypass, "POST", "/api/v2/home/users/uuid-kid/switch", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"authToken" => "kid-token"}))
      end)

      assert {:ok, "kid-token"} = Home.token_for(config, "uuid-kid", plex_tv_base: base)
    end

    test "a switch that returns no token is an error, never a silent fallback",
         %{bypass: bypass, config: config, base: base} do
      # Falling back to the admin token here would hand one account's watch
      # state to a different user, which is the merge bug this whole task
      # exists to remove. No link is strictly better than a wrong link.
      Bypass.stub(bypass, "POST", "/api/v2/home/users/uuid-kid/switch", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"id" => 2}))
      end)

      assert {:error, _} = Home.token_for(config, "uuid-kid", plex_tv_base: base)
    end

    test "a rejected switch surfaces as an auth error",
         %{bypass: bypass, config: config, base: base} do
      Bypass.stub(bypass, "POST", "/api/v2/home/users/uuid-kid/switch", fn conn ->
        Plug.Conn.resp(conn, 401, "")
      end)

      assert {:error, %Mydia.MediaServer.Error{kind: :auth}} =
               Home.token_for(config, "uuid-kid", plex_tv_base: base)
    end
  end

  describe "seed_links/2 token isolation" do
    test "a home user whose token cannot be minted gets no link at all",
         %{bypass: bypass, config: config, base: base} do
      Bypass.stub(bypass, "GET", "/api/v2/home/users", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "users" => [
              %{"id" => 2, "uuid" => "uuid-kid", "username" => "kid", "admin" => false}
            ]
          })
        )
      end)

      Bypass.stub(bypass, "POST", "/api/v2/home/users/uuid-kid/switch", fn conn ->
        Plug.Conn.resp(conn, 500, "")
      end)

      user = Mydia.AccountsFixtures.user_fixture(%{username: "kid"})
      {:ok, saved} = Mydia.Settings.create_media_server_config(persistable(config))

      assert {:ok, links} = Home.seed_links(saved, plex_tv_base: base)

      refute Enum.any?(links, &(&1.user_id == user.id))
    end
  end

  describe "apply_mapping/3" do
    setup %{bypass: bypass, config: config} do
      Bypass.stub(bypass, "GET", "/api/v2/home/users", fn conn ->
        body =
          Jason.encode!(%{
            "users" => [
              %{"id" => 1, "uuid" => "uuid-arsfeld", "username" => "arsfeld", "admin" => true},
              %{"id" => 2, "uuid" => "uuid-camille", "title" => "Camille", "admin" => false}
            ]
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      {:ok, saved} = Mydia.Settings.create_media_server_config(persistable(config))

      {:ok, saved: saved}
    end

    test "links a profile whose name matches no Mydia user at all",
         %{bypass: bypass, base: base, saved: saved} do
      # Auto-matching only fires when Plex and Mydia agree on a name. People
      # name Plex profiles after people and their Mydia account "admin", so on
      # most installs it matches nothing and there was no other way to link.
      Bypass.expect(bypass, "POST", "/api/v2/home/users/uuid-camille/switch", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"authToken" => "camille-token"}))
      end)

      user = Mydia.AccountsFixtures.user_fixture(%{username: "alex"})

      assert {:ok, [link]} =
               Home.apply_mapping(saved, %{"uuid-camille" => user.id}, plex_tv_base: base)

      assert link.user_id == user.id
      assert link.plex_account_id == "uuid-camille"
      assert link.plex_username == "Camille"
      assert link.access_token == "camille-token"
    end

    test "removes the link for a profile the operator unmapped",
         %{bypass: bypass, base: base, saved: saved} do
      Bypass.stub(bypass, "POST", "/api/v2/home/users/uuid-camille/switch", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"authToken" => "camille-token"}))
      end)

      user = Mydia.AccountsFixtures.user_fixture(%{username: "alex"})

      assert {:ok, [_link]} =
               Home.apply_mapping(saved, %{"uuid-camille" => user.id}, plex_tv_base: base)

      assert {:ok, []} = Home.apply_mapping(saved, %{"uuid-camille" => nil}, plex_tv_base: base)
      assert Mydia.Settings.list_media_server_user_links(saved.id) == []
    end

    test "refuses to point two profiles at one Mydia user",
         %{base: base, saved: saved} do
      # The links table is unique on (config, user), so this would not fail
      # loudly: the second profile would overwrite the first and one of them
      # would sit in the UI looking linked while syncing nothing.
      user = Mydia.AccountsFixtures.user_fixture(%{username: "alex"})

      assert {:error, :duplicate_user} =
               Home.apply_mapping(saved, %{"uuid-arsfeld" => user.id, "uuid-camille" => user.id},
                 plex_tv_base: base
               )
    end

    test "a failed token mint leaves the existing mapping untouched",
         %{bypass: bypass, base: base, saved: saved} do
      # Deleting before minting meant a mint that failed had already unlinked
      # somebody who was syncing fine, and the operator saw only an error.
      Bypass.stub(bypass, "POST", "/api/v2/home/users/uuid-camille/switch", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"authToken" => "camille-token"}))
      end)

      Bypass.stub(bypass, "POST", "/api/v2/home/users/uuid-arsfeld/switch", fn conn ->
        Plug.Conn.resp(conn, 500, "")
      end)

      camille = Mydia.AccountsFixtures.user_fixture(%{username: "alex"})
      owner = Mydia.AccountsFixtures.user_fixture(%{username: "arsfeld"})

      assert {:ok, [_]} =
               Home.apply_mapping(saved, %{"uuid-camille" => camille.id}, plex_tv_base: base)

      # Unmap Camille and map the owner in one save. The owner's mint fails, so
      # the save must not have unlinked Camille on its way there.
      assert {:error, _} =
               Home.apply_mapping(saved, %{"uuid-arsfeld" => owner.id, "uuid-camille" => nil},
                 plex_tv_base: base
               )

      assert [link] = Mydia.Settings.list_media_server_user_links(saved.id)
      assert link.user_id == camille.id
      assert link.plex_account_id == "uuid-camille"
    end

    test "re-saving an unchanged mapping does not mint a fresh token",
         %{bypass: bypass, base: base, saved: saved} do
      {:ok, switches} = Agent.start_link(fn -> 0 end)

      Bypass.stub(bypass, "POST", "/api/v2/home/users/uuid-camille/switch", fn conn ->
        Agent.update(switches, &(&1 + 1))

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"authToken" => "camille-token"}))
      end)

      user = Mydia.AccountsFixtures.user_fixture(%{username: "alex"})

      assert {:ok, [_]} =
               Home.apply_mapping(saved, %{"uuid-camille" => user.id}, plex_tv_base: base)

      assert {:ok, [_]} =
               Home.apply_mapping(saved, %{"uuid-camille" => user.id}, plex_tv_base: base)

      assert Agent.get(switches, & &1) == 1
    end
  end

  defp persistable(config) do
    %{
      name: "Storage #{System.unique_integer([:positive])}",
      type: :plex,
      url: "http://localhost:32400",
      token: config.token
    }
  end
end
