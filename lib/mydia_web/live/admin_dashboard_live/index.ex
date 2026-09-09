defmodule MydiaWeb.AdminDashboardLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.Downloads
  alias Mydia.Playback
  alias Mydia.Streaming

  # Now Playing updates on PubSub push; only the day-bucketed figures need a
  # timer, since a daily bucket does not move often.
  @history_refresh :timer.seconds(60)
  @history_days 30

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mydia.PubSub, "hls_sessions")
      Phoenix.PubSub.subscribe(Mydia.PubSub, "transcodes")
      :timer.send_interval(@history_refresh, self(), :refresh_history)
    end

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:active_tab, :dashboard)
     |> load_now_playing()
     |> load_history()}
  end

  @impl true
  def handle_info(:refresh_history, socket) do
    {:noreply, load_history(socket)}
  end

  def handle_info(:session_started, socket), do: {:noreply, load_now_playing(socket)}
  def handle_info(:session_ended, socket), do: {:noreply, load_now_playing(socket)}
  def handle_info({:job_updated, _id}, socket), do: {:noreply, load_now_playing(socket)}

  def handle_info({:session_updated, _session_id}, socket),
    do: {:noreply, load_now_playing(socket)}

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

    # Plays, not progress rows: a media-server sync writes progress for watches
    # that happened elsewhere and stamps it with the sync time, which flooded
    # this list with imported Plex history the moment a sync ran.
    plays = Playback.Stats.recent_plays(15)

    job_items =
      Enum.map(completed_jobs, &%{type: :transcode_job, data: &1, timestamp: &1.updated_at})

    history_items =
      Enum.map(plays, &%{type: :watch_history, data: &1, timestamp: &1.last_watched_at})

    (job_items ++ history_items)
    |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
    |> Enum.take(20)
  end
end
