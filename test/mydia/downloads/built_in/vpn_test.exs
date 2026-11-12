defmodule Mydia.Downloads.BuiltIn.VpnTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Mydia.Downloads.BuiltIn.{Config, Status, Vpn}

  @moduletag :tmp_dir
  # Every transition into a down state logs an error.
  @moduletag :capture_log

  setup %{tmp_dir: dir} do
    bypass = Bypass.open()
    status = :"status_#{System.unique_integer([:positive])}"
    topic = "built_in_status:test:#{System.unique_integer([:positive])}"
    start_supervised!({Status, name: status, topic: topic})
    Phoenix.PubSub.subscribe(Mydia.PubSub, topic)
    File.write!(Path.join(dir, "apikey"), "k3y")
    File.write!(Path.join(dir, "preflight"), "net_admin=ok\ntun=ok\n")

    config = %Config{vpn?: true, vpn_provider: "protonvpn", port: 51413, gluetun_dir: dir}
    %{bypass: bypass, status: status, config: config, dir: dir}
  end

  defp start_vpn(ctx, leak_result) when not is_function(leak_result),
    do: start_vpn(ctx, fn _public_ip -> leak_result end)

  defp start_vpn(ctx, leak_fun) when is_function(leak_fun, 0),
    do: start_vpn(ctx, fn _public_ip -> leak_fun.() end)

  defp start_vpn(ctx, leak_fun) do
    test_pid = self()

    engine_fun = fn
      {:start, port, listen_ip} ->
        send(test_pid, {:engine_start, port})
        send(test_pid, {:engine_listen, port, listen_ip})
        :ok

      {:stop, reason} ->
        send(test_pid, {:engine_stop, reason})
        :ok
    end

    start_supervised!(
      {Vpn,
       name: :"vpn_#{System.unique_integer([:positive])}",
       config: ctx.config,
       status: ctx.status,
       engine_fun: Map.get(ctx, :engine_fun, engine_fun),
       tunnel_ip_fun: Map.get(ctx, :tunnel_ip_fun, fn _interface -> {:ok, "10.2.0.2"} end),
       reverify_ms: Map.get(ctx, :reverify_ms, 60_000),
       base_url: "http://localhost:#{ctx.bypass.port}",
       interval_ms: 50,
       leak_check: leak_fun}
    )
  end

  defp gluetun(bypass, status, port) do
    Bypass.stub(bypass, "GET", "/v1/vpn/status", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{status: status}))
    end)

    Bypass.stub(bypass, "GET", "/v1/publicip/ip", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"public_ip":"203.0.113.9"}))
    end)

    Bypass.stub(bypass, "GET", "/v1/portforward", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{port: port}))
    end)
  end

  test "running VPN with a passed leak check starts the engine on the forwarded port", ctx do
    gluetun(ctx.bypass, "running", 40_123)
    start_vpn(ctx, :ok)

    assert_receive {:engine_start, 40_123}, 1_000

    assert %Status{vpn: {:up, %{provider: "protonvpn", public_ip: "203.0.113.9"}}} =
             Status.get(ctx.status)

    assert %Status{port: {:forwarded, 40_123, _}} = Status.get(ctx.status)
  end

  test "no forwarded port uses the configured port", ctx do
    gluetun(ctx.bypass, "running", 0)
    start_vpn(ctx, :ok)
    assert_receive {:engine_start, 51413}, 1_000
  end

  test "a failed leak check never starts the engine", ctx do
    gluetun(ctx.bypass, "running", 0)
    start_vpn(ctx, {:error, :leak_detected})

    assert_receive {:engine_stop, :leak_detected}, 1_000
    refute_received {:engine_start, _}
    assert %Status{vpn: {:down, :leak_detected}} = Status.get(ctx.status)
  end

  test "a stopped VPN stops the engine and shows the last log line", ctx do
    File.write!(Path.join(ctx.dir, "gluetun.log"), "INFO ok\nERROR [vpn] auth failed\n")
    gluetun(ctx.bypass, "stopped", 0)
    start_vpn(ctx, :ok)

    assert_receive {:engine_stop, {:vpn_down, "ERROR [vpn] auth failed"}}, 1_000
  end

  test "a preflight problem is reported without calling gluetun", ctx do
    File.write!(Path.join(ctx.dir, "preflight"), "net_admin=missing\ntun=ok\n")
    start_vpn(ctx, :ok)

    assert_receive {:engine_stop, :missing_net_admin}, 1_000
    assert %Status{vpn: {:down, :missing_net_admin}} = Status.get(ctx.status)
  end

  test "a missing split group is reported without calling gluetun", ctx do
    File.write!(Path.join(ctx.dir, "preflight"), "net_admin=ok\ntun=ok\nsplit_group=missing\n")
    start_vpn(ctx, :ok)

    assert_receive {:engine_stop, :split_group_missing}, 1_000
    assert %Status{vpn: {:down, :split_group_missing}} = Status.get(ctx.status)
  end

  test "an unreachable gluetun is reported", ctx do
    Bypass.down(ctx.bypass)
    start_vpn(ctx, :ok)
    assert_receive {:engine_stop, :vpn_unreachable}, 1_000
  end

  test "a steady running VPN does not re-broadcast the same status on every poll", ctx do
    gluetun(ctx.bypass, "running", 40_123)
    start_vpn(ctx, :ok)

    # Several polls: the engine is called each time, Status is written once.
    assert_receive {:engine_start, 40_123}, 1_000
    assert_receive {:engine_start, 40_123}, 1_000
    assert_receive {:engine_start, 40_123}, 1_000

    {:forwarded, 40_123, since} = Status.get(ctx.status).port

    broadcasts = drain_broadcasts([])
    up_broadcasts = Enum.filter(broadcasts, &match?(%Status{vpn: {:up, _}}, &1))
    assert [%Status{} | _] = up_broadcasts

    # :connecting, then :up, then :forwarded port: three puts in total.
    assert length(broadcasts) == 3
    assert {:forwarded, 40_123, ^since} = Status.get(ctx.status).port
  end

  # State shared with the Vpn poll. Supervised, and started before Vpn, so
  # ExUnit stops Vpn first (reverse start order): a poll still in flight at
  # teardown never finds the state process gone.
  defp start_state(initial) do
    start_supervised!(%{
      id: {:state, System.unique_integer([:positive])},
      start: {Agent, :start_link, [fn -> initial end]}
    })
  end

  # Gluetun whose answers the test changes while the gate is polling.
  defp mutable_gluetun(bypass, initial) do
    agent = start_state(initial)

    Bypass.stub(bypass, "GET", "/v1/vpn/status", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{status: Agent.get(agent, & &1.status)}))
    end)

    Bypass.stub(bypass, "GET", "/v1/publicip/ip", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{public_ip: Agent.get(agent, & &1.ip)}))
    end)

    # `port: :error` makes the port forward read fail.
    Bypass.stub(bypass, "GET", "/v1/portforward", fn conn ->
      case Agent.get(agent, & &1.port) do
        :error -> Plug.Conn.resp(conn, 500, "")
        port -> Plug.Conn.resp(conn, 200, Jason.encode!(%{port: port}))
      end
    end)

    agent
  end

  defp counting_leak_check(results) do
    test_pid = self()
    counter = start_state(0)

    fn ->
      n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(test_pid, {:leak_check, n})
      results.(n)
    end
  end

  # The reason matches the VPN's :connecting, so the panel does not say the
  # tunnel is down while it says it is connecting.
  test "a fresh gate stops an engine it did not start, as connecting", ctx do
    gluetun(ctx.bypass, "stopped", 0)
    start_vpn(ctx, :ok)
    assert_receive {:engine_stop, :vpn_connecting}, 1_000
  end

  test "an engine call that exits does not crash the gate", ctx do
    gluetun(ctx.bypass, "running", 0)
    test_pid = self()

    ctx =
      Map.put(ctx, :engine_fun, fn message ->
        send(test_pid, {:engine_call, message})
        exit({:timeout, {GenServer, :call, [:engine, message, 20_000]}})
      end)

    pid = start_vpn(ctx, :ok)

    assert_receive {:engine_call, {:stop, :vpn_connecting}}, 1_000
    assert_receive {:engine_call, {:start, 51413, "10.2.0.2"}}, 1_000
    assert_receive {:engine_call, {:start, 51413, "10.2.0.2"}}, 1_000
    assert Process.alive?(pid)
  end

  test "a passed leak check is not repeated while it is fresh", ctx do
    gluetun(ctx.bypass, "running", 0)
    start_vpn(ctx, counting_leak_check(fn _ -> :ok end))

    assert_receive {:leak_check, 1}, 1_000
    for _ <- 1..3, do: assert_receive({:engine_start, 51413}, 1_000)
    refute_received {:leak_check, 2}
  end

  # A gluetun restart between polls can land on the same addresses.
  test "a passed leak check expires and is run again on unchanged addresses", ctx do
    gluetun(ctx.bypass, "running", 0)
    ctx = Map.put(ctx, :reverify_ms, 0)
    start_vpn(ctx, counting_leak_check(fn _ -> :ok end))

    assert_receive {:leak_check, 1}, 1_000
    assert_receive {:leak_check, 2}, 1_000
  end

  test "a changed tunnel address re-runs the leak check", ctx do
    gluetun(ctx.bypass, "running", 0)
    agent = start_state("10.2.0.2")
    ctx = Map.put(ctx, :tunnel_ip_fun, fn _interface -> {:ok, Agent.get(agent, & &1)} end)
    start_vpn(ctx, counting_leak_check(fn _ -> :ok end))

    assert_receive {:leak_check, 1}, 1_000
    assert_receive {:engine_listen, 51413, "10.2.0.2"}, 1_000
    Agent.update(agent, fn _ -> "10.2.0.9" end)
    assert_receive {:leak_check, 2}, 1_000
    assert_receive {:engine_listen, 51413, "10.2.0.9"}, 1_000
  end

  @tag :capture_log
  test "a leak check that raises stops the engine and the gate survives", ctx do
    gluetun(ctx.bypass, "running", 0)
    pid = start_vpn(ctx, fn -> raise "boom" end)

    assert_receive {:engine_stop, {:leak_check_failed, "boom"}}, 1_000
    refute_received {:engine_start, _}
    Process.sleep(150)
    assert Process.alive?(pid)
    assert %Status{vpn: {:down, {:leak_check_failed, "boom"}}} = Status.get(ctx.status)
  end

  test "a changed public address re-runs the leak check before the engine continues", ctx do
    agent = mutable_gluetun(ctx.bypass, %{status: "running", ip: "203.0.113.1", port: 0})

    start_vpn(
      ctx,
      counting_leak_check(fn
        1 -> :ok
        _ -> {:error, :leak_detected}
      end)
    )

    assert_receive {:leak_check, 1}, 1_000
    assert_receive {:engine_start, 51413}, 1_000

    Agent.update(agent, &%{&1 | ip: "203.0.113.2"})

    assert_receive {:leak_check, 2}, 1_000
    assert_receive {:engine_stop, :leak_detected}, 1_000
    assert %Status{vpn: {:down, :leak_detected}} = Status.get(ctx.status)
  end

  test "an unreadable public address stops the engine without a leak check", ctx do
    Bypass.stub(ctx.bypass, "GET", "/v1/vpn/status", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"status":"running"}))
    end)

    Bypass.stub(ctx.bypass, "GET", "/v1/publicip/ip", fn conn ->
      Plug.Conn.resp(conn, 500, "")
    end)

    start_vpn(ctx, counting_leak_check(fn _ -> :ok end))

    assert_receive {:engine_stop, :vpn_connecting}, 1_000
    Process.sleep(150)
    refute_received {:engine_start, _}
    refute_received {:leak_check, _}
    assert %Status{vpn: :connecting} = Status.get(ctx.status)
  end

  test "the engine is started on the tunnel address", ctx do
    gluetun(ctx.bypass, "running", 40_123)
    start_vpn(ctx, :ok)
    assert_receive {:engine_listen, 40_123, "10.2.0.2"}, 1_000
  end

  test "an unreadable tunnel address stops the engine and leaves the VPN connecting", ctx do
    gluetun(ctx.bypass, "running", 40_123)
    ctx = Map.put(ctx, :tunnel_ip_fun, fn _interface -> {:error, :no_tunnel_address} end)
    start_vpn(ctx, counting_leak_check(fn _ -> :ok end))

    assert_receive {:engine_stop, :vpn_connecting}, 1_000
    refute_received {:leak_check, _}
    Process.sleep(150)
    refute_received {:engine_start, _}
    assert %Status{vpn: :connecting} = Status.get(ctx.status)
  end

  test "a changed tunnel address restarts the engine on the new one", ctx do
    gluetun(ctx.bypass, "running", 40_123)
    agent = start_state("10.2.0.2")
    ctx = Map.put(ctx, :tunnel_ip_fun, fn _interface -> {:ok, Agent.get(agent, & &1)} end)
    start_vpn(ctx, :ok)

    assert_receive {:engine_listen, 40_123, "10.2.0.2"}, 1_000
    Agent.update(agent, fn _ -> "10.2.0.9" end)
    assert_receive {:engine_listen, 40_123, "10.2.0.9"}, 1_000
  end

  test "the tunnel address is parsed from ip output" do
    line = "7: tun0    inet 10.2.0.2/32 scope global tun0\\       valid_lft forever\\n"
    assert {:ok, "10.2.0.2"} = Vpn.parse_tunnel_ip(line)
    assert {:error, _} = Vpn.parse_tunnel_ip("")
    assert {:error, _} = Vpn.parse_tunnel_ip("7: tun0    inet 999.1.1.1/32 scope global tun0\n")
  end

  test "up then stopped stops the engine, and running again re-runs the leak check", ctx do
    agent = mutable_gluetun(ctx.bypass, %{status: "running", ip: "203.0.113.1", port: 0})
    start_vpn(ctx, counting_leak_check(fn _ -> :ok end))

    assert_receive {:leak_check, 1}, 1_000
    assert_receive {:engine_start, 51413}, 1_000
    flush_engine_messages()

    Agent.update(agent, &%{&1 | status: "stopped"})
    assert_receive {:engine_stop, :vpn_down}, 1_000
    assert %Status{vpn: {:down, :vpn_down}} = Status.get(ctx.status)
    flush_engine_messages()

    Agent.update(agent, &%{&1 | status: "running"})
    assert_receive {:leak_check, 2}, 1_000
    assert_receive {:engine_start, 51413}, 1_000
    assert %Status{vpn: {:up, _}} = Status.get(ctx.status)
  end

  test "gluetun going unreachable after up stops the engine", ctx do
    gluetun(ctx.bypass, "running", 0)
    start_vpn(ctx, :ok)
    assert_receive {:engine_start, 51413}, 1_000

    Bypass.down(ctx.bypass)
    assert_receive {:engine_stop, :vpn_unreachable}, 1_000
    assert %Status{vpn: {:down, :vpn_unreachable}} = Status.get(ctx.status)
  end

  test "a recovered tunnel re-puts its forwarded port with a fresh since", ctx do
    agent = mutable_gluetun(ctx.bypass, %{status: "running", ip: "203.0.113.1", port: 40_123})
    start_vpn(ctx, :ok)
    assert_receive {:engine_start, 40_123}, 1_000
    {:forwarded, 40_123, first} = Status.get(ctx.status).port
    flush_engine_messages()

    Agent.update(agent, &%{&1 | status: "stopped"})
    assert_receive {:engine_stop, _}, 1_000
    flush_engine_messages()
    Agent.update(agent, &%{&1 | status: "running"})
    assert_receive {:engine_start, 40_123}, 1_000

    assert {:forwarded, 40_123, second} = Status.get(ctx.status).port
    assert DateTime.compare(second, first) == :gt
  end

  test "the leak check is given gluetun's public address", ctx do
    gluetun(ctx.bypass, "running", 0)
    test_pid = self()

    start_vpn(ctx, fn public_ip ->
      send(test_pid, {:leak_check_ip, public_ip})
      :ok
    end)

    assert_receive {:leak_check_ip, "203.0.113.9"}, 1_000
  end

  test "a failed port forward read keeps the forwarded port and reports it", ctx do
    agent = mutable_gluetun(ctx.bypass, %{status: "running", ip: "203.0.113.1", port: 40_123})
    start_vpn(ctx, :ok)
    assert_receive {:engine_start, 40_123}, 1_000

    Agent.update(agent, &%{&1 | port: :error})
    flush_engine_messages()
    refute_receive {:engine_start, 51413}, 300

    assert %Status{port: {:failed, {:port_forward_failed, message}, 40_123}} =
             Status.get(ctx.status)

    assert message =~ "500"
  end

  test "a forwarded port that reads back as 0 is a failure, not the static port", ctx do
    agent = mutable_gluetun(ctx.bypass, %{status: "running", ip: "203.0.113.1", port: 40_123})
    start_vpn(ctx, :ok)
    assert_receive {:engine_start, 40_123}, 1_000

    Agent.update(agent, &%{&1 | port: 0})
    flush_engine_messages()
    assert_receive {:engine_start, 40_123}, 1_000
    refute_receive {:engine_start, 51413}, 200
    assert %Status{port: {:failed, {:port_forward_failed, _}, 40_123}} = Status.get(ctx.status)

    # Forwarding comes back on a new port.
    Agent.update(agent, &%{&1 | port: 40_200})
    assert_receive {:engine_start, 40_200}, 1_000
    assert %Status{port: {:forwarded, 40_200, _}} = Status.get(ctx.status)
  end

  test "a failed port forward read without an earlier forward uses the static port", ctx do
    mutable_gluetun(ctx.bypass, %{status: "running", ip: "203.0.113.1", port: :error})
    start_vpn(ctx, :ok)
    assert_receive {:engine_start, 51413}, 1_000
    assert %Status{port: {:static, 51413}} = Status.get(ctx.status)
  end

  test "the same error with a new timestamp is one transition", ctx do
    log = Path.join(ctx.dir, "gluetun.log")
    File.write!(log, "2026-11-04T19:52:12Z ERROR [vpn] auth failed\n")
    gluetun(ctx.bypass, "stopped", 0)
    start_vpn(ctx, :ok)

    assert_receive {:built_in_status,
                    %Status{vpn: {:down, {:vpn_down, "ERROR [vpn] auth failed"}}}},
                   1_000

    File.write!(log, "2026-11-04T19:52:42Z ERROR [vpn] auth failed\n")
    # Several polls (50ms apart) read the new timestamp.
    refute_receive {:built_in_status, %Status{vpn: {:down, _}}}, 400
  end

  test "an unreachable gluetun shows the last error from its log", ctx do
    File.write!(
      Path.join(ctx.dir, "gluetun.log"),
      "INFO starting\nERROR VPN settings: wireguard private key is missing\n"
    )

    Bypass.down(ctx.bypass)
    start_vpn(ctx, :ok)

    assert_receive {:engine_stop,
                    {:vpn_down, "ERROR VPN settings: wireguard private key is missing"}},
                   1_000
  end

  test "only the tail of the gluetun log is read", ctx do
    filler = String.duplicate("INFO filler line that pads the log\n", 3_000)
    log = Path.join(ctx.dir, "gluetun.log")
    File.write!(log, "ERROR old failure outside the tail\n" <> filler)

    Bypass.down(ctx.bypass)
    start_vpn(ctx, :ok)
    assert_receive {:engine_stop, :vpn_unreachable}, 1_000
  end

  test "a transition into a down state is logged once, not on every poll", ctx do
    File.write!(Path.join(ctx.dir, "preflight"), "net_admin=missing\ntun=ok\n")

    log =
      capture_log(fn ->
        start_vpn(ctx, :ok)
        # Several 50ms polls.
        Process.sleep(300)
      end)

    occurrences = log |> String.split("needs the NET_ADMIN capability") |> length()
    assert occurrences - 1 == 1
  end

  # Drops queued engine messages: the gate also stops the engine on boot and
  # calls it on every poll, so earlier messages must not satisfy later asserts.
  defp flush_engine_messages do
    receive do
      {:engine_start, _} -> flush_engine_messages()
      {:engine_listen, _, _} -> flush_engine_messages()
      {:engine_stop, _} -> flush_engine_messages()
    after
      0 -> :ok
    end
  end

  defp drain_broadcasts(acc) do
    receive do
      {:built_in_status, status} -> drain_broadcasts([status | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
