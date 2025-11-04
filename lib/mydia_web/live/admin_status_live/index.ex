defmodule MydiaWeb.AdminStatusLive.Index do
  use MydiaWeb, :live_view
  alias Mydia.Settings
  alias Mydia.Repo

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Refresh data every 5 seconds for real-time updates
      :timer.send_interval(5000, self(), :refresh)
    end

    {:ok,
     socket
     |> assign(:page_title, "System Status")
     |> load_system_data()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, load_system_data(socket)}
  end

  defp load_system_data(socket) do
    socket
    |> assign(:config_settings, get_all_settings())
    |> assign(:library_paths, Settings.list_library_paths())
    |> assign(:download_clients, Settings.list_download_client_configs())
    |> assign(:indexers, Settings.list_indexer_configs())
    |> assign(:oban_stats, get_oban_stats())
    |> assign(:database_info, get_database_info())
    |> assign(:system_info, get_system_info())
  end

  defp get_all_settings do
    # Get runtime config
    config = Settings.get_runtime_config()

    # Convert to a list of settings with their sources
    [
      # Server settings
      %{
        category: "Server",
        key: "server.port",
        value: config.server.port,
        source: get_setting_source("PORT")
      },
      %{
        category: "Server",
        key: "server.host",
        value: config.server.host,
        source: get_setting_source("HOST")
      },
      %{
        category: "Server",
        key: "server.url_scheme",
        value: config.server.url_scheme,
        source: get_setting_source("URL_SCHEME")
      },
      %{
        category: "Server",
        key: "server.url_host",
        value: config.server.url_host,
        source: get_setting_source("URL_HOST")
      },
      # Database settings
      %{
        category: "Database",
        key: "database.path",
        value: config.database.path,
        source: get_setting_source("DATABASE_PATH")
      },
      %{
        category: "Database",
        key: "database.pool_size",
        value: config.database.pool_size,
        source: get_setting_source("POOL_SIZE")
      },
      # Auth settings
      %{
        category: "Authentication",
        key: "auth.local_enabled",
        value: config.auth.local_enabled,
        source: get_setting_source("LOCAL_AUTH_ENABLED")
      },
      %{
        category: "Authentication",
        key: "auth.oidc_enabled",
        value: config.auth.oidc_enabled,
        source: get_setting_source("OIDC_ENABLED")
      },
      # Media settings
      %{
        category: "Media",
        key: "media.movies_path",
        value: config.media.movies_path,
        source: get_setting_source("MOVIES_PATH")
      },
      %{
        category: "Media",
        key: "media.tv_path",
        value: config.media.tv_path,
        source: get_setting_source("TV_PATH")
      },
      %{
        category: "Media",
        key: "media.scan_interval_hours",
        value: config.media.scan_interval_hours,
        source: get_setting_source("MEDIA_SCAN_INTERVAL_HOURS")
      },
      # Downloads settings
      %{
        category: "Downloads",
        key: "downloads.monitor_interval_minutes",
        value: config.downloads.monitor_interval_minutes,
        source: get_setting_source("DOWNLOAD_MONITOR_INTERVAL_MINUTES")
      }
    ]
    |> Enum.group_by(& &1.category)
  end

  defp get_setting_source(env_var_name) do
    if System.get_env(env_var_name), do: :env, else: :default
  end

  defp get_oban_stats do
    try do
      # Get queue status from Oban
      %{
        running_jobs: 0,
        queued_jobs: 0,
        queues: []
      }
    rescue
      _ ->
        %{
          running_jobs: 0,
          queued_jobs: 0,
          queues: [],
          error: "Oban not available"
        }
    end
  end

  defp get_database_info do
    config = Application.get_env(:mydia, Mydia.Repo, [])
    db_path = Keyword.get(config, :database, "unknown")

    file_size =
      if File.exists?(db_path) do
        File.stat!(db_path).size
      else
        0
      end

    %{
      path: db_path,
      size: format_file_size(file_size),
      exists: File.exists?(db_path),
      health: if(Repo.checked_out?() or test_db_connection(), do: :healthy, else: :unhealthy)
    }
  end

  defp test_db_connection do
    try do
      Repo.query!("SELECT 1")
      true
    rescue
      _ -> false
    end
  end

  defp get_system_info do
    %{
      elixir_version: System.version(),
      otp_version: :erlang.system_info(:otp_release) |> to_string(),
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

  defp source_badge_class(:env), do: "badge-primary"
  defp source_badge_class(:database), do: "badge-info"
  defp source_badge_class(:file), do: "badge-warning"
  defp source_badge_class(:default), do: "badge-ghost"
  defp source_badge_class(_), do: "badge-ghost"

  defp source_label(:env), do: "ENV"
  defp source_label(:database), do: "DB"
  defp source_label(:file), do: "FILE"
  defp source_label(:default), do: "DEFAULT"
  defp source_label(_), do: "UNKNOWN"

  defp health_badge(:healthy), do: "badge-success"
  defp health_badge(:unhealthy), do: "badge-error"
  defp health_badge(:unknown), do: "badge-warning"
  defp health_badge(_), do: "badge-ghost"

  defp enabled_badge(true), do: "badge-success"
  defp enabled_badge(false), do: "badge-ghost"
end
