defmodule Mydia.Streaming.SessionSampler do
  @moduledoc """
  Samples active playback sessions on a fixed interval to feed the admin
  dashboard's live bandwidth chart.

  Bandwidth here is *estimated*. It is derived from stream properties, namely
  the file's own bitrate and the transcode ladder's cap when the client asked
  for one, and not from measured socket throughput. A paused client still
  counts, because the estimate describes the stream rather than current
  traffic. This mirrors what Plex's dashboard reports.

  State is in memory and resets on restart, which is the correct lifetime for
  a live 30-minute strip. Longer-range reporting comes from
  `Mydia.Playback.Stats`, which reads the durable events table.
  """

  use GenServer

  require Logger

  alias Mydia.Library
  alias Mydia.Streaming.HlsSessionSupervisor

  @tick_interval :timer.seconds(5)
  @window_size 360
  @topic "playback_samples"

  defmodule Sample do
    @moduledoc """
    One instant of playback load.

    `sessions` maps a stable per-session key to estimated Mbps. Keys are stable
    across ticks so the chart can draw one band per session.
    """

    @type t :: %__MODULE__{
            at: DateTime.t(),
            sessions: %{String.t() => float()},
            unmeasured_count: non_neg_integer()
          }

    defstruct [:at, sessions: %{}, unmeasured_count: 0]
  end

  defmodule State do
    @moduledoc false
    defstruct samples: [], bitrate_cache: %{}, list_sessions: nil, window_size: 360
  end

  ## Client API

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    case name do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  The PubSub topic each tick is broadcast on, as `{:sample, %Sample{}}`.
  """
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  The retained window, oldest first, ready for charting.

  Returns `[]` when the sampler is not running. A crashed sampler must render
  an empty chart, not take down every mounted dashboard with it.
  """
  @spec window(GenServer.server()) :: [Sample.t()]
  def window(server \\ __MODULE__) do
    GenServer.call(server, :window)
  catch
    :exit, _ -> []
  end

  @doc """
  The most recent sample, or an empty one when the sampler is not running.
  """
  @spec current(GenServer.server()) :: Sample.t()
  def current(server \\ __MODULE__) do
    GenServer.call(server, :current)
  catch
    :exit, _ -> %Sample{at: DateTime.utc_now(), sessions: %{}}
  end

  @doc """
  Estimated Mbps for one session.

  Direct play ships the file as-is, so the file's bitrate is the estimate. A
  transcode is bounded by `max_bitrate` when the client asked for a rung, and
  otherwise targets roughly the source rate.

  Returns `nil` when the file has no known bitrate. Callers count those
  separately so the UI can disclose how many streams are unmeasured rather
  than silently reporting a low total.
  """
  @spec estimate_mbps(map(), integer() | nil) :: float() | nil
  def estimate_mbps(_session, nil), do: nil
  def estimate_mbps(%{mode: :direct}, bitrate), do: to_mbps(bitrate)

  def estimate_mbps(%{max_bitrate: cap}, bitrate) when is_integer(cap),
    do: to_mbps(min(cap, bitrate))

  def estimate_mbps(_session, bitrate), do: to_mbps(bitrate)

  ## Server callbacks

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :tick_interval, @tick_interval)

    if Keyword.get(opts, :tick, true) do
      :timer.send_interval(interval, self(), :tick)
    end

    state = %State{
      list_sessions: Keyword.get(opts, :list_sessions, &default_list_sessions/0),
      window_size: Keyword.get(opts, :window_size, @window_size)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:window, _from, state) do
    {:reply, Enum.reverse(state.samples), state}
  end

  def handle_call(:current, _from, state) do
    {:reply, List.first(state.samples) || %Sample{at: DateTime.utc_now()}, state}
  end

  # Tests drive ticks deterministically instead of waiting on the timer.
  def handle_call(:tick_now, _from, state) do
    state = tick(state)
    {:reply, List.first(state.samples), state}
  end

  @impl true
  def handle_info(:tick, state) do
    {:noreply, tick(state)}
  end

  ## Internals

  defp tick(state) do
    entries = state.list_sessions.() |> normalize()

    {cache, sessions, unmeasured} =
      Enum.reduce(entries, {state.bitrate_cache, %{}, 0}, fn entry, {cache, acc, unmeasured} ->
        {cache, bitrate} = fetch_bitrate(cache, entry.media_file_id)

        case estimate_mbps(entry, bitrate) do
          nil -> {cache, acc, unmeasured + 1}
          mbps -> {cache, Map.put(acc, entry.session_key, mbps), unmeasured}
        end
      end)

    sample = %Sample{
      at: DateTime.utc_now(),
      sessions: sessions,
      unmeasured_count: unmeasured
    }

    Phoenix.PubSub.broadcast(Mydia.PubSub, @topic, {:sample, sample})

    %{
      state
      | samples: Enum.take([sample | state.samples], state.window_size),
        bitrate_cache: bound_cache(cache, entries)
    }
  end

  defp default_list_sessions, do: HlsSessionSupervisor.list_sessions()

  # Registry entries are `{key, pid, meta}` where key is
  # `{:hls_session, media_file_id, user_id}`. Anything that does not match that
  # shape, or that carries no media_file_id, is skipped rather than crashing the
  # tick: a session can die between the registry read and this call.
  defp normalize(entries) do
    Enum.flat_map(entries, fn
      {{_tag, media_file_id, user_id}, _pid, meta} when not is_nil(media_file_id) ->
        [
          %{
            session_key: "#{media_file_id}:#{user_id}",
            media_file_id: media_file_id,
            mode: Map.get(meta, :mode) || :transcode,
            max_bitrate: Map.get(meta, :max_bitrate)
          }
        ]

      _other ->
        []
    end)
  end

  defp fetch_bitrate(cache, media_file_id) do
    case Map.fetch(cache, media_file_id) do
      {:ok, bitrate} ->
        {cache, bitrate}

      :error ->
        bitrate =
          case Library.get_media_file(media_file_id) do
            nil -> nil
            media_file -> media_file.bitrate
          end

        {Map.put(cache, media_file_id, bitrate), bitrate}
    end
  end

  # Bound the cache to what is streaming right now. A session that stops and
  # later restarts costs one extra query, which is cheaper than growing this map
  # for the life of the node.
  defp bound_cache(cache, entries) do
    Map.take(cache, Enum.map(entries, & &1.media_file_id))
  end

  defp to_mbps(bps), do: Float.round(bps / 1_000_000, 2)
end
