defmodule Mydia.Downloads.BuiltIn.Vpn do
  @moduledoc """
  Gates the built-in engine on the VPN.

  Gluetun is started by the container entrypoint as root, so this process only
  observes it: the entrypoint's preflight file, then gluetun's control server.
  The engine starts only while gluetun reports `running` and the leak check
  passed for the current tunnel; anything else stops it with a named reason.

  `Status` is only written when a value changes, so a steady tunnel does not
  re-broadcast on every poll. Engine calls are idempotent and repeat each poll.
  """

  use GenServer

  alias Mydia.Downloads.BuiltIn.{Engine, GluetunClient, LeakCheck, Status}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @impl true
  def init(opts) do
    engine = Keyword.get(opts, :engine, Engine)

    state = %{
      config: Keyword.fetch!(opts, :config),
      status: Keyword.get(opts, :status, Status),
      base_url: Keyword.get(opts, :base_url, "http://127.0.0.1:8000"),
      interval_ms: Keyword.get(opts, :interval_ms, 10_000),
      engine_fun: Keyword.get(opts, :engine_fun, default_engine_fun(engine)),
      leak_check:
        Keyword.get(opts, :leak_check, fn ->
          LeakCheck.run(relay_url: Mydia.Metadata.metadata_relay_url())
        end),
      verified?: false,
      last_vpn: :connecting,
      last_port: nil
    }

    Status.put(state.status, :vpn, :connecting)
    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = poll(state)
    Process.send_after(self(), :poll, state.interval_ms)
    {:noreply, state}
  end

  defp poll(state) do
    with :ok <- preflight(state.config.gluetun_dir),
         {:ok, req} <- client(state),
         {:ok, "running"} <- status(req, state) do
      up(req, state)
    else
      {:down, reason} -> down(state, reason)
    end
  end

  defp up(req, %{verified?: false} = state) do
    case state.leak_check.() do
      :ok -> up(req, %{state | verified?: true})
      {:error, reason} -> down(state, reason)
    end
  end

  defp up(req, state) do
    public_ip =
      case GluetunClient.public_ip(req) do
        {:ok, ip} -> ip
        _ -> nil
      end

    state =
      put_vpn(state, {:up, %{provider: state.config.vpn_provider, public_ip: public_ip}})

    {state, port} =
      case GluetunClient.forwarded_port(req) do
        {:ok, n} when n > 0 -> {put_port(state, {:forwarded, n}), n}
        _ -> {put_port(state, {:static, state.config.port}), state.config.port}
      end

    state.engine_fun.({:start, port})
    state
  end

  defp down(state, reason) do
    state = put_vpn(state, {:down, reason})
    state.engine_fun.({:stop, reason})
    %{state | verified?: false}
  end

  defp put_vpn(%{last_vpn: value} = state, value), do: state

  defp put_vpn(state, value) do
    Status.put(state.status, :vpn, value)
    %{state | last_vpn: value}
  end

  # A forwarded port is identified by its number alone; `since` records when
  # that number was first seen and survives repeated polls.
  defp put_port(%{last_port: {:forwarded, n, _}} = state, {:forwarded, n}), do: state
  defp put_port(%{last_port: {:static, n}} = state, {:static, n}), do: state

  defp put_port(state, {:forwarded, n}) do
    value = {:forwarded, n, DateTime.utc_now()}
    Status.put(state.status, :port, value)
    %{state | last_port: value}
  end

  defp put_port(state, {:static, _} = value) do
    Status.put(state.status, :port, value)
    %{state | last_port: value}
  end

  defp preflight(dir) do
    case File.read(Path.join(dir, "preflight")) do
      {:ok, body} ->
        cond do
          body =~ "net_admin=missing" -> {:down, :missing_net_admin}
          body =~ "tun=missing" -> {:down, :missing_tun}
          true -> :ok
        end

      {:error, _} ->
        {:down, :vpn_unreachable}
    end
  end

  defp client(state) do
    case File.read(Path.join(state.config.gluetun_dir, "apikey")) do
      {:ok, key} -> {:ok, GluetunClient.new(state.base_url, String.trim(key))}
      {:error, _} -> {:down, :vpn_unreachable}
    end
  end

  defp status(req, state) do
    case GluetunClient.vpn_status(req) do
      {:ok, "running"} = ok -> ok
      {:ok, _other} -> {:down, vpn_down_reason(state.config.gluetun_dir)}
      {:error, _} -> {:down, :vpn_unreachable}
    end
  end

  defp vpn_down_reason(dir) do
    with {:ok, log} <- File.read(Path.join(dir, "gluetun.log")),
         line when is_binary(line) <-
           log |> String.split("\n", trim: true) |> Enum.reverse() |> Enum.find(&(&1 =~ "ERROR")) do
      {:vpn_down, line}
    else
      _ -> :vpn_down
    end
  end

  defp default_engine_fun(engine) do
    fn
      {:start, port} -> Engine.start_engine(engine, port)
      {:stop, reason} -> Engine.stop_engine(engine, reason)
    end
  end
end
