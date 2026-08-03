defmodule MydiaWeb.AdminSystemLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.DB
  alias Mydia.Health
  alias Mydia.Repo
  alias Mydia.Settings
  alias Mydia.Streaming
  alias Mydia.Playback
  alias Mydia.Downloads
  alias Mydia.System

  # Capture Mix.env at compile time since Mix is not available in releases
  @env Mix.env()

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      refresh_interval = Application.get_env(:mydia, :admin_refresh_interval, 5000)
      :timer.send_interval(refresh_interval, self(), :refresh_system_data)
      Phoenix.PubSub.subscribe(Mydia.PubSub, "hls_sessions")
      Phoenix.PubSub.subscribe(Mydia.PubSub, "transcodes")
    end

    {:ok,
     socket
     |> assign(:page_title, "Configuration - Status")
     |> assign(:active_tab, :status)
     |> load_data()
     |> load_system_data()
     |> load_player_data()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    # Handle backward-compatible ?tab= redirects
    case params["tab"] do
      nil ->
        {:noreply, socket}

      tab ->
        route = tab_to_route(tab)
        {:noreply, push_navigate(socket, to: route)}
    end
  end

  ## Timer and PubSub handlers

  @impl true
  def handle_info(:refresh_system_data, socket) do
    {:noreply, load_system_data(socket)}
  end

  @impl true
  def handle_info(:session_started, socket) do
    {:noreply, update(socket, :active_sessions, fn _ -> Streaming.list_active_sessions() end)}
  end

  @impl true
  def handle_info({:job_updated, _id}, socket) do
    job_preloads = [:user, media_file: [:media_item, episode: [:media_item]]]

    active_jobs =
      Downloads.list_transcode_jobs(
        status: ["pending", "transcoding", "playing"],
        preload: job_preloads
      )

    recent_activity = build_recent_activity(job_preloads)

    {:noreply,
     socket
     |> assign(:active_jobs, active_jobs)
     |> assign(:recent_activity, recent_activity)}
  end

  ## Status Tab Events

  @impl true
  def handle_event("delete_transcode_job", %{"id" => job_id}, socket) do
    case Repo.get(Downloads.TranscodeJob, job_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Job not found")}

      job ->
        {:ok, _} = Downloads.cancel_transcode_job(job)
        {:noreply, put_flash(socket, :info, "Transcode job deleted")}
    end
  end

  @impl true
  def handle_event("clear_recent_activity", _params, socket) do
    Downloads.delete_all_completed_jobs()
    Playback.clear_recent_history()

    job_preloads = [:user, media_file: [:media_item, episode: [:media_item]]]
    recent_activity = build_recent_activity(job_preloads)

    {:noreply,
     socket
     |> assign(:recent_activity, recent_activity)
     |> put_flash(:info, "Cleared recent activity")}
  end

  ## Private Helpers

  defp load_data(socket) do
    # Load summary counts for status overview (not full lists).
    #
    # `upgrade_health/0` is a counting query over an indexed column, but it
    # belongs here rather than in `load_system_data/1` on purpose: a wedged
    # upgrade is a condition that lasts hours, so re-counting it every five
    # seconds alongside the memory and uptime readouts would buy nothing.
    socket
    |> assign(:library_paths_count, length(Settings.list_library_paths()))
    |> assign(:download_clients_count, length(Settings.list_download_client_configs()))
    |> assign(:indexers_count, length(Settings.list_indexer_configs()))
    |> assign(:stuck_upgrades, Health.upgrade_health().stuck_upgrades)
  end

  defp load_system_data(socket) do
    socket
    |> assign(:database_info, get_database_info())
    |> assign(:system_info, get_system_info())
  end

  defp load_player_data(socket) do
    job_preloads = [:user, media_file: [:media_item, episode: [:media_item]]]

    active_jobs =
      Downloads.list_transcode_jobs(
        status: ["pending", "transcoding", "playing"],
        preload: job_preloads
      )

    recent_activity = build_recent_activity(job_preloads)

    socket
    |> assign(:active_sessions, Streaming.list_active_sessions())
    |> assign(:active_jobs, active_jobs)
    |> assign(:recent_activity, recent_activity)
  end

  defp build_recent_activity(job_preloads) do
    completed_jobs =
      Downloads.list_transcode_jobs(
        status: ["ready", "failed"],
        limit: 15,
        preload: job_preloads
      )

    watch_history = Playback.list_recent_history(limit: 15)

    job_items =
      Enum.map(completed_jobs, fn job ->
        %{type: :transcode_job, data: job, timestamp: job.updated_at}
      end)

    history_items =
      Enum.map(watch_history, fn progress ->
        %{type: :watch_history, data: progress, timestamp: progress.last_watched_at}
      end)

    (job_items ++ history_items)
    |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
    |> Enum.take(20)
  end

  defp get_database_info do
    if DB.postgres?() do
      get_postgres_database_info()
    else
      get_sqlite_database_info()
    end
  end

  defp get_sqlite_database_info do
    config = Application.get_env(:mydia, Mydia.Repo, [])
    db_path = Keyword.get(config, :database, "unknown")

    file_size =
      if File.exists?(db_path) do
        File.stat!(db_path).size
      else
        0
      end

    %{
      adapter: :sqlite,
      path: db_path,
      size: format_file_size(file_size),
      exists: File.exists?(db_path),
      health: get_database_health()
    }
  end

  defp get_postgres_database_info do
    config = Application.get_env(:mydia, Mydia.Repo, [])
    hostname = Keyword.get(config, :hostname, "localhost")
    port = Keyword.get(config, :port, 5432)
    database = Keyword.get(config, :database, "unknown")

    size =
      try do
        %{rows: [[size_bytes]]} =
          Repo.query!("SELECT pg_database_size(current_database())")

        format_file_size(size_bytes)
      rescue
        _ -> "Unknown"
      end

    %{
      adapter: :postgres,
      hostname: hostname,
      port: port,
      database: database,
      size: size,
      health: get_database_health()
    }
  end

  defp get_database_health do
    if @env == :test do
      :healthy
    else
      if Repo.checked_out?() or test_db_connection(), do: :healthy, else: :unhealthy
    end
  end

  defp test_db_connection do
    Repo.query!("SELECT 1")
    true
  rescue
    _ -> false
  end

  defp get_system_info do
    memory = :erlang.memory()
    total_memory = Keyword.get(memory, :total, 0)

    %{
      app_version: System.app_version(),
      dev_mode: System.dev_mode?(),
      elixir_version: Elixir.System.version(),
      memory_used: format_file_size(total_memory),
      uptime: format_uptime(:erlang.statistics(:wall_clock) |> elem(0))
    }
  end

  defp format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776, 2)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_uptime(milliseconds) do
    seconds = div(milliseconds, 1000)
    minutes = div(seconds, 60)
    hours = div(minutes, 60)
    days = div(hours, 24)

    cond do
      days > 0 -> "#{days}d #{rem(hours, 24)}h"
      hours > 0 -> "#{hours}h #{rem(minutes, 60)}m"
      minutes > 0 -> "#{minutes}m #{rem(seconds, 60)}s"
      true -> "#{seconds}s"
    end
  end

  # Backward-compatible ?tab= redirect whitelist
  defp tab_to_route("clients"), do: "/admin/config/clients"
  defp tab_to_route("indexers"), do: "/admin/config/indexers"
  defp tab_to_route("quality"), do: "/admin/config/quality"
  defp tab_to_route("library"), do: "/admin/config/library-paths"
  defp tab_to_route("media_servers"), do: "/admin/config/media-servers"
  defp tab_to_route("remote_access"), do: "/admin/config/remote-access"
  defp tab_to_route("general"), do: "/admin/config/settings"
  defp tab_to_route(_), do: "/admin/config/status"
end
