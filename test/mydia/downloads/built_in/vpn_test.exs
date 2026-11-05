defmodule Mydia.Downloads.BuiltIn.VpnTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.BuiltIn.{Config, Status, Vpn}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    bypass = Bypass.open()
    status = :"status_#{System.unique_integer([:positive])}"
    start_supervised!({Status, name: status})
    Phoenix.PubSub.subscribe(Mydia.PubSub, Status.topic())
    File.write!(Path.join(dir, "apikey"), "k3y")
    File.write!(Path.join(dir, "preflight"), "net_admin=ok\ntun=ok\n")

    config = %Config{vpn?: true, vpn_provider: "protonvpn", port: 51413, gluetun_dir: dir}
    %{bypass: bypass, status: status, config: config, dir: dir}
  end

  defp start_vpn(ctx, leak_result) do
    test_pid = self()

    engine_fun = fn
      {:start, port} ->
        send(test_pid, {:engine_start, port})
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
       engine_fun: engine_fun,
       base_url: "http://localhost:#{ctx.bypass.port}",
       interval_ms: 50,
       leak_check: fn -> leak_result end}
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

  defp drain_broadcasts(acc) do
    receive do
      {:built_in_status, status} -> drain_broadcasts([status | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
