defmodule Mydia.Downloads.BuiltIn.LimitsTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Mydia.Downloads.BuiltIn.{Config, Limits, Status}
  alias Mydia.Downloads.Client.Rqbit

  setup do
    bypass = Bypass.open()
    test_pid = self()
    uniq = System.unique_integer([:positive])
    status = :"limits_status_#{uniq}"
    topic = "built_in_status:limits:#{uniq}"
    start_supervised!({Status, name: status, topic: topic})

    client = %{
      type: :rqbit,
      host: "localhost",
      port: bypass.port,
      username: nil,
      password: nil,
      use_ssl: false,
      options: %{}
    }

    start_limits = fn config ->
      start_supervised!(
        {Limits,
         name: :"limits_#{uniq}",
         config: config,
         status: status,
         topic: topic,
         resolve: fn -> {:ok, Rqbit, client} end}
      )

      :"limits_#{uniq}"
    end

    Bypass.stub(bypass, "POST", "/torrents/limits", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:limits_body, Jason.decode!(body)})
      Plug.Conn.resp(conn, 200, "{}")
    end)

    %{bypass: bypass, status: status, start_limits: start_limits}
  end

  defp warnings(status), do: Status.get(status).warnings

  # A call to a GenServer returns after the messages queued before it.
  defp settle(server), do: :sys.get_state(server)

  test "pushes limits when the engine becomes running", ctx do
    server = ctx.start_limits.(%Config{download_limit: 100, upload_limit: 0})
    refute_receive {:limits_body, _}, 50

    Status.put(ctx.status, :engine, :running)

    assert_receive {:limits_body, %{"download_bps" => 102_400, "upload_bps" => nil}}
    settle(server)
  end

  test "pushes at start when the engine is already running", ctx do
    Status.put(ctx.status, :engine, :running)
    ctx.start_limits.(%Config{download_limit: 1, upload_limit: 2})
    assert_receive {:limits_body, %{"download_bps" => 1024, "upload_bps" => 2048}}
  end

  test "does not push again on a running -> running status change", ctx do
    server = ctx.start_limits.(%Config{download_limit: 100})
    Status.put(ctx.status, :engine, :running)
    assert_receive {:limits_body, _}

    Status.put(ctx.status, :warnings, [{:invalid_port, "x"}])
    Status.put(ctx.status, :port, {:static, 1})
    settle(server)

    refute_receive {:limits_body, _}, 50
  end

  test "pushes again after the engine stops and runs again", ctx do
    server = ctx.start_limits.(%Config{download_limit: 100})
    Status.put(ctx.status, :engine, :running)
    assert_receive {:limits_body, _}

    Status.put(ctx.status, :engine, {:stopped, :vpn_down})
    Status.put(ctx.status, :engine, :running)
    settle(server)

    assert_receive {:limits_body, %{"download_bps" => 102_400}}
  end

  test "push/2 sends new limits immediately", ctx do
    server = ctx.start_limits.(%Config{download_limit: 100})
    Status.put(ctx.status, :engine, :running)
    assert_receive {:limits_body, _}

    :ok = Limits.push(server, %Config{download_limit: nil, upload_limit: 50})

    assert_receive {:limits_body, %{"download_bps" => nil, "upload_bps" => 51_200}}
  end

  test "push/2 while the engine is not running waits for it", ctx do
    server = ctx.start_limits.(%Config{})
    :ok = Limits.push(server, %Config{download_limit: 7})
    settle(server)
    refute_receive {:limits_body, _}, 50

    Status.put(ctx.status, :engine, :running)
    assert_receive {:limits_body, %{"download_bps" => 7168}}
  end

  test "a failed push records one warning and a later success clears it", ctx do
    Bypass.stub(ctx.bypass, "POST", "/torrents/limits", fn conn ->
      Plug.Conn.resp(conn, 500, ~s({"human_readable": "boom"}))
    end)

    server = ctx.start_limits.(%Config{download_limit: 100})
    Status.put(ctx.status, :warnings, [{:invalid_port, "x"}])
    Status.put(ctx.status, :engine, :running)
    settle(server)

    assert [{:invalid_port, "x"}, {:limits_failed, message}] = warnings(ctx.status)
    assert is_binary(message)

    # A second failure replaces the first instead of stacking.
    :ok = Limits.push(server, %Config{download_limit: 200})
    settle(server)
    assert [{:invalid_port, "x"}, {:limits_failed, _}] = warnings(ctx.status)

    test_pid = self()

    Bypass.stub(ctx.bypass, "POST", "/torrents/limits", fn conn ->
      send(test_pid, :ok_push)
      Plug.Conn.resp(conn, 200, "{}")
    end)

    :ok = Limits.push(server, %Config{download_limit: 300})
    assert_receive :ok_push
    settle(server)
    assert warnings(ctx.status) == [{:invalid_port, "x"}]
  end

  test "push/2 to a process that is not running does not crash" do
    assert :ok = Limits.push(:no_such_limits_process, %Config{})
  end

  test "describe/1 copy" do
    assert Status.describe({:limits_failed, "boom"}) == "Could not apply the speed limits: boom"
  end
end
