defmodule Mydia.MediaServer.Plex.HomeTest do
  # DataCase rather than ExUnit.Case: seed_links/2 persists user links.
  use Mydia.DataCase, async: true

  alias Mydia.MediaServer.Plex.Home
  alias Mydia.MediaServer.SeedResult
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

      assert {:ok, %SeedResult{linked: links}} = Home.seed_links(saved, plex_tv_base: base)

      refute Enum.any?(links, &(&1.user_id == user.id))
    end
  end

  describe "seed_links/2 owner fallback" do
    test "leaves an existing mapping alone instead of reverting it to the owner",
         %{bypass: bypass, config: config, base: base} do
      # A 404 means the account has no Plex Home, and a bad minute at plex.tv
      # reads the same way here. The fallback link carries no remote_user_id and
      # the upsert replaces that column, so writing it would quietly undo the
      # profile the operator picked by hand.
      Bypass.stub(bypass, "GET", "/api/v2/home/users", fn conn ->
        Plug.Conn.resp(conn, 404, "")
      end)

      admin = Mydia.AccountsFixtures.admin_user_fixture(%{username: "owner"})
      {:ok, saved} = Mydia.Settings.create_media_server_config(persistable(config))

      {:ok, hand_made} =
        Mydia.Settings.upsert_media_server_user_link(%{
          media_server_config_id: saved.id,
          user_id: admin.id,
          remote_user_id: "uuid-kid",
          remote_username: "kid",
          access_token: "kid-token",
          enabled: true
        })

      assert {:ok, %SeedResult{linked: [], already_mapped: ["kid"]}} =
               Home.seed_links(saved, plex_tv_base: base)

      assert [kept] = Mydia.Settings.list_media_server_user_links(saved.id)
      assert kept.id == hand_made.id
      assert kept.remote_user_id == "uuid-kid"
      assert kept.access_token == "kid-token"
    end

    test "still creates the owner link when nothing is mapped yet",
         %{bypass: bypass, config: config, base: base} do
      Bypass.stub(bypass, "GET", "/api/v2/home/users", fn conn ->
        Plug.Conn.resp(conn, 404, "")
      end)

      admin = Mydia.AccountsFixtures.admin_user_fixture(%{username: "owner"})
      {:ok, saved} = Mydia.Settings.create_media_server_config(persistable(config))

      assert {:ok, %SeedResult{linked: [link], already_mapped: [], owner_fallback: :linked}} =
               Home.seed_links(saved, plex_tv_base: base)

      assert link.user_id == admin.id
      assert link.remote_user_id == nil
      assert link.access_token == saved.token
    end

    test "refuses to pick an owner when this install has more than one admin",
         %{bypass: bypass, config: config, base: base} do
      # The fallback link carries config.token, the credential of whoever ran
      # OAuth. With one admin that is necessarily them. With two, taking the
      # first by query order binds admin A's Mydia account to admin B's Plex
      # watch state, which is the cross-account merge this mapping exists to
      # prevent, so nothing is written and the operator maps it by hand.
      Bypass.stub(bypass, "GET", "/api/v2/home/users", fn conn ->
        Plug.Conn.resp(conn, 404, "")
      end)

      Mydia.AccountsFixtures.admin_user_fixture(%{username: "first-admin"})
      Mydia.AccountsFixtures.admin_user_fixture(%{username: "second-admin"})
      {:ok, saved} = Mydia.Settings.create_media_server_config(persistable(config))

      assert {:ok, %SeedResult{linked: [], owner_fallback: :ambiguous}} =
               Home.seed_links(saved, plex_tv_base: base)

      assert Mydia.Settings.list_media_server_user_links(saved.id) == []
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
