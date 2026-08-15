defmodule Mydia.Plugins.SingleFlight do
  @moduledoc """
  Per-plugin invocation serialization (U4).

  Reactive (`on-event`), scheduled (`on-schedule`), and inline invocations of one
  plugin share its KV state; a plain get/set read-modify-write under concurrency
  loses updates and double-pushes. This GenServer is the host's single-flight
  lock: every `Mydia.Plugins.Host.call/4` acquires the plugin's lock before
  running and releases it after, so only one invocation per plugin runs at a time
  — consistent with the one-pool-per-plugin model, without growing a KV
  compare-and-swap primitive.

  Two acquire modes:

    * `:wait` — block until the lock is free, then hold it (reactive/inline). A
      reactive event arriving during a long scheduled sync runs *after* it, never
      interleaved.
    * `:skip` — return `:busy` immediately if the lock is held (the scheduler).
      A still-running sync makes the next tick a no-op (non-reentrant), so ticks
      never pile up.

  The holder is monitored: if an invocation process dies (crash, kill-on-timeout)
  without releasing, the lock is freed and granted to the next waiter. There is
  no persistent flag to get stuck — on host restart the GenServer starts empty,
  so a tick always fires (no schedule deadlock).

  Despite the namespace this GenServer is a plain named-lock server with no
  plugin-specific behaviour. `Mydia.Streaming.SessionSubtitles` runs a second
  instance under `Mydia.Streaming.SubtitleLock` to serialize subtitle
  extraction. Keep it generic; anything plugin-specific belongs in
  `Mydia.Plugins.Host`.
  """

  use GenServer

  @type mode :: :wait | :skip

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Acquires the lock for `slug` on behalf of the calling process.

  `:wait` blocks until granted and returns `:ok`. `:skip` returns `:ok` if the
  lock was free (now held) or `:busy` if another process holds it.
  """
  @spec acquire(String.t(), mode(), GenServer.server()) :: :ok | :busy
  def acquire(slug, mode \\ :wait, server \\ __MODULE__) when mode in [:wait, :skip] do
    GenServer.call(server, {:acquire, slug, mode, self()}, :infinity)
  end

  @doc "Releases the lock for `slug` held by the calling process."
  @spec release(String.t(), GenServer.server()) :: :ok
  def release(slug, server \\ __MODULE__) do
    GenServer.cast(server, {:release, slug, self()})
  end

  @doc """
  Runs `fun` while holding the lock, releasing it afterward. Returns `{:busy}`
  without running `fun` when `mode` is `:skip` and the lock is held.
  """
  @spec run(String.t(), mode(), (-> result), GenServer.server()) :: result | {:busy}
        when result: term()
  def run(slug, mode, fun, server \\ __MODULE__) do
    case acquire(slug, mode, server) do
      :ok ->
        try do
          fun.()
        after
          release(slug, server)
        end

      :busy ->
        {:busy}
    end
  end

  # ── Server ────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # locks: %{slug => %{holder: pid, ref: monitor_ref, waiters: :queue.t()}}
    # refs:  %{monitor_ref => slug}  (reverse index for DOWN handling)
    {:ok, %{locks: %{}, refs: %{}}}
  end

  @impl true
  def handle_call({:acquire, slug, mode, pid}, from, state) do
    case Map.get(state.locks, slug) do
      nil ->
        {:reply, :ok, grant(state, slug, pid)}

      %{waiters: waiters} = lock ->
        case mode do
          :skip ->
            {:reply, :busy, state}

          :wait ->
            lock = %{lock | waiters: :queue.in({from, pid}, waiters)}
            {:noreply, put_in(state.locks[slug], lock)}
        end
    end
  end

  @impl true
  def handle_cast({:release, slug, pid}, state) do
    case Map.get(state.locks, slug) do
      %{holder: ^pid} = lock -> {:noreply, hand_off(state, slug, lock)}
      _ -> {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.get(state.refs, ref) do
      nil ->
        {:noreply, state}

      slug ->
        case Map.get(state.locks, slug) do
          %{ref: ^ref} = lock -> {:noreply, hand_off(state, slug, lock)}
          _ -> {:noreply, %{state | refs: Map.delete(state.refs, ref)}}
        end
    end
  end

  # Grant the lock for `slug` to `pid`, monitoring it for auto-release.
  defp grant(state, slug, pid) do
    ref = Process.monitor(pid)

    %{
      state
      | locks: Map.put(state.locks, slug, %{holder: pid, ref: ref, waiters: :queue.new()}),
        refs: Map.put(state.refs, ref, slug)
    }
  end

  # Release the held lock and hand it to the next waiter, or drop it if none.
  defp hand_off(state, slug, %{ref: ref, waiters: waiters}) do
    state = %{state | refs: Map.delete(state.refs, ref)}
    Process.demonitor(ref, [:flush])

    case :queue.out(waiters) do
      {{:value, {from, pid}}, rest} ->
        new_ref = Process.monitor(pid)
        GenServer.reply(from, :ok)

        %{
          state
          | locks: Map.put(state.locks, slug, %{holder: pid, ref: new_ref, waiters: rest}),
            refs: Map.put(state.refs, new_ref, slug)
        }

      {:empty, _} ->
        %{state | locks: Map.delete(state.locks, slug)}
    end
  end
end
