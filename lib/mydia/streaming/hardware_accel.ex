defmodule Mydia.Streaming.HardwareAccel do
  @moduledoc """
  Holds the hardware probe result and rations access to the device.

  The probe runs in `handle_continue/2`, so `capabilities/1` is an ordinary
  `GenServer.call/3` that queues behind it: callers arriving during the probe
  block until it finishes, and callers after it get a cached struct. There is no
  `:probing` state for the encode paths to handle.

  When this process is not running, `capabilities/0` reports software rather
  than raising. That is the normal state in `test` and on any install where the
  supervisor child is skipped, and it is what lets every pre-existing streaming
  test keep asserting software arguments.
  """

  use GenServer

  require Logger

  alias Mydia.Streaming.HardwareAccel.Capabilities
  alias Mydia.Streaming.HardwareAccel.Probe

  # Household scale, not a hardware limit. Deliberately not configurable: a knob
  # added before anyone hits the ceiling is surface without evidence. If leases
  # are refused in practice, that is the signal to raise it.
  @default_cap 3

  # How many failures for one {backend, codec} pair before that codec drops out
  # of the decode list.
  @default_demote_after 3

  # Every call below queues behind handle_continue's :probe message, which can
  # legitimately run for a few seconds (a hung vainfo or driver ioctl makes
  # that worse, not better). The default GenServer.call/3 timeout of 5s would
  # then raise exit(:timeout) in the caller instead of returning :refused,
  # turning a slow probe into a crash in the playback path -- exactly what
  # this module's "a refusal means encode in software, not an error" contract
  # promises callers it won't do. One shared value so lease/2 and
  # report_failure/3 cannot drift from capabilities/1's timeout again.
  @call_timeout 30_000

  defmodule State do
    @moduledoc false
    defstruct [:capabilities, :cap, :demote_after, :probe, leases: %{}, failures: %{}]
  end

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The probe result, or software capabilities when no probe is running."
  @spec capabilities(GenServer.server()) :: Capabilities.t()
  def capabilities(server \\ __MODULE__) do
    fallback = Capabilities.software("hardware acceleration probe is not running")

    case GenServer.whereis(server) do
      nil -> fallback
      pid -> call_or(pid, :capabilities, fallback)
    end
  end

  @doc """
  Claims a hardware slot. `:background` is refused one slot early so an
  interactive playback start never waits behind a batch download transcode. A
  refusal means "encode in software", not an error.

  Monitors the calling process for the lifetime of the lease: if the holder
  dies without calling `release/2` (an ffmpeg-wrapping session killed by OOM
  or a timeout, the realistic failure mode here), the slot is reclaimed on the
  resulting `:DOWN` rather than leaking until this process restarts.
  """
  @spec lease(GenServer.server(), :playback | :background) :: {:ok, reference()} | :refused
  def lease(server \\ __MODULE__, priority) do
    case GenServer.whereis(server) do
      nil -> :refused
      pid -> call_or(pid, {:lease, priority}, :refused)
    end
  end

  @spec release(GenServer.server(), reference()) :: :ok
  def release(server \\ __MODULE__, ref) do
    case GenServer.whereis(server) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:release, ref})
    end
  end

  @doc "Records that a hardware encode failed for a source codec."
  @spec report_failure(GenServer.server(), atom(), String.t() | atom() | nil) :: :ok
  def report_failure(server \\ __MODULE__, backend, source_codec) do
    case GenServer.whereis(server) do
      nil -> :ok
      pid -> call_or(pid, {:report_failure, backend, source_codec}, :ok)
    end
  end

  # GenServer.whereis/1 resolves a pid, but the probe process can exit in the
  # gap between that lookup and this call actually being handled (a probe
  # crash and its supervisor restart are the realistic version of this,
  # boot-time or not). A plain GenServer.call/3 turns that race into an exit
  # in the CALLER -- an admin LiveView mount, or a playback session -- which
  # contradicts this module's documented contract that it never raises and
  # instead reports software/refused/ok, the same as when the process was
  # never running at all. Every call site above already has that fallback
  # value on hand for the "not running" branch; a mid-call exit gets the
  # identical one.
  @spec call_or(pid(), term(), term()) :: term()
  defp call_or(pid, message, fallback) do
    GenServer.call(pid, message, @call_timeout)
  catch
    :exit, _ -> fallback
  end

  @impl true
  def init(opts) do
    state = %State{
      cap: Keyword.get(opts, :cap, @default_cap),
      demote_after: Keyword.get(opts, :demote_after, @default_demote_after),
      probe: Keyword.get(opts, :probe, &Probe.run/1)
    }

    {:ok, state, {:continue, :probe}}
  end

  @impl true
  def handle_continue(:probe, state) do
    config = Mydia.Config.get()
    streaming = Map.get(config || %{}, :streaming) || %{}

    opts = [
      hwaccel: Map.get(streaming, :hwaccel, :auto),
      device: Map.get(streaming, :hwaccel_device)
    ]

    capabilities = state.probe.(opts)

    log_result(capabilities)

    {:noreply, %{state | capabilities: capabilities}}
  end

  defp log_result(%Capabilities{backend: :none, reason: reason}) do
    Logger.info("Hardware transcoding unavailable: #{reason}. Encoding in software.")
  end

  defp log_result(%Capabilities{} = caps) do
    Logger.info(
      "Hardware transcoding enabled: #{caps.backend} on #{caps.device}, " <>
        "decodes #{inspect(caps.decode_profiles)}, encodes #{inspect(caps.encoders)}"
    )
  end

  @impl true
  def handle_call(:capabilities, _from, state), do: {:reply, state.capabilities, state}

  def handle_call({:lease, _priority}, _from, %State{capabilities: %{backend: :none}} = state) do
    {:reply, :refused, state}
  end

  def handle_call({:lease, priority}, {pid, _tag}, state) do
    if map_size(state.leases) < limit_for(priority, state.cap) do
      # The monitor reference doubles as the lease reference handed back to
      # the caller: it is already unique, and using it directly means the
      # :DOWN handler below needs no separate index to find which lease a
      # dead holder held.
      ref = Process.monitor(pid)
      {:reply, {:ok, ref}, %{state | leases: Map.put(state.leases, ref, priority)}}
    else
      {:reply, :refused, state}
    end
  end

  def handle_call({:report_failure, backend, source_codec}, _from, state) do
    case Capabilities.codec_atom(source_codec) do
      nil ->
        {:reply, :ok, state}

      codec ->
        key = {backend, codec}
        count = Map.get(state.failures, key, 0) + 1
        state = %{state | failures: Map.put(state.failures, key, count)}

        {:reply, :ok, maybe_demote(state, codec, count)}
    end
  end

  # Demotion is per codec, never per backend. Losing the whole device because
  # one advertised profile is broken would throw away every other codec it
  # handles correctly.
  defp maybe_demote(state, codec, count) do
    if count >= state.demote_after and codec in state.capabilities.decode_profiles do
      Logger.warning(
        "Hardware decode of #{codec} failed #{count} times; dropping it to the hybrid tier"
      )

      profiles = List.delete(state.capabilities.decode_profiles, codec)
      %{state | capabilities: %{state.capabilities | decode_profiles: profiles}}
    else
      state
    end
  end

  defp limit_for(:background, cap), do: max(cap - 1, 0)
  defp limit_for(_playback, cap), do: cap

  @impl true
  def handle_cast({:release, ref}, state) do
    # Flush so a DOWN that already fired (or fires concurrently with this
    # cast) for a ref we're about to forget cannot land in the mailbox and be
    # treated as a live message later.
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | leases: Map.delete(state.leases, ref)}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.leases, ref) do
      {nil, _leases} ->
        {:noreply, state}

      {priority, leases} ->
        Logger.info(
          "Reclaimed a leaked #{priority} hardware lease: holder exited (#{inspect(reason)})"
        )

        {:noreply, %{state | leases: leases}}
    end
  end
end
