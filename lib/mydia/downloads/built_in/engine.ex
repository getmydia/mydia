defmodule Mydia.Downloads.BuiltIn.Engine do
  @moduledoc """
  Runs `rqbit server` as a child process and keeps it running.

  The child is opened as a Port and tracked by OS pid, like
  `Mydia.BoundedCommand`, so stopping it kills it rather than orphaning it.
  The pid is also written to `<state_dir>/rqbit.pid` so a child left behind by
  a crashed BEAM is killed on the next start.

  It restarts with backoff up to 5 times, then holds `:crashed` until
  `restart/1`. With the VPN on, the binary is installed setgid
  `mydia-torrent` in the image, which is what puts its traffic in the tunnel.
  """

  use GenServer
  require Logger

  alias Mydia.Downloads.BuiltIn.{Config, Status}

  @max_restarts 5

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  def start_engine(server \\ __MODULE__, listen_port),
    do: GenServer.call(server, {:start, listen_port})

  def stop_engine(server \\ __MODULE__, reason), do: GenServer.call(server, {:stop, reason})
  def restart(server \\ __MODULE__), do: GenServer.call(server, :restart)

  @spec args(Config.t(), pos_integer(), pos_integer()) :: [String.t()]
  def args(%Config{} = config, api_port, listen_port) do
    bind = if config.vpn?, do: ["--bind-device", config.vpn_interface], else: []

    ["--http-api-listen-addr", "127.0.0.1:#{api_port}", "--listen-port", "#{listen_port}"] ++
      ["--disable-upnp-port-forward"] ++
      bind ++
      ["server", "start", "--persistence-location", config.state_dir, config.download_path]
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    config = Keyword.fetch!(opts, :config)

    state = %{
      config: config,
      status: Keyword.get(opts, :status, Status),
      rqbit_path: Keyword.get(opts, :rqbit_path, "rqbit"),
      api_port: Keyword.get(opts, :api_port, 3030),
      credentials: Keyword.fetch!(opts, :credentials),
      backoff_ms: Keyword.get(opts, :backoff_ms, 2_000),
      env: Keyword.get(opts, :env, []),
      port: nil,
      os_pid: nil,
      listen_port: nil,
      restarts: 0
    }

    kill_stale(config.state_dir)

    if Keyword.get(opts, :autostart, false) do
      send(self(), {:autostart, config.port})
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:start, listen_port}, _from, %{port: nil} = state),
    do: {:reply, :ok, spawn_child(%{state | listen_port: listen_port})}

  def handle_call({:start, listen_port}, _from, %{listen_port: listen_port} = state),
    do: {:reply, :ok, state}

  def handle_call({:start, listen_port}, _from, state) do
    state = kill_child(state)
    {:reply, :ok, spawn_child(%{state | listen_port: listen_port})}
  end

  def handle_call({:stop, reason}, _from, state) do
    state = kill_child(state)
    Status.put(state.status, :engine, {:stopped, reason})
    {:reply, :ok, state}
  end

  def handle_call(:restart, _from, state) do
    state = kill_child(%{state | restarts: 0})
    {:reply, :ok, spawn_child(state)}
  end

  @impl true
  def handle_info({:autostart, port}, state) do
    Status.put(state.status, :port, {:static, port})
    {:noreply, spawn_child(%{state | listen_port: port})}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    Logger.debug("rqbit: " <> String.trim_trailing(data))
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.error("rqbit exited with code #{code}")
    state = %{state | port: nil, os_pid: nil}

    if state.restarts >= @max_restarts do
      Status.put(state.status, :engine, {:crashed, {:engine_exit, code}, state.restarts})
      {:noreply, state}
    else
      delay = state.backoff_ms * Integer.pow(2, state.restarts)
      Process.send_after(self(), :respawn, delay)
      {:noreply, %{state | restarts: state.restarts + 1}}
    end
  end

  def handle_info(:respawn, %{port: nil} = state), do: {:noreply, spawn_child(state)}
  def handle_info(:respawn, state), do: {:noreply, state}
  def handle_info({:EXIT, _port, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: kill_child(state)

  defp spawn_child(state) do
    case System.find_executable(state.rqbit_path) do
      nil ->
        Status.put(state.status, :engine, {:crashed, :rqbit_not_found, 0})
        state

      path ->
        File.mkdir_p!(state.config.state_dir)
        File.mkdir_p!(state.config.download_path)
        {user, pass} = state.credentials

        env =
          [{"RQBIT_HTTP_BASIC_AUTH_USERPASS", "#{user}:#{pass}"} | state.env]
          |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

        port =
          Port.open({:spawn_executable, path}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            :hide,
            args: args(state.config, state.api_port, state.listen_port),
            env: env
          ])

        {:os_pid, os_pid} = Port.info(port, :os_pid)
        File.write!(pid_file(state.config.state_dir), Integer.to_string(os_pid))
        Status.put(state.status, :engine, :running)
        %{state | port: port, os_pid: os_pid}
    end
  end

  defp kill_child(%{port: nil} = state), do: state

  defp kill_child(state) do
    Port.close(state.port)
    System.cmd("kill", ["-TERM", Integer.to_string(state.os_pid)], stderr_to_stdout: true)
    File.rm(pid_file(state.config.state_dir))
    %{state | port: nil, os_pid: nil}
  rescue
    ArgumentError -> %{state | port: nil, os_pid: nil}
  end

  defp kill_stale(state_dir) do
    with {:ok, contents} <- File.read(pid_file(state_dir)),
         {pid, ""} <- Integer.parse(String.trim(contents)),
         {:ok, cmdline} <- File.read("/proc/#{pid}/cmdline"),
         true <- String.contains?(cmdline, "rqbit") do
      System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    File.rm(pid_file(state_dir))
  end

  defp pid_file(state_dir), do: Path.join(state_dir, "rqbit.pid")
end
