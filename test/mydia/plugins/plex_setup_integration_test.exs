defmodule Mydia.Plugins.PlexSetupIntegrationTest do
  use Mydia.PlexPluginCase

  alias Mydia.Plugins.Setup

  # A setup test drives a fresh instance through the host's setup driver, which
  # stores the credentials and approves the endpoints the guest's screens carry.
  defp fresh_instance(tv_base) do
    {:ok, instance} =
      Instances.create("plex", %{
        name: "Attic",
        settings: %{"plex_tv_base" => tv_base, "sync_watched" => "on"}
      })

    instance
  end

  # Bypass matches `:who` in a stub path but does not fill `conn.path_params`,
  # so read the profile id out of `/api/v2/home/users/<who>/switch`.
  defp switched(conn), do: conn.path_info |> Enum.at(-2)

  defp stub_pin(plex_tv, authorize_after) do
    {:ok, polls} = Agent.start_link(fn -> 0 end)

    Bypass.stub(plex_tv, "POST", "/api/v2/pins", fn conn ->
      json(conn, 201, %{"id" => 4242, "code" => "WXYZ"})
    end)

    Bypass.stub(plex_tv, "GET", "/api/v2/pins/4242", fn conn ->
      n = Agent.get_and_update(polls, &{&1, &1 + 1})
      token = if n >= authorize_after, do: "account-token", else: nil
      json(conn, 200, %{"id" => 4242, "code" => "WXYZ", "authToken" => token})
    end)
  end

  defp stub_resources(plex_tv, server) do
    Bypass.stub(plex_tv, "GET", "/api/v2/resources", fn conn ->
      json(conn, 200, [
        %{
          "name" => "Attic Server",
          "provides" => "server",
          "clientIdentifier" => "machine-1",
          "owned" => true,
          "presence" => true,
          "accessToken" => "server-token",
          "connections" => [
            %{
              "protocol" => "http",
              "uri" => "http://127.0.0.1:#{server.port}",
              "local" => true,
              "relay" => false
            }
          ]
        }
      ])
    end)

    FakePlexServer.stub(server, "GET", "/library/sections", fn conn ->
      json(conn, 200, %{"MediaContainer" => %{"Directory" => []}})
    end)
  end

  defp to_server_choice(instance) do
    {:ok, s} = Setup.start("plex", instance, [])
    assert {:choice, %{options: methods}} = s.screen.body
    assert Enum.map(methods, & &1.id) == ["signin", "manual"]

    {:ok, s} = Setup.advance(s, %{"option_id" => "signin"})
    assert {:external_auth, %{url: url}} = s.screen.body
    assert url =~ "WXYZ"

    # Not authorized yet: the guest keeps polling.
    {:ok, s} = Setup.poll(s)
    assert {:external_auth, _} = s.screen.body

    {:ok, s} = Setup.poll(s)
    assert {:choice, %{options: [option]}} = s.screen.body
    assert option.id == "machine-1"
    s
  end

  test "sign-in walks to a server, a mapping, a per-profile token by uuid, and done",
       %{plex_tv: plex_tv, server: server, tv_base: tv_base} do
    # `server-token` below is what plex.tv lists as the server's accessToken.
    test_pid = self()
    instance = fresh_instance(tv_base)
    stub_pin(plex_tv, 1)
    stub_resources(plex_tv, server)

    Bypass.stub(plex_tv, "GET", "/api/v2/user", fn conn ->
      json(conn, 200, %{"uuid" => "uuid-admin", "username" => "admin", "title" => "admin"})
    end)

    Bypass.stub(plex_tv, "GET", "/api/v2/home/users", fn conn ->
      json(conn, 200, %{
        "users" => [
          %{
            "id" => 1,
            "uuid" => "uuid-admin",
            "title" => "admin",
            "username" => "admin",
            "admin" => true
          },
          # A nameless profile, listed by its title.
          %{
            "id" => 2,
            "uuid" => "uuid-kid",
            "title" => "Kid",
            "username" => nil,
            "admin" => false
          }
        ]
      })
    end)

    # Switch is by uuid. The numeric id answers 404 on the real service.
    Bypass.stub(plex_tv, "POST", "/api/v2/home/users/:who/switch", fn conn ->
      send(test_pid, {:switch, switched(conn), token(conn)})

      case switched(conn) do
        "uuid-kid" -> json(conn, 201, %{"authToken" => "kid-token"})
        _ -> Plug.Conn.resp(conn, 404, "")
      end
    end)

    s = to_server_choice(instance)

    # An SSO-provisioned user must not break the host's name matching.
    sso = oidc_user_fixture()
    kid = user_fixture(%{username: "kid"})

    {:ok, s} = Setup.advance(s, %{"option_id" => "machine-1"})
    assert {:mapping, %{accounts: accounts, suggestions: suggestions}} = s.screen.body

    assert accounts |> Enum.map(&{&1.id, &1.name}) |> Enum.sort() == [
             {"uuid-admin", "admin"},
             {"uuid-kid", "Kid"}
           ]

    # The name match still works around the SSO user.
    assert %{remote_account_id: "uuid-kid", user_id: kid.id} in suggestions
    # The first OIDC user is the instance's sole admin, so the owner-style admin
    # profile falls back to it and nothing else does.
    assert sso.role == :admin or sso.role == "admin"
    assert %{remote_account_id: "uuid-admin", user_id: sso.id} in suggestions
    assert length(suggestions) == 2

    {:ok, s} = Setup.advance(s, %{"mapping" => %{"uuid-kid" => kid.id, "uuid-admin" => ""}})
    assert s.status == :done

    assert_received {:switch, "uuid-kid", "account-token"}
    refute_received {:switch, "2", _}

    links = AccountLinks.list(instance.id)
    link = Enum.find(links, &(&1.user_id == kid.id))
    assert %{access_token: "kid-token", status: :active} = AccountLinks.get(link.id)
    refute Enum.any?(links, &(&1.user_id == sso.id))

    # The chosen server's address is approved, and the two credentials are the
    # PIN account token (owner) and the server's own accessToken (endpoint).
    instance = Instances.get!(instance.id)

    assert Enum.any?(instance.approved_endpoints, fn e ->
             e["host"] == "127.0.0.1" and e["port"] == server.port
           end)

    assert %{access_token: "account-token"} = AccountLinks.credential(instance.id, :owner)
    assert %{access_token: "server-token"} = AccountLinks.credential(instance.id, :endpoint)

    # The configured instance can sync: its first tick reaches the server with
    # the endpoint credential.
    test_pid = self()

    FakePlexServer.stub(server, "GET", "/library/sections", fn conn ->
      send(test_pid, {:sections, token(conn)})
      json(conn, 200, %{"MediaContainer" => %{"Directory" => []}})
    end)

    assert {:ok, _} = Plugins.invoke_plugin_schedule("plex", instance.id)
    assert_received {:sections, "server-token"}

    assert {:ok, %{status: :ok}} = Plugins.invoke_check_health("plex", instance.id)
  end

  test "a failed profile switch marks only that link",
       %{plex_tv: plex_tv, server: server, tv_base: tv_base} do
    instance = fresh_instance(tv_base)
    stub_pin(plex_tv, 0)
    stub_resources(plex_tv, server)

    Bypass.stub(plex_tv, "GET", "/api/v2/user", fn conn ->
      json(conn, 200, %{"uuid" => "uuid-admin", "username" => "admin"})
    end)

    Bypass.stub(plex_tv, "GET", "/api/v2/home/users", fn conn ->
      json(conn, 200, %{
        "users" => [
          %{"uuid" => "uuid-kid", "title" => "Kid"},
          %{"uuid" => "uuid-gran", "title" => "Gran"}
        ]
      })
    end)

    Bypass.stub(plex_tv, "POST", "/api/v2/home/users/:who/switch", fn conn ->
      case switched(conn) do
        "uuid-gran" -> json(conn, 201, %{"authToken" => "gran-token"})
        _ -> Plug.Conn.resp(conn, 500, "")
      end
    end)

    {:ok, s} = Setup.start("plex", instance, [])
    {:ok, s} = Setup.advance(s, %{"option_id" => "signin"})
    {:ok, s} = Setup.poll(s)
    {:ok, s} = Setup.advance(s, %{"option_id" => "machine-1"})

    kid = user_fixture()
    gran = user_fixture()
    {:ok, s} = Setup.advance(s, %{"mapping" => %{"uuid-kid" => kid.id, "uuid-gran" => gran.id}})
    assert s.status == :done

    links = AccountLinks.list(instance.id)

    assert %{status: :error, last_error: "token_mint_failed"} =
             Enum.find(links, &(&1.user_id == kid.id))

    assert %{status: :active, access_token: "gran-token"} =
             Enum.find(links, &(&1.user_id == gran.id))
  end

  test "an account with no Plex Home maps the owner account without a switch",
       %{plex_tv: plex_tv, server: server, tv_base: tv_base} do
    test_pid = self()
    instance = fresh_instance(tv_base)
    stub_pin(plex_tv, 0)
    stub_resources(plex_tv, server)
    admin = admin_user_fixture()

    Bypass.stub(plex_tv, "GET", "/api/v2/home/users", fn conn -> Plug.Conn.resp(conn, 404, "") end)

    Bypass.stub(plex_tv, "GET", "/api/v2/user", fn conn ->
      json(conn, 200, %{"uuid" => "uuid-owner", "username" => "someone-else", "title" => "Owner"})
    end)

    Bypass.stub(plex_tv, "POST", "/api/v2/home/users/:who/switch", fn conn ->
      send(test_pid, {:switch, switched(conn)})
      Plug.Conn.resp(conn, 404, "")
    end)

    {:ok, s} = Setup.start("plex", instance, [])
    {:ok, s} = Setup.advance(s, %{"option_id" => "signin"})
    {:ok, s} = Setup.poll(s)
    {:ok, s} = Setup.advance(s, %{"option_id" => "machine-1"})

    assert {:mapping, %{accounts: [owner], suggestions: suggestions}} = s.screen.body
    assert owner.admin
    # Task 9's owner fallback: the sole Mydia admin is suggested for the owner.
    assert %{remote_account_id: "uuid-owner", user_id: admin.id} in suggestions

    {:ok, s} = Setup.advance(s, %{"mapping" => %{"uuid-owner" => admin.id}})
    assert s.status == :done
    refute_received {:switch, _}

    link = instance.id |> AccountLinks.list() |> Enum.find(&(&1.user_id == admin.id))
    assert {:ok, "1"} = Kv.get(instance.id, "link/#{link.id}/uses_owner")
  end

  test "a server that moved asks the operator to confirm new endpoints",
       %{plex_tv: plex_tv, server: server, instance: instance} do
    user = user_fixture()
    link_user!(instance, user, "user-token")
    test_pid = self()

    # No typed URL: the guest works from the addresses stored at setup.
    {:ok, instance} =
      Instances.update(instance, %{settings: Map.delete(instance.settings, "url")})

    {:ok, _} =
      Kv.set(
        instance.id,
        "server/info",
        Jason.encode!(%{
          machine_identifier: "machine-1",
          name: "Den",
          candidates: ["http://127.0.0.1:#{server.port}"]
        })
      )

    # The approved address stops answering.
    FakePlexServer.down(server)

    moved = Bypass.open()

    Bypass.stub(moved, "GET", "/library/sections", fn conn ->
      send(test_pid, :contacted_unapproved_endpoint)
      json(conn, 200, %{"MediaContainer" => %{"Directory" => []}})
    end)

    Bypass.stub(plex_tv, "GET", "/api/v2/resources", fn conn ->
      json(conn, 200, [
        %{
          "name" => "Den",
          "provides" => "server",
          "clientIdentifier" => "machine-1",
          "connections" => [%{"uri" => "http://moved.plex.test:#{moved.port}", "local" => true}]
        }
      ])
    end)

    assert {:ok, %{"skipped" => "unreachable"}} =
             Plugins.invoke_plugin_schedule("plex", instance.id)

    refute_received :contacted_unapproved_endpoint
    assert {:ok, pending} = Kv.get(instance.id, "server/pending")
    assert pending =~ "moved.plex.test"

    assert {:ok, %{status: :unreachable, action: :confirm_endpoints}} =
             Plugins.invoke_check_health("plex", instance.id)

    # The operator confirms the new address through the setup step.
    {:ok, s} = Setup.start("plex", instance, step: "confirm-endpoints")
    assert {:choice, %{options: [option]}} = s.screen.body
    assert [%{host: "moved.plex.test"}] = option.endpoints
    {:ok, s} = Setup.advance(s, %{"option_id" => option.id})
    assert s.status == :done
    assert {:ok, nil} = Kv.get(instance.id, "server/pending")

    # Approved now, the next tick reaches the new address.
    while_flush_contacts()
    assert {:ok, _} = Plugins.invoke_plugin_schedule("plex", instance.id)
    assert_received :contacted_unapproved_endpoint
    assert {:ok, %{status: :ok}} = Plugins.invoke_check_health("plex", instance.id)
  end

  # Drops the probe messages the confirm step itself caused, so the assertion
  # after it proves the following tick made its own request.
  defp while_flush_contacts do
    receive do
      :contacted_unapproved_endpoint -> while_flush_contacts()
    after
      0 -> :ok
    end
  end
end
