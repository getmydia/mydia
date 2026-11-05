defmodule Mydia.Downloads.BuiltIn.EngineTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.BuiltIn.{Config, Engine, Status}

  @fake Path.expand("../../../support/fixtures/fake_rqbit.sh", __DIR__)

  setup %{tmp_dir: tmp_dir} = ctx do
    status = :"status_#{System.unique_integer([:positive])}"
    start_supervised!({Status, name: status})
    Phoenix.PubSub.subscribe(Mydia.PubSub, Status.topic())

    config = %Config{
      enabled?: true,
      download_path: Path.join(tmp_dir, "downloads"),
      state_dir: Path.join(tmp_dir, "rqbit"),
      vpn?: Map.get(ctx, :vpn, false),
      vpn_interface: "tun0"
    }

    args_file = Path.join(tmp_dir, "args")
    %{status: status, config: config, args_file: args_file}
  end

  defp start_engine(ctx, extra) do
    name = :"engine_#{System.unique_integer([:positive])}"

    opts =
      Keyword.merge(
        [
          name: name,
          config: ctx.config,
          status: ctx.status,
          rqbit_path: @fake,
          credentials: {"mydia", "secret"},
          backoff_ms: 10,
          env: [
            {"FAKE_RQBIT_ARGS", ctx.args_file},
            {"FAKE_RQBIT_MODE", Keyword.get(extra, :mode, "run")}
          ]
        ],
        Keyword.drop(extra, [:mode])
      )

    start_supervised!({Engine, opts}, id: name)
    name
  end

  @tag :tmp_dir
  test "args put global flags before server start", ctx do
    args = Engine.args(ctx.config, 3030, 6881)

    assert args == [
             "--http-api-listen-addr",
             "127.0.0.1:3030",
             "--listen-port",
             "6881",
             "--disable-upnp-port-forward",
             "server",
             "start",
             "--persistence-location",
             ctx.config.state_dir,
             ctx.config.download_path
           ]
  end

  @tag :tmp_dir
  @tag vpn: true
  test "args bind to the tunnel when the VPN is on", ctx do
    args = Engine.args(ctx.config, 3030, 6881)
    assert ["--bind-device", "tun0"] == Enum.slice(args, 5, 2)
  end

  @tag :tmp_dir
  test "autostart runs rqbit with credentials and reports running", ctx do
    start_engine(ctx, autostart: true)
    assert_receive {:built_in_status, %Status{engine: :running, port: {:static, 51413}}}, 1_000
    Process.sleep(50)
    lines = File.read!(ctx.args_file) |> String.split("\n", trim: true)
    assert "51413" in lines
    assert List.last(lines) == "mydia:secret"
  end

  @tag :tmp_dir
  test "stop_engine/2 kills the child and records the reason", ctx do
    name = start_engine(ctx, autostart: true)
    assert_receive {:built_in_status, %Status{engine: :running}}, 1_000
    :ok = Engine.stop_engine(name, :vpn_down)
    assert %Status{engine: {:stopped, :vpn_down}} = Status.get(ctx.status)
  end

  @tag :tmp_dir
  @tag :capture_log
  test "a child that keeps exiting ends crashed after 5 restarts", ctx do
    start_engine(ctx, autostart: true, mode: "exit")

    assert_receive {:built_in_status, %Status{engine: {:crashed, {:engine_exit, 3}, 5}}},
                   2_000
  end

  @tag :tmp_dir
  @tag :capture_log
  test "restart/1 clears a crash", ctx do
    name = start_engine(ctx, autostart: true, mode: "exit")
    assert_receive {:built_in_status, %Status{engine: {:crashed, _, 5}}}, 2_000
    :ok = Engine.restart(name)
    assert_receive {:built_in_status, %Status{engine: :running}}, 1_000
  end

  @tag :tmp_dir
  test "a missing binary is a named reason", ctx do
    start_engine(ctx, autostart: true, rqbit_path: "/nonexistent/rqbit")
    assert_receive {:built_in_status, %Status{engine: {:crashed, :rqbit_not_found, 0}}}, 1_000
  end
end
