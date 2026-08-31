defmodule Mydia.Streaming.HlsSessionStub do
  @moduledoc """
  A process double for `Mydia.Streaming.HlsSession`, for controller tests
  that need a session registered in `Mydia.Streaming.HlsSessionRegistry`
  without paying for a real FFmpeg-backed session (which a real `HlsSession`
  spawns on start).

  `MydiaWeb.Api.HlsController` needs four things from the process behind a
  session id: `HlsSession.get_info/1` (`GenServer.call(pid, :get_info)`),
  `HlsSession.heartbeat/1` (`GenServer.cast(pid, :heartbeat)`),
  `HlsSession.playlist/1` (`GenServer.call(pid, :playlist)`), and
  `HlsSession.request_segment/2` (`GenServer.call(pid, {:request_segment,
  index})`). This stub answers all four: `get_info/1` and `heartbeat/1`
  against the fixed info map it is started with, and `playlist/1` /
  `request_segment/2` against the `responses` map passed to `start_link/3`,
  so a test can drive every outcome the controller's full-mode dispatch
  branches on. It registers under the same `{:session, session_id}` key a
  real session uses, so the controller's actual lookup-and-dispatch path
  (`find_session_by_id/2`, `get_session_info_by_id/2`, `heartbeat_session/2`)
  runs unmodified under test.

  ## Responses

  `responses` may set:

    * `:playlist` - the reply for `HlsSession.playlist/1`, e.g.
      `{:ok, playlist_text}` or `{:error, :window_mode}`. Defaults to
      `{:error, :window_mode}`, matching a real session with no
      `SegmentPlan`.
    * `:request_segment` - the reply for `HlsSession.request_segment/2`,
      e.g. `{:ok, path}`, `{:error, :timeout}`, or `{:error, :window_mode}`.
      Defaults to `{:error, :window_mode}`.

  A reply is returned as-is, synchronously; there is no real wait or
  relocation to simulate, so `{:error, :timeout}` here stands in for what a
  real session would eventually reply once a waiter parked on a segment
  that never arrives, not for `GenServer.call`'s own timeout.
  """

  use GenServer

  @registry Mydia.Streaming.HlsSessionRegistry

  @default_responses %{
    playlist: {:error, :window_mode},
    request_segment: {:error, :window_mode}
  }

  @doc """
  Starts a stub session registered under `{:session, session_id}`.

  `info` is returned verbatim by `get_info/1`; it must carry at least
  `:temp_dir` and `:media_file_id` for `SessionSubtitles.ensure/2` to accept
  it. `responses` overrides the replies for `:playlist` and
  `:request_segment`; see the moduledoc.
  """
  @spec start_link(String.t(), map(), map()) :: GenServer.on_start()
  def start_link(session_id, info, responses \\ %{}) do
    GenServer.start_link(
      __MODULE__,
      {session_id, info, Map.merge(@default_responses, responses)}
    )
  end

  @impl true
  def init({session_id, info, responses}) do
    {:ok, _owner} = Registry.register(@registry, {:session, session_id}, info)
    {:ok, %{info: info, responses: responses}}
  end

  @impl true
  def handle_call(:get_info, _from, state), do: {:reply, {:ok, state.info}, state}
  def handle_call(:playlist, _from, state), do: {:reply, state.responses.playlist, state}

  def handle_call({:request_segment, _index}, _from, state),
    do: {:reply, state.responses.request_segment, state}

  @impl true
  def handle_cast(:heartbeat, state), do: {:noreply, state}
end
