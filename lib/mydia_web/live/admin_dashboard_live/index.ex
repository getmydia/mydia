defmodule MydiaWeb.AdminDashboardLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.Downloads
  alias Mydia.Playback
  alias Mydia.Streaming
  alias Mydia.Streaming.SessionSampler

  # The live chart is driven by sampler broadcasts. Only the day-bucketed
  # figures need a timer, and a daily bucket does not move often.
  @history_refresh :timer.seconds(60)
  @history_days 30

  # Matches SessionSampler's ring buffer: 30 minutes at one sample per 5s.
  @window_size 360

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mydia.PubSub, SessionSampler.topic())
      Phoenix.PubSub.subscribe(Mydia.PubSub, "hls_sessions")
      Phoenix.PubSub.subscribe(Mydia.PubSub, "transcodes")
      :timer.send_interval(@history_refresh, self(), :refresh_history)
    end

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:active_tab, :dashboard)
     |> assign(:samples, SessionSampler.window())
     |> load_now_playing()
     |> load_history()}
  end

  @impl true
  def handle_info({:sample, sample}, socket) do
    # Append rather than re-reading the sampler: the broadcast already carries
    # the new point, and a call per tick per mounted dashboard is wasteful.
    #
    # The negative count is load-bearing. `samples` is oldest-first, so a
    # positive Enum.take/2 would keep the OLDEST 360 and silently drop every new
    # sample once the window filled, freezing the chart after ~30 minutes on any
    # long-lived dashboard session.
    samples = Enum.take(socket.assigns.samples ++ [sample], -@window_size)

    {:noreply, assign(socket, :samples, samples)}
  end

  def handle_info(:refresh_history, socket) do
    {:noreply, load_history(socket)}
  end

  def handle_info(:session_started, socket), do: {:noreply, load_now_playing(socket)}
  def handle_info(:session_ended, socket), do: {:noreply, load_now_playing(socket)}
  def handle_info({:job_updated, _id}, socket), do: {:noreply, load_now_playing(socket)}

  # The transcodes and hls_sessions topics carry messages this page does not
  # act on. Ignore them rather than crashing the LiveView.
  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_now_playing(socket) do
    sessions = Streaming.list_active_sessions()

    background_jobs =
      Downloads.list_transcode_jobs(
        status: ["pending", "transcoding"],
        preload: [:user, media_file: [:media_item, episode: [:media_item]]]
      )
      |> Enum.filter(&(&1.type == "download"))

    socket
    |> assign(:active_sessions, sessions)
    |> assign(:background_jobs, background_jobs)
    |> assign(:recent_activity, recent_activity())
  end

  defp load_history(socket) do
    days = Playback.Stats.plays_by_day(@history_days)

    socket
    |> assign(:days, days)
    |> assign(:plays_today, plays_on(List.last(days)))
    |> assign(:plays_week, days |> Enum.take(-7) |> Enum.map(&plays_on/1) |> Enum.sum())
  end

  defp plays_on(nil), do: 0
  defp plays_on(day), do: day.movies + day.episodes

  defp recent_activity do
    job_preloads = [:user, media_file: [:media_item, episode: [:media_item]]]

    completed_jobs =
      Downloads.list_transcode_jobs(status: ["ready", "failed"], limit: 15, preload: job_preloads)

    watch_history = Playback.list_recent_history(limit: 15)

    job_items =
      Enum.map(completed_jobs, &%{type: :transcode_job, data: &1, timestamp: &1.updated_at})

    history_items =
      Enum.map(watch_history, &%{type: :watch_history, data: &1, timestamp: &1.last_watched_at})

    (job_items ++ history_items)
    |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
    |> Enum.take(20)
  end
end
