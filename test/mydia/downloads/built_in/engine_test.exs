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
    pid_file = Path.join(tmp_dir, "child.pid")
    %{status: status, config: config, args_file: args_file, pid_file: pid_file}
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
          env:
            [
              {"FAKE_RQBIT_ARGS", ctx.args_file},
              {"FAKE_RQBIT_PID", ctx.pid_file},
              {"FAKE_RQBIT_MODE", Keyword.get(extra, :mode, "run")}
            ] ++ Enum.map(List.wrap(extra[:env_file]), &{"FAKE_RQBIT_ENV", &1})
        ],
        Keyword.drop(extra, [:mode, :env_file])
      )

    start_supervised!({Engine, opts}, id: name)
    name
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met in time")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  defp read_pid(file) do
    wait_until(fn -> match?({:ok, <<_, _::binary>>}, File.read(file)) end)
    file |> File.read!() |> String.trim() |> String.to_integer()
  end

  defp gone?(pid), do: not File.exists?("/proc/#{pid}") or zombie?(pid)

  defp zombie?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> stat |> String.split(") ") |> List.last() |> String.starts_with?("Z")
      _ -> false
    end
  end

  defp drain do
    receive do
      {:built_in_status, _} -> drain()
    after
      0 -> :ok
    end
  end

  @tag :tmp_dir
  test "args put
 global flags before server start",
       ctx do
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
  test "args/4 puts --listen-ip right after the listen port", ctx do
    args = Engine.args(ctx.config, 3030, 6881, "10.2.0.2")
    assert ["--listen-port", "6881", "--listen-ip", "10.2.0.2"] == Enum.slice(args, 2, 4)

    assert Enum.find_index(args, &(&1 == "--listen-ip")) <
             Enum.find_index(args, &(&1 == "server"))
  end

  @tag :tmp_dir
  test "start_engine/3 with the same port and a different ip restarts the child", ctx do
    name = start_engine(ctx, [])
    :ok = Engine.start_engine(name, 6881, "10.2.0.2")
    first_pid = read_pid(ctx.pid_file)

    wait_until(fn ->
      "10.2.0.2" in (File.read!(ctx.args_file) |> String.split("\n", trim: true))
    end)

    # Same port and ip is a no-op.
    :ok = Engine.start_engine(name, 6881, "10.2.0.2")
    assert read_pid(ctx.pid_file) == first_pid

    :ok = Engine.start_engine(name, 6881, "10.2.0.9")
    assert gone?(first_pid)

    wait_until(fn ->
      read_pid(ctx.pid_file) != first_pid and
        "10.2.0.9" in (File.read!(ctx.args_file) |> String.split("\n", trim: true))
    end)
  end

  @tag :tmp_dir
  @tag :capture_log
  test "a spawn failure is reported and the engine stays alive", ctx do
    # A NUL byte in the environment makes Port.open raise.
    name = start_engine(ctx, credentials: {"mydia", "se\0cret"})
    :ok = Engine.start_engine(name, 6881)

    assert %Status{engine: {:crashed, {:spawn_failed, reason}, 0}} = Status.get(ctx.status)
    assert is_binary(reason)
    assert Process.alive?(Process.whereis(name))
    refute File.exists?(ctx.pid_file)
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
    pid = read_pid(ctx.pid_file)
    :ok = Engine.stop_engine(name, :vpn_down)
    assert %Status{engine: {:stopped, :vpn_down}} = Status.get(ctx.status)
    assert gone?(pid)
  end

  @tag :tmp_dir
  @tag :capture_log
  test "a respawn pending during backoff does not survive stop_engine/2", ctx do
    name = start_engine(ctx, autostart: true, mode: "exit", backoff_ms: 300)
    # :starting is also the initial state, so wait for the first spawn and
    # then for the backoff that follows its exit.
    assert_receive {:built_in_status, %Status{engine: :running}}, 1_000
    drain()
    assert_receive {:built_in_status, %Status{engine: :starting}}, 1_000
    :ok = Engine.stop_engine(name, :vpn_down)
    File.rm!(ctx.args_file)
    drain()

    refute_receive {:built_in_status, _}, 500
    refute File.exists?(ctx.args_file)
    assert %Status{engine: {:stopped, :vpn_down}} = Status.get(ctx.status)
  end

  @tag :tmp_dir
  test "start_engine/2 with a different port restarts the child on it", ctx do
    name = start_engine(ctx, autostart: true)
    assert_receive {:built_in_status, %Status{engine: :running}}, 1_000
    old_pid = read_pid(ctx.pid_file)

    :ok = Engine.start_engine(name, 6881)
    assert gone?(old_pid)

    wait_until(fn ->
      File.read!(ctx.pid_file) |> String.trim() != Integer.to_string(old_pid) and
        "6881" in (File.read!(ctx.args_file) |> String.split("\n", trim: true))
    end)
  end

  @tag :tmp_dir
  test "a stale pid file left by a crashed BEAM is killed on start", ctx do
    File.mkdir_p!(ctx.config.state_dir)

    stale =
      Port.open({:spawn_executable, @fake}, [
        :binary,
        env: [
          {~c"FAKE_RQBIT_ARGS", String.to_charlist(ctx.args_file)},
          {~c"FAKE_RQBIT_PID", String.to_charlist(ctx.pid_file)},
          {~c"FAKE_RQBIT_MODE", ~c"hold"}
        ]
      ])

    {:os_pid, os_pid} = Port.info(stale, :os_pid)
    assert read_pid(ctx.pid_file) == os_pid
    File.write!(Path.join(ctx.config.state_dir, "rqbit.pid"), Integer.to_string(os_pid))

    start_engine(ctx, [])
    assert gone?(os_pid)
    refute File.exists?(Path.join(ctx.config.state_dir, "rqbit.pid"))
  end

  @tag :tmp_dir
  test "restart/1 is a no-op unless the engine crashed", ctx do
    name = start_engine(ctx, autostart: true)
    assert_receive {:built_in_status, %Status{engine: :running}}, 1_000
    pid = read_pid(ctx.pid_file)
    :ok = Engine.restart(name)
    assert gone?(pid) == false

    :ok = Engine.stop_engine(name, :vpn_down)
    drain()
    :ok = Engine.restart(name)
    refute_receive {:built_in_status, _}, 100
    assert %Status{engine: {:stopped, :vpn_down}} = Status.get(ctx.status)
  end

  @tag :tmp_dir
  test "restart/1 does not spawn before a port is known", ctx do
    name = start_engine(ctx, [])
    :ok = Engine.restart(name)
    refute_receive {:built_in_status, _}, 100
    assert %Status{engine: :starting} = Status.get(ctx.status)
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
    drain()
    :ok = Engine.restart(name)
    assert_receive {:built_in_status, %Status{engine: :running}}, 1_000
  end

  @tag :tmp_dir
  test "a missing binary is a named reason", ctx do
    start_engine(ctx, autostart: true, rqbit_path: "/nonexistent/rqbit")
    assert_receive {:built_in_status, %Status{engine: {:crashed, :rqbit_not_found, 0}}}, 1_000
  end

  @tag :tmp_dir
  test "an unwritable path is a named reason and nothing is spawned", ctx do
    blocker = Path.join(ctx.config.state_dir <> "-file", "x")
    File.mkdir_p!(Path.dirname(blocker))
    File.write!(Path.dirname(blocker) |> Path.join("f"), "")
    bad = Path.join(Path.join(Path.dirname(blocker), "f"), "downloads")
    config = %{ctx.config | download_path: bad}

    start_engine(%{ctx | config: config}, autostart: true)

    assert_receive {:built_in_status,
                    %Status{
                      engine:
                        {:crashed,
                         {:path_unwritable, ^bad, _reason, "MYDIA_TORRENT_DOWNLOAD_PATH"}, 0}
                    }},
                   1_000

    refute File.exists?(ctx.pid_file)
  end

  @tag :tmp_dir
  test "an unwritable state path names its own variable", ctx do
    blocker = Path.join(ctx.tmp_dir, "blocker")
    File.write!(blocker, "")
    bad = Path.join(blocker, "rqbit")

    start_engine(%{ctx | config: %{ctx.config | state_dir: bad}}, autostart: true)

    assert_receive {:built_in_status,
                    %Status{
                      engine:
                        {:crashed, {:path_unwritable, ^bad, _reason, "MYDIA_TORRENT_STATE_PATH"},
                         0}
                    }},
                   1_000
  end

  @tag :tmp_dir
  @tag :capture_log
  test "restart/1 after a stop does not spawn, even when the engine had crashed", ctx do
    name = start_engine(ctx, autostart: true, mode: "exit")
    assert_receive {:built_in_status, %Status{engine: {:crashed, _, 5}}}, 2_000
    :ok = Engine.stop_engine(name, :vpn_down)
    File.rm!(ctx.args_file)
    drain()

    :ok = Engine.restart(name)
    refute_receive {:built_in_status, _}, 200
    refute File.exists?(ctx.args_file)
    assert %Status{engine: {:stopped, :vpn_down}} = Status.get(ctx.status)
  end

  @tag :tmp_dir
  @tag :capture_log
  test "repeating start on the same target does not reset a crash or a backoff", ctx do
    name = start_engine(ctx, autostart: true, mode: "exit", backoff_ms: 20)
    assert_receive {:built_in_status, %Status{engine: :running}}, 1_000

    # The VPN gate repeats its start every poll while rqbit keeps exiting. The
    # counter must still run out instead of being reset by each call.
    for _ <- 1..20 do
      :ok = Engine.start_engine(name, 51413)
      Process.sleep(20)
    end

    assert_receive {:built_in_status, %Status{engine: {:crashed, {:engine_exit, 3}, 5}}}, 3_000
    File.rm!(ctx.args_file)
    drain()

    :ok = Engine.start_engine(name, 51413)
    refute_receive {:built_in_status, _}, 200
    refute File.exists?(ctx.args_file)
    assert %Status{engine: {:crashed, _, 5}} = Status.get(ctx.status)

    # A new target is a fresh start.
    :ok = Engine.start_engine(name, 6881)
    assert_receive {:built_in_status, %Status{engine: :running}}, 1_000
  end

  @tag :tmp_dir
  test "a missing binary is not re-reported on every start", ctx do
    name = start_engine(ctx, rqbit_path: "/nonexistent/rqbit")
    :ok = Engine.start_engine(name, 6881, "10.2.0.2")
    assert_receive {:built_in_status, %Status{engine: {:crashed, :rqbit_not_found, 0}}}, 1_000

    :ok = Engine.start_engine(name, 6881, "10.2.0.2")
    :ok = Engine.start_engine(name, 6881, "10.2.0.2")
    refute_receive {:built_in_status, _}, 100
  end

  @tag :tmp_dir
  test "a repeated stop for the same reason is broadcast once", ctx do
    name = start_engine(ctx, autostart: true)
    assert_receive {:built_in_status, %Status{engine: :running}}, 1_000
    drain()

    :ok = Engine.stop_engine(name, :vpn_down)
    :ok = Engine.stop_engine(name, :vpn_down)
    assert_receive {:built_in_status, %Status{engine: {:stopped, :vpn_down}}}, 1_000
    refute_receive {:built_in_status, _}, 100

    :ok = Engine.stop_engine(name, :leak_detected)
    assert_receive {:built_in_status, %Status{engine: {:stopped, :leak_detected}}}, 1_000
  end

  @tag :tmp_dir
  test "child_env unsets inherited secrets and keeps its own values" do
    parent = %{
      "MYDIA_VPN_WIREGUARD_PRIVATE_KEY" => "k",
      "SECRET_KEY_BASE" => "s",
      "PATH" => "/bin",
      "FAKE_SECRET_SETTING" => "inherited"
    }

    env =
      Engine.child_env(
        %{credentials: {"mydia", "pw"}, env: [{"FAKE_SECRET_SETTING", "mine"}]},
        parent
      )

    assert {~c"MYDIA_VPN_WIREGUARD_PRIVATE_KEY", false} in env
    assert {~c"SECRET_KEY_BASE", false} in env
    assert {~c"RQBIT_HTTP_BASIC_AUTH_USERPASS", ~c"mydia:pw"} in env
    assert {~c"FAKE_SECRET_SETTING", ~c"mine"} in env
    refute {~c"FAKE_SECRET_SETTING", false} in env
    refute Enum.any?(env, &match?({~c"PATH", _}, &1))
  end

  @tag :tmp_dir
  test "rqbit does not inherit secrets from Mydia's environment", ctx do
    env_file = Path.join(ctx.tmp_dir, "env")
    start_engine(ctx, autostart: true, env_file: env_file)
    assert_receive {:built_in_status, %Status{engine: :running}}, 1_000
    wait_until(fn -> File.exists?(env_file) end)

    names =
      env_file
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&(&1 |> String.split("=", parts: 2) |> hd()))

    inherited_secrets = Enum.map(Config.child_env_unset(System.get_env()), &elem(&1, 0))
    assert Enum.filter(names, &(&1 in inherited_secrets)) == []
  end
end
