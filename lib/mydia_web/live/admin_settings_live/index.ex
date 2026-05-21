defmodule MydiaWeb.AdminSettingsLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.Settings
  alias MydiaWeb.AdminSettingsLive.Components

  require Logger
  alias Mydia.Logger, as: MydiaLogger

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Configuration - Settings")
     |> assign(:active_tab, :settings)
     |> load_data()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  ## General Settings Events

  @impl true
  def handle_event(
        "update_setting_form",
        %{"category" => category, "settings" => settings},
        socket
      ) do
    category_atom = category_string_to_atom(category)

    results =
      settings
      |> Enum.map(fn {key, value} ->
        changeset =
          validate_config_setting(%{
            key: key,
            value: to_string(value),
            category: category_atom
          })

        if changeset.valid? do
          validated_data = Ecto.Changeset.apply_changes(changeset)

          validated_data_with_user =
            Map.put(validated_data, :updated_by_id, socket.assigns.current_user.id)

          upsert_config_setting(validated_data_with_user)
        else
          {:error, changeset}
        end
      end)

    if Enum.all?(results, fn result -> match?({:ok, _}, result) end) do
      {:noreply,
       socket
       |> put_flash(:info, "Settings updated successfully")
       |> load_data()}
    else
      failed_results =
        results
        |> Enum.with_index()
        |> Enum.reject(fn {result, _} -> match?({:ok, _}, result) end)

      Enum.each(failed_results, fn {{:error, error}, idx} ->
        setting_key = Enum.at(Map.keys(settings), idx)

        MydiaLogger.log_error(:liveview, "Failed to update setting",
          error: error,
          error_details: inspect(error, pretty: true),
          operation: :update_setting,
          category: category,
          setting_key: setting_key,
          user_id: socket.assigns.current_user.id
        )
      end)

      error_msg = MydiaLogger.user_error_message(:update_setting, :multiple_failures)

      {:noreply,
       socket
       |> put_flash(:error, error_msg)}
    end
  end

  @impl true
  def handle_event(
        "toggle_setting",
        %{"key" => key, "category" => category} = params,
        socket
      ) do
    category_atom = category_string_to_atom(category)

    new_value =
      case {Map.get(params, "next_value"), Map.get(params, "value")} do
        {next_value, _value} when is_binary(next_value) ->
          next_value

        {nil, nil} ->
          case Settings.get_config_setting_by_key(key) do
            nil -> "true"
            setting -> to_string(!parse_boolean_value(setting.value))
          end

        {nil, value} ->
          to_string(value)
      end

    changeset =
      validate_config_setting(%{
        key: key,
        value: new_value,
        category: category_atom
      })

    if changeset.valid? do
      validated_data = Ecto.Changeset.apply_changes(changeset)

      validated_data_with_user =
        Map.put(validated_data, :updated_by_id, socket.assigns.current_user.id)

      case upsert_config_setting(validated_data_with_user) do
        {:ok, _setting} ->
          {:noreply,
           socket
           |> put_flash(:info, "Setting updated successfully")
           |> load_data()}

        {:error, changeset} ->
          MydiaLogger.log_error(:liveview, "Failed to toggle setting",
            error: changeset,
            error_details: inspect(changeset, pretty: true),
            changeset_errors: changeset.errors,
            operation: :update_setting,
            category: category,
            setting_key: key,
            user_id: socket.assigns.current_user.id
          )

          error_msg = MydiaLogger.user_error_message(:update_setting, changeset)

          {:noreply,
           socket
           |> put_flash(:error, error_msg)}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "Invalid setting value")}
    end
  end

  @impl true
  def handle_event(
        "update_select_setting",
        %{"key" => key, "category" => category, "value" => value},
        socket
      ) do
    category_atom = category_string_to_atom(category)

    changeset =
      validate_config_setting(%{
        key: key,
        value: value,
        category: category_atom
      })

    if changeset.valid? do
      validated_data = Ecto.Changeset.apply_changes(changeset)

      validated_data_with_user =
        Map.put(validated_data, :updated_by_id, socket.assigns.current_user.id)

      case upsert_config_setting(validated_data_with_user) do
        {:ok, _setting} ->
          {:noreply,
           socket
           |> put_flash(:info, "Setting updated successfully")
           |> load_data()}

        {:error, _changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to update setting")}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "Invalid setting value")}
    end
  end

  @impl true
  def handle_event("clear_crash_queue", _params, socket) do
    Mydia.CrashReporter.clear_queue()

    {:noreply,
     socket
     |> load_data()
     |> put_flash(:info, "Crash report queue cleared")}
  end

  ## Private Helpers

  defp load_data(socket) do
    socket
    |> assign(:config_settings_with_sources, get_all_settings_with_sources())
    |> assign(:crash_report_stats, Mydia.CrashReporter.stats())
  end

  defp get_all_settings_with_sources do
    config = Settings.get_runtime_config()

    config =
      if is_struct(config) do
        config
      else
        Mydia.Config.Schema.defaults()
      end

    flaresolverr = config.flaresolverr || %Mydia.Config.Schema.FlareSolverr{}
    metadata = config.metadata || %Mydia.Config.Schema.Metadata{}

    # Fetch all DB settings in one query to avoid N+1 per-key lookups
    all_db_settings = Settings.list_config_settings() |> Map.new(&{&1.key, &1})

    %{
      "Server" => [
        %{
          key: "server.port",
          label: "Port",
          type: :integer,
          value: config.server.port,
          source: get_source("PORT", "server.port", all_db_settings)
        },
        %{
          key: "server.host",
          label: "Host",
          type: :string,
          value: config.server.host,
          source: get_source("HOST", "server.host", all_db_settings)
        },
        %{
          key: "server.url_scheme",
          label: "URL Scheme",
          type: :string,
          value: config.server.url_scheme,
          source: get_source("URL_SCHEME", "server.url_scheme", all_db_settings)
        },
        %{
          key: "server.url_host",
          label: "URL Host",
          type: :string,
          value: config.server.url_host,
          source: get_source("URL_HOST", "server.url_host", all_db_settings)
        }
      ],
      "Database" => [
        %{
          key: "database.path",
          label: "Database Path",
          type: :string,
          value: config.database.path,
          source: get_source("DATABASE_PATH", "database.path", all_db_settings)
        },
        %{
          key: "database.pool_size",
          label: "Pool Size",
          type: :integer,
          value: config.database.pool_size,
          source: get_source("POOL_SIZE", "database.pool_size", all_db_settings)
        }
      ],
      "Authentication" => [
        %{
          key: "auth.local_enabled",
          label: "Local Auth Enabled",
          type: :boolean,
          value: config.auth.local_enabled,
          source: get_source("LOCAL_AUTH_ENABLED", "auth.local_enabled", all_db_settings)
        },
        %{
          key: "auth.oidc_enabled",
          label: "OIDC Enabled",
          type: :boolean,
          value: config.auth.oidc_enabled,
          source: get_source("OIDC_ENABLED", "auth.oidc_enabled", all_db_settings)
        }
      ],
      "Media" => [
        %{
          key: "media.movies_path",
          label: "Movies Path",
          type: :string,
          value: config.media.movies_path,
          source: get_source("MOVIES_PATH", "media.movies_path", all_db_settings)
        },
        %{
          key: "media.tv_path",
          label: "TV Path",
          type: :string,
          value: config.media.tv_path,
          source: get_source("TV_PATH", "media.tv_path", all_db_settings)
        },
        %{
          key: "media.scan_interval_hours",
          label: "Scan Interval (hours)",
          type: :integer,
          value: config.media.scan_interval_hours,
          source:
            get_source("MEDIA_SCAN_INTERVAL_HOURS", "media.scan_interval_hours", all_db_settings)
        }
      ],
      "Metadata" => [
        %{
          key: "metadata.language",
          label: "Language",
          description:
            "Locale sent to TMDB/TVDB through the metadata relay (ISO 639-1 like \"de\" or BCP 47 like \"de-DE\"). Affects displayed titles, descriptions, and posters.",
          type: :string,
          value: metadata.language,
          placeholder: "en-US",
          source: get_source("METADATA_LANGUAGE", "metadata.language", all_db_settings)
        }
      ],
      "Downloads" => [
        %{
          key: "downloads.monitor_interval_minutes",
          label: "Monitor Interval (minutes)",
          type: :integer,
          value: config.downloads.monitor_interval_minutes,
          source:
            get_source(
              "DOWNLOAD_MONITOR_INTERVAL_MINUTES",
              "downloads.monitor_interval_minutes",
              all_db_settings
            )
        }
      ],
      "Crash Reporting" => [
        %{
          key: "crash_reporting.enabled",
          label: "Share Crashes with Developers",
          type: :boolean,
          value: get_crash_reporting_enabled(all_db_settings),
          # Unlike other settings where env wins, Mydia.CrashReporter.enabled?/0
          # gives the UI/DB setting priority over CRASH_REPORTING_ENABLED, so the
          # toggle must remain interactive even when the env var is set.
          editable: true,
          source: crash_reporting_source(all_db_settings)
        }
      ],
      "Feedback" => [
        %{
          key: "feedback.enabled",
          label: "Show Send feedback button",
          type: :boolean,
          value: Mydia.Feedback.enabled?(),
          editable: true,
          source: feedback_source(all_db_settings)
        }
      ],
      "Library" => [
        %{
          key: "library.auto_repair_enabled",
          label: "Auto-Repair Database Issues",
          description:
            "Automatically queue a library re-scan on startup when database issues (orphaned files) are detected",
          type: :boolean,
          value: get_library_auto_repair_enabled(all_db_settings),
          source:
            get_source("DATABASE_AUTO_REPAIR", "library.auto_repair_enabled", all_db_settings)
        },
        %{
          key: "library.auto_repair_threshold",
          label: "Auto-Repair Threshold",
          description: "Minimum number of issues required to trigger auto-repair",
          type: :integer,
          value: get_library_auto_repair_threshold(all_db_settings),
          source:
            get_source(
              "DATABASE_AUTO_REPAIR_THRESHOLD",
              "library.auto_repair_threshold",
              all_db_settings
            )
        }
      ],
      "Streaming" => [
        %{
          key: "streaming.embedded_enabled",
          label: "Embedded torrent streaming",
          description:
            "Allow the server to stream torrents from instant playback candidates. " <>
              "When off, startTorrentSession is rejected and any active sessions are stopped.",
          type: :boolean,
          value: streaming_embedded_enabled?(config, all_db_settings),
          source: get_source(nil, "streaming.embedded_enabled", all_db_settings)
        },
        %{
          key: "streaming.concurrent_cap",
          label: "Concurrent stream cap",
          description: "Maximum number of simultaneous torrent streams.",
          type: :integer,
          value: streaming_concurrent_cap(config, all_db_settings),
          source: get_source(nil, "streaming.concurrent_cap", all_db_settings)
        }
      ],
      "FlareSolverr" => [
        %{
          key: "flaresolverr.enabled",
          label: "Enabled",
          type: :boolean,
          value: flaresolverr.enabled,
          source: get_source("FLARESOLVERR_ENABLED", "flaresolverr.enabled", all_db_settings)
        },
        %{
          key: "flaresolverr.url",
          label: "FlareSolverr URL",
          type: :string,
          value: flaresolverr.url || "",
          source: get_source("FLARESOLVERR_URL", "flaresolverr.url", all_db_settings),
          placeholder: "http://flaresolverr:8191"
        },
        %{
          key: "flaresolverr.timeout",
          label: "Timeout (ms)",
          type: :integer,
          value: flaresolverr.timeout,
          source: get_source("FLARESOLVERR_TIMEOUT", "flaresolverr.timeout", all_db_settings)
        },
        %{
          key: "flaresolverr.max_timeout",
          label: "Max Timeout (ms)",
          type: :integer,
          value: flaresolverr.max_timeout,
          source:
            get_source("FLARESOLVERR_MAX_TIMEOUT", "flaresolverr.max_timeout", all_db_settings)
        }
      ]
    }
  end

  defp crash_reporting_source(all_db_settings) do
    cond do
      Map.has_key?(all_db_settings, "crash_reporting.enabled") -> :database
      System.get_env("CRASH_REPORTING_ENABLED") != nil -> :env
      true -> :default
    end
  end

  defp get_crash_reporting_enabled(all_db_settings) do
    case Map.get(all_db_settings, "crash_reporting.enabled") do
      nil ->
        case System.get_env("CRASH_REPORTING_ENABLED") do
          nil -> false
          value -> parse_boolean_value(value)
        end

      setting ->
        parse_boolean_value(setting.value)
    end
  end

  defp feedback_source(all_db_settings) do
    if Map.has_key?(all_db_settings, "feedback.enabled") do
      :database
    else
      :default
    end
  end

  defp get_library_auto_repair_enabled(all_db_settings) do
    case System.get_env("DATABASE_AUTO_REPAIR") do
      nil ->
        case Map.get(all_db_settings, "library.auto_repair_enabled") do
          nil ->
            Application.get_env(:mydia, :database_auto_repair, true)

          setting ->
            parse_boolean_value(setting.value)
        end

      value ->
        parse_boolean_value(value)
    end
  end

  defp get_library_auto_repair_threshold(all_db_settings) do
    case System.get_env("DATABASE_AUTO_REPAIR_THRESHOLD") do
      nil ->
        case Map.get(all_db_settings, "library.auto_repair_threshold") do
          nil ->
            Application.get_env(:mydia, :database_auto_repair_threshold, 10)

          setting ->
            case Integer.parse(setting.value) do
              {int, ""} -> int
              _ -> 10
            end
        end

      value ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> 10
        end
    end
  end

  # `"on"` is accepted because LiveView used to clobber phx-value-value with the
  # checkbox's default `value="on"` for this toggle, and existing rows may
  # still hold that string.
  defp parse_boolean_value(value) when is_boolean(value), do: value
  defp parse_boolean_value("true"), do: true
  defp parse_boolean_value("1"), do: true
  defp parse_boolean_value("yes"), do: true
  defp parse_boolean_value("on"), do: true
  defp parse_boolean_value(_), do: false

  defp get_source(env_var_name, key, all_db_settings) do
    cond do
      env_var_name != nil and System.get_env(env_var_name) != nil ->
        :env

      Map.has_key?(all_db_settings, key) ->
        :database

      true ->
        :default
    end
  end

  defp validate_config_setting(attrs) do
    types = %{
      key: :string,
      value: :string,
      category: :string
    }

    attrs_with_string_category =
      case Map.get(attrs, :category) do
        nil -> attrs
        category when is_atom(category) -> Map.put(attrs, :category, to_string(category))
        _category -> attrs
      end

    {%{}, types}
    |> Ecto.Changeset.cast(attrs_with_string_category, Map.keys(types))
    |> Ecto.Changeset.validate_required([:key, :category])
  end

  defp category_string_to_atom(category_string) do
    case category_string do
      "Server" -> :server
      "Database" -> :general
      "Authentication" -> :auth
      "Media" -> :media
      "Metadata" -> :metadata
      "Downloads" -> :downloads
      "Crash Reporting" -> :crash_reporting
      "Feedback" -> :feedback
      "Notifications" -> :notifications
      "FlareSolverr" -> :flaresolverr
      "Library" -> :library
      "Streaming" -> :streaming
      _ -> :general
    end
  end

  defp streaming_embedded_enabled?(config, all_db_settings) do
    case Map.get(all_db_settings, "streaming.embedded_enabled") do
      nil ->
        case config do
          %{streaming: %{embedded_enabled: value}} when is_boolean(value) -> value
          _ -> false
        end

      setting ->
        parse_boolean_value(setting.value)
    end
  end

  defp streaming_concurrent_cap(config, all_db_settings) do
    case Map.get(all_db_settings, "streaming.concurrent_cap") do
      nil ->
        case config do
          %{streaming: %{concurrent_cap: cap}} when is_integer(cap) -> cap
          _ -> 3
        end

      setting ->
        case Integer.parse(setting.value || "") do
          {int, ""} -> int
          _ -> 3
        end
    end
  end

  defp upsert_config_setting(attrs) do
    attrs_map = if is_struct(attrs), do: Map.from_struct(attrs), else: attrs
    key = Map.get(attrs_map, :key) || Map.get(attrs_map, "key")

    string_attrs = %{
      "key" => Map.get(attrs_map, :key),
      "value" => Map.get(attrs_map, :value),
      "category" => Map.get(attrs_map, :category),
      "updated_by_id" => Map.get(attrs_map, :updated_by_id)
    }

    case Settings.get_config_setting_by_key(key) do
      nil -> Settings.create_config_setting(string_attrs)
      existing -> Settings.update_config_setting(existing, string_attrs)
    end
  end
end
