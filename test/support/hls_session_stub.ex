defmodule Mydia.Streaming.HlsSessionStub do
  @moduledoc """
  A process double for `Mydia.Streaming.HlsSession`, for controller tests
  that need a session registered in `Mydia.Streaming.HlsSessionRegistry`
  without paying for a real FFmpeg-backed session (which a real `HlsSession`
  spawns on start).

  `MydiaWeb.Api.HlsController` only ever needs two things from the process
  behind a session id: `HlsSession.get_info/1` (a
  `GenServer.call(pid, :get_info)`) and `HlsSession.heartbeat/1` (a
  `GenServer.cast(pid, :heartbeat)`). This stub answers both against the
  fixed info map it is started with, and registers under the same
  `{:session, session_id}` key a real session uses, so the controller's
  actual lookup-and-dispatch path (`find_session_by_id/2`,
  `get_session_info_by_id/2`, `heartbeat_session/2`) runs unmodified under
  test.
  """

  use GenServer

  @registry Mydia.Streaming.HlsSessionRegistry

  @doc """
  Starts a stub session registered under `{:session, session_id}`.

  `info` is returned verbatim by `get_info/1`; it must carry at least
  `:temp_dir` and `:media_file_id` for `SessionSubtitles.ensure/2` to accept
  it.
  """
  @spec start_link(String.t(), map()) :: GenServer.on_start()
  def start_link(session_id, info) do
    GenServer.start_link(__MODULE__, {session_id, info})
  end

  @impl true
  def init({session_id, info}) do
    {:ok, _owner} = Registry.register(@registry, {:session, session_id}, info)
    {:ok, info}
  end

  @impl true
  def handle_call(:get_info, _from, info), do: {:reply, {:ok, info}, info}

  @impl true
  def handle_cast(:heartbeat, info), do: {:noreply, info}
end
