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

  # A text or number input reports through `phx-blur`, which sends the
  # element's own value alongside its `phx-value-*` metadata — never the
  # `settings` map the clause below expects. Without this clause every
  # typed setting in this screen raised FunctionClauseError on edit, so the
  # database layer was reachable for toggles and selects but not for
  # anything you type, `streaming.max_transcode_height` included.
  @impl true
  def handle_event(
        "update_setting_form",
        %{"key" => key, "category" => category, "value" => value},
        socket
      ) do
    save_setting(socket, key, category, to_string(value))
  end

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

          Settings.upsert_config_setting(validated_data_with_user)
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
            setting -> to_string(!Settings.parse_setting_boolean(setting.value))
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

      case Settings.upsert_config_setting(validated_data_with_user) do
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

      case Settings.upsert_config_setting(validated_data_with_user) do
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

  # Validates, persists, and reloads a single key. Shared by the typed-input
  # path above; the toggle and select paths predate it and still inline the
  # same steps.
  defp save_setting(socket, key, category, value) do
    changeset =
      validate_config_setting(%{
        key: key,
        value: value,
        category: category_string_to_atom(category)
      })

    cond do
      unchanged?(socket, key, value) ->
        # `phx-blur` fires on every blur, including one that only tabbed
        # through. Writing then would insert a ConfigSetting row holding the
        # value the field was already showing, flipping the provenance badge
        # from Default or YAML to DB and permanently shadowing that key from
        # any later YAML or default change. The layered config is only
        # honest if the database layer holds values an operator actually
        # chose, so an unchanged field writes nothing at all.
        {:noreply, socket}

      changeset.valid? ->
        persist_setting(socket, changeset, key, category)

      true ->
        {:noreply, put_flash(socket, :error, "Invalid setting value")}
    end
  end

  # Compares against the value the screen is currently showing, which is the
  # *resolved* one across every layer — not just the database row. Comparing
  # against the row alone would still write a first row for a key whose
  # displayed value came from YAML or a schema default, which is the case
  # that matters.
  defp unchanged?(socket, key, value) do
    current =
      socket.assigns
      |> Map.get(:config_settings_with_sources, %{})
      |> Map.values()
      |> List.flatten()
      |> Enum.find(&(&1.key == key))

    case current do
      nil -> false
      setting -> to_string(value) == to_string(setting.value || "")
    end
  end

  defp persist_setting(socket, changeset, key, category) do
    attrs =
      changeset
      |> Ecto.Changeset.apply_changes()
      |> Map.put(:updated_by_id, socket.assigns.current_user.id)

    case Settings.upsert_config_setting(attrs) do
      {:ok, _setting} ->
        {:noreply,
         socket
         |> put_flash(:info, "Setting updated successfully")
         |> load_data()}

      {:error, error} ->
        MydiaLogger.log_error(:liveview, "Failed to update setting",
          error: error,
          error_details: inspect(error, pretty: true),
          operation: :update_setting,
          category: category,
          setting_key: key,
          user_id: socket.assigns.current_user.id
        )

        {:noreply,
         put_flash(socket, :error, MydiaLogger.user_error_message(:update_setting, error))}
    end
  end

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

    metadata = config.metadata || %Mydia.Config.Schema.Metadata{}
    streaming = config.streaming || %Mydia.Config.Schema.Streaming{}

    # Fetch all DB settings in one query to avoid N+1 per-key lookups
    all_db_settings = Settings.list_config_settings() |> Map.new(&{&1.key, &1})

    %{
      "Server" => [
        %{
          key: "server.port",
          label: "Port",
          type: :integer,
          value: config.server.port,
          source: Settings.config_source("PORT", "server.port", all_db_settings)
        },
        %{
          key: "server.host",
          label: "Host",
          type: :string,
          value: config.server.host,
          source: Settings.config_source("HOST", "server.host", all_db_settings)
        },
        %{
          key: "server.url_scheme",
          label: "URL Scheme",
          type: :string,
          value: config.server.url_scheme,
          source: Settings.config_source("URL_SCHEME", "server.url_scheme", all_db_settings)
        },
        %{
          key: "server.url_host",
          label: "URL Host",
          type: :string,
          value: config.server.url_host,
          source: Settings.config_source("URL_HOST", "server.url_host", all_db_settings)
        }
      ],
      "Database" => [
        %{
          key: "database.path",
          label: "Database Path",
          type: :string,
          value: config.database.path,
          source: Settings.config_source("DATABASE_PATH", "database.path", all_db_settings)
        },
        %{
          key: "database.pool_size",
          label: "Pool Size",
          type: :integer,
          value: config.database.pool_size,
          source: Settings.config_source("POOL_SIZE", "database.pool_size", all_db_settings)
        }
      ],
      "Authentication" => [
        %{
          key: "auth.local_enabled",
          label: "Local Auth Enabled",
          type: :boolean,
          value: config.auth.local_enabled,
          source:
            Settings.config_source("LOCAL_AUTH_ENABLED", "auth.local_enabled", all_db_settings)
        },
        %{
          key: "auth.oidc_enabled",
          label: "OIDC Enabled",
          type: :boolean,
          value: config.auth.oidc_enabled,
          source: Settings.config_source("OIDC_ENABLED", "auth.oidc_enabled", all_db_settings)
        }
      ],
      "Media" => [
        %{
          key: "media.movies_path",
          label: "Movies Path",
          type: :string,
          value: config.media.movies_path,
          source: Settings.config_source("MOVIES_PATH", "media.movies_path", all_db_settings)
        },
        %{
          key: "media.tv_path",
          label: "TV Path",
          type: :string,
          value: config.media.tv_path,
          source: Settings.config_source("TV_PATH", "media.tv_path", all_db_settings)
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
          source:
            Settings.config_source("METADATA_LANGUAGE", "metadata.language", all_db_settings)
        }
      ],
      "Downloads" => [
        %{
          key: "downloads.monitor_interval_minutes",
          label: "Monitor Interval (minutes)",
          type: :integer,
          value: config.downloads.monitor_interval_minutes,
          source:
            Settings.config_source(
              "DOWNLOAD_MONITOR_INTERVAL_MINUTES",
              "downloads.monitor_interval_minutes",
              all_db_settings
            )
        },
        %{
          key: "downloads.min_seeders",
          label: "Minimum Seeders (automatic search)",
          description:
            "Minimum seeders a result must report for automatic searches to consider it. " <>
              "This is a hard filter applied before ranking, so a torrent below it is " <>
              "removed rather than demoted. Manual searches have their own control, and " <>
              "Usenet results report no seeders at all and are exempt. 0, the default, " <>
              "filters nothing. Careful above 0: some indexers report 0 when they mean " <>
              "\"unknown\" rather than \"dead\", so a floor can silently empty their results.",
          type: :integer,
          value: config.downloads.min_seeders,
          placeholder: "0",
          source:
            Settings.config_source(
              "AUTO_SEARCH_MIN_SEEDERS",
              "downloads.min_seeders",
              all_db_settings
            )
        }
      ],
      "Streaming" => [
        %{
          key: "streaming.max_transcode_height",
          label: "Max Transcode Height",
          description:
            "Ceiling in pixels on the output height of any transcode, for example 720. " <>
              "Empty means no ceiling and a transcode keeps the source resolution, which " <>
              "a small server may not sustain in realtime for a 4K file. Never upscales, " <>
              "and never applies when the file is streamed without re-encoding.",
          type: :integer,
          value: streaming.max_transcode_height,
          placeholder: "no limit",
          source:
            Settings.config_source(
              "MAX_TRANSCODE_HEIGHT",
              "streaming.max_transcode_height",
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
            Settings.config_source(
              "DATABASE_AUTO_REPAIR",
              "library.auto_repair_enabled",
              all_db_settings
            )
        },
        %{
          key: "library.auto_repair_threshold",
          label: "Auto-Repair Threshold",
          description: "Minimum number of issues required to trigger auto-repair",
          type: :integer,
          value: get_library_auto_repair_threshold(all_db_settings),
          source:
            Settings.config_source(
              "DATABASE_AUTO_REPAIR_THRESHOLD",
              "library.auto_repair_threshold",
              all_db_settings
            )
        }
      ]
    }
  end

  # Deliberately NOT Settings.config_source/3: crash reporting is a privacy
  # toggle that inverts the global env > DB precedence. Mydia.CrashReporter.enabled?/0
  # gives the UI/DB setting priority over CRASH_REPORTING_ENABLED so the operator's
  # explicit opt-out always wins, so the source badge must report :database (not
  # :env) whenever a DB row exists. Keep this in sync with CrashReporter.enabled?/0.
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
          value -> Settings.parse_setting_boolean(value)
        end

      setting ->
        Settings.parse_setting_boolean(setting.value)
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
            Settings.parse_setting_boolean(setting.value)
        end

      value ->
        Settings.parse_setting_boolean(value)
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
      "Streaming" -> :streaming
      "Crash Reporting" -> :crash_reporting
      "Feedback" -> :feedback
      "Notifications" -> :notifications
      "Library" -> :library
      _ -> :general
    end
  end
end
