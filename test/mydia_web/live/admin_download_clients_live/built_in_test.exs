defmodule MydiaWeb.AdminDownloadClientsLive.BuiltInTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.BuiltIn.{Config, Status}

  setup %{conn: conn} do
    unique_id = System.unique_integer([:positive])

    {:ok, user} =
      Mydia.Accounts.create_user(%{
        email: "admin_#{unique_id}@example.com",
        username: "admin_#{unique_id}",
        password_hash: "$2b$12$test",
        role: "admin"
      })

    {:ok, token, _} = Mydia.Auth.Guardian.encode_and_sign(user)

    conn =
      conn
      |> init_test_session(%{})
      |> put_session(:guardian_default_token, token)
      |> put_req_header("authorization", "Bearer #{token}")

    start_supervised!(Mydia.Indexers.Health)
    start_supervised!({Status, name: Status})

    BuiltIn.put_runtime(%{
      api_port: 3030,
      credentials: {"mydia", "x"},
      config: %Config{enabled?: true, vpn?: true, vpn_provider: "protonvpn"}
    })

    on_exit(&BuiltIn.clear_runtime/0)
    %{conn: conn}
  end

  test "shows engine, VPN and port state and updates live", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/clients")

    assert has_element?(view, "#built-in-torrent")
    assert has_element?(view, "#built-in-vpn-experimental")

    Status.put(:vpn, {:down, :missing_net_admin})
    assert render(element(view, "#built-in-vpn-state")) =~ "cap_add"

    Status.put(:vpn, {:up, %{provider: "protonvpn", public_ip: "203.0.113.9"}})
    Status.put(:port, {:forwarded, 40_123, DateTime.utc_now()})
    Status.put(:engine, :running)

    assert render(element(view, "#built-in-vpn-state")) =~ "203.0.113.9"
    assert render(element(view, "#built-in-port-state")) =~ "40123"
    assert render(element(view, "#built-in-engine-state")) =~ "Running"
  end

  test "restart with the engine not running flashes an error instead of crashing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/clients")
    render_click(element(view, "#built-in-restart"))
    assert has_element?(view, "#built-in-torrent")
    assert render(view) =~ "not running"
  end

  test "no panel when the built-in client is not running", %{conn: conn} do
    BuiltIn.clear_runtime()
    {:ok, view, _html} = live(conn, ~p"/admin/clients")
    refute has_element?(view, "#built-in-torrent")
  end
end
