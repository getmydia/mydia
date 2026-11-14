defmodule Mydia.Downloads.BuiltIn.Limits do
  @moduledoc """
  Pushes the session-wide download and upload speed limits to rqbit.

  rqbit forgets them whenever the engine restarts, so the limits go out each
  time `Status` reports the engine running after a non-running state, and
  again when `push/2` hands over a new config. A running to running status
  change (a warnings update, including the one written here) pushes nothing.

  A failed push is recorded as a `{:limits_failed, message}` entry in the
  `Status` warnings, replacing any earlier one. A later success removes it.

  Options: `:config` (a `Config`, required), `:name` (default `__MODULE__`),
  `:status` and `:topic` (the `Status` server and its PubSub topic, for tests)
  and `:resolve` (a zero-arity function returning `{:ok, adapter, client_config}`,
  default: the running built-in client).
  """

  use GenServer

  require Logger

  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.BuiltIn.{Config, Status}
  alias Mydia.Downloads.Queue

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Stores new limits and pushes them. A cast: with no process running (the
  built-in client is off) it does nothing.
  """
  @spec push(GenServer.server(), Config.t()) :: :ok
  def push(server \\ __MODULE__, %Config{} = config), do: GenServer.cast(server, {:push, config})

  @impl true
  def init(opts) do
    topic = Keyword.get(opts, :topic, Status.topic())
    :ok = Phoenix.PubSub.subscribe(Mydia.PubSub, topic)

    state = %{
      config: Keyword.fetch!(opts, :config),
      status: Keyword.get(opts, :status, Status),
      resolve: Keyword.get(opts, :resolve, fn -> Queue.resolve_adapter(BuiltIn.name()) end),
      running?: false
    }

    {:ok, state, {:continue, :sync}}
  end

  # The engine may have reported running before this process subscribed.
  @impl true
  def handle_continue(:sync, state) do
    case safe_get(state.status) do
      %Status{} = status -> {:noreply, observe(state, status)}
      nil -> {:noreply, state}
    end
  end

  @impl true
  def handle_info({:built_in_status, %Status{} = status}, state),
    do: {:noreply, observe(state, status)}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_cast({:push, config}, state) do
    state = %{state | config: config}
    if state.running?, do: apply_limits(state)
    {:noreply, state}
  end

  defp observe(state, %Status{engine: engine}) do
    running? = engine == :running
    if running? and not state.running?, do: apply_limits(state)
    %{state | running?: running?}
  end

  defp apply_limits(state) do
    limits = %{
      download_bps: bytes_per_second(state.config.download_limit),
      upload_bps: bytes_per_second(state.config.upload_limit)
    }

    with {:ok, adapter, client_config} <- resolve(state),
         :ok <- adapter.set_session_limits(client_config, limits) do
      set_warning(state, nil)
    else
      {:error, reason} ->
        message = describe(reason)
        Logger.warning("Could not apply the built-in client's speed limits: #{message}")
        set_warning(state, {:limits_failed, message})
    end
  end

  # Looking the client up reads the database; a failure there is a failed
  # push, not a crash of the instance tree.
  defp resolve(state) do
    state.resolve.()
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  defp bytes_per_second(kib) when is_integer(kib) and kib > 0, do: kib * 1024
  defp bytes_per_second(_), do: nil

  defp describe(%{message: message}) when is_binary(message), do: message
  defp describe(reason), do: inspect(reason)

  defp set_warning(state, warning) do
    case safe_get(state.status) do
      %Status{warnings: warnings} ->
        kept = Enum.reject(warnings, &match?({:limits_failed, _}, &1))
        new = if warning, do: kept ++ [warning], else: kept
        if new != warnings, do: Status.put(state.status, :warnings, new)

      nil ->
        :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp safe_get(server) do
    Status.get(server)
  catch
    :exit, _ -> nil
  end
end
