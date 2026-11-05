defmodule MydiaWeb.AdminDownloadClientsLive.BuiltInTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.BuiltIn.{Config, Engine, Status}

  @fake_rqbit Path.expand("../../../support/fixtures/fake_rqbit.sh", __DIR__)

  # The page lists downloads from the built-in client, which is not running.
  @moduletag :capture_log

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

  test "restart is offered only for a crashed engine", %{conn: conn} do
    Status.put(:engine, :running)
    {:ok, view, _html} = live(conn, ~p"/admin/clients")
    refute has_element?(view, "#built-in-restart")

    Status.put(:engine, {:stopped, :vpn_down})
    refute has_element?(view, "#built-in-restart")

    Status.put(:engine, {:crashed, {:engine_exit, 3}, 5})
    assert has_element?(view, "#built-in-restart")
    assert render(element(view, "#built-in-engine-state")) =~ "Crashed after 5 restarts"
  end

  test "a crash before any restart reads as not running", %{conn: conn} do
    Status.put(:engine, {:crashed, :rqbit_not_found, 0})
    {:ok, view, _html} = live(conn, ~p"/admin/clients")

    label = render(element(view, "#built-in-engine-state"))
    assert label =~ "Not running"
    refute label =~ "0 restarts"
  end

  test "restart with the engine process gone flashes an error instead of crashing", %{
    conn: conn
  } do
    Status.put(:engine, {:crashed, :rqbit_not_found, 0})
    {:ok, view, _html} = live(conn, ~p"/admin/clients")
    render_click(element(view, "#built-in-restart"))
    assert has_element?(view, "#built-in-torrent")
    assert render(view) =~ "not running"
  end

  describe "restart with a real engine" do
    @describetag :tmp_dir

    # Engine registers under its default name, which the LiveView calls; this
    # module is async: false for that reason.
    defp start_real_engine(tmp_dir, autostart?) do
      args_file = Path.join(tmp_dir, "args")

      config = %Config{
        enabled?: true,
        download_path: Path.join(tmp_dir, "downloads"),
        state_dir: Path.join(tmp_dir, "rqbit")
      }

      start_supervised!(
        {Engine,
         config: config,
         status: Status,
         rqbit_path: @fake_rqbit,
         credentials: {"mydia", "x"},
         backoff_ms: 1,
         autostart: autostart?,
         env: [
           {"FAKE_RQBIT_ARGS", args_file},
           {"FAKE_RQBIT_PID", Path.join(tmp_dir, "child.pid")},
           {"FAKE_RQBIT_MODE", "exit"}
         ]}
      )

      args_file
    end

    defp wait_for(fun, tries \\ 300) do
      cond do
        fun.() -> :ok
        tries == 0 -> flunk("condition not met in time")
        true -> Process.sleep(10) && wait_for(fun, tries - 1)
      end
    end

    test "restarts a crashed engine", %{conn: conn, tmp_dir: tmp_dir} do
      args_file = start_real_engine(tmp_dir, true)
      wait_for(fn -> match?(%Status{engine: {:crashed, _, 5}}, Status.get()) end)
      File.rm!(args_file)

      {:ok, view, _html} = live(conn, ~p"/admin/clients")
      Phoenix.PubSub.subscribe(Mydia.PubSub, Status.topic())
      render_click(element(view, "#built-in-restart"))

      assert render(view) =~ "Restarting the built-in torrent client"
      assert_receive {:built_in_status, %Status{engine: :running}}, 1_000
      wait_for(fn -> File.exists?(args_file) end)
    end

    test "flashes an error when the engine has not crashed", %{conn: conn, tmp_dir: tmp_dir} do
      args_file = start_real_engine(tmp_dir, false)
      # The engine is idle; only the status claims a crash, as when the
      # engine left the crash between the render and the click.
      Status.put(:engine, {:crashed, {:engine_exit, 3}, 5})

      {:ok, view, _html} = live(conn, ~p"/admin/clients")
      render_click(element(view, "#built-in-restart"))

      assert render(view) =~ "has not crashed"
      refute File.exists?(args_file)
    end
  end

  test "an unreadable status says so instead of showing a state", %{conn: conn} do
    stop_supervised!(Status)
    {:ok, view, _html} = live(conn, ~p"/admin/clients")

    assert has_element?(view, "#built-in-status-unavailable")
    refute has_element?(view, "#built-in-engine-state")
    refute has_element?(view, "#built-in-restart")
  end

  test "no panel when the built-in client is not running", %{conn: conn} do
    BuiltIn.clear_runtime()
    {:ok, view, _html} = live(conn, ~p"/admin/clients")
    refute has_element?(view, "#built-in-torrent")
  end
end
