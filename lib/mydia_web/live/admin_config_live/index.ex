defmodule MydiaWeb.AdminConfigLive.Index do
  use MydiaWeb, :live_view
  alias Mydia.Settings
  alias Mydia.Settings.{QualityProfile, DownloadClientConfig, IndexerConfig, LibraryPath}
  alias Mydia.Downloads.ClientHealth
  alias Mydia.Indexers.Health, as: IndexerHealth

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Configuration Management")
     |> assign(:active_tab, "general")
     |> load_configuration_data()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    tab = params["tab"] || "general"

    {:noreply,
     socket
     |> assign(:active_tab, tab)
     |> maybe_setup_form(tab)}
  end

  @impl true
  def handle_event("change_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/config?tab=#{tab}")}
  end

  ## General Settings Events

  @impl true
  def handle_event(
        "update_setting_form",
        %{"category" => category, "settings" => settings},
        socket
      ) do
    # Parse the category
    parsed_category = parse_category(category)

    # Process each changed setting
    results =
      settings
      |> Enum.map(fn {key, value} ->
        attrs = %{
          key: key,
          value: value,
          category: parsed_category
        }

        upsert_config_setting(attrs)
      end)

    # Check if all updates succeeded
    if Enum.all?(results, fn result -> match?({:ok, _}, result) end) do
      {:noreply,
       socket
       |> put_flash(:info, "Settings updated successfully")
       |> load_configuration_data()}
    else
      {:noreply,
       socket
       |> put_flash(:error, "Failed to update some settings")}
    end
  end

  @impl true
  def handle_event(
        "toggle_setting",
        %{"key" => key, "value" => value, "category" => category},
        socket
      ) do
    # Handle boolean toggle
    parsed_category = parse_category(category)

    attrs = %{
      key: key,
      value: to_string(value),
      category: parsed_category
    }

    case upsert_config_setting(attrs) do
      {:ok, _setting} ->
        {:noreply,
         socket
         |> load_configuration_data()}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to update setting")}
    end
  end

  ## Quality Profile Events

  @impl true
  def handle_event("new_quality_profile", _params, socket) do
    changeset = Settings.change_quality_profile(%QualityProfile{})

    {:noreply,
     socket
     |> assign(:show_quality_profile_modal, true)
     |> assign(:quality_profile_form, to_form(changeset))
     |> assign(:quality_profile_mode, :new)}
  end

  @impl true
  def handle_event("edit_quality_profile", %{"id" => id}, socket) do
    profile = Settings.get_quality_profile!(id)
    changeset = Settings.change_quality_profile(profile)

    {:noreply,
     socket
     |> assign(:show_quality_profile_modal, true)
     |> assign(:quality_profile_form, to_form(changeset))
     |> assign(:quality_profile_mode, :edit)
     |> assign(:editing_quality_profile, profile)}
  end

  @impl true
  def handle_event("validate_quality_profile", %{"quality_profile" => params}, socket) do
    profile =
      case socket.assigns.quality_profile_mode do
        :new -> %QualityProfile{}
        :edit -> socket.assigns.editing_quality_profile
      end

    # Transform params to match schema
    transformed_params = transform_quality_profile_params(params)

    changeset =
      profile
      |> Settings.change_quality_profile(transformed_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :quality_profile_form, to_form(changeset))}
  end

  @impl true
  def handle_event("save_quality_profile", %{"quality_profile" => params}, socket) do
    # Transform params to match schema
    transformed_params = transform_quality_profile_params(params)

    result =
      case socket.assigns.quality_profile_mode do
        :new ->
          Settings.create_quality_profile(transformed_params)

        :edit ->
          Settings.update_quality_profile(
            socket.assigns.editing_quality_profile,
            transformed_params
          )
      end

    case result do
      {:ok, _profile} ->
        {:noreply,
         socket
         |> assign(:show_quality_profile_modal, false)
         |> put_flash(:info, "Quality profile saved successfully")
         |> load_configuration_data()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :quality_profile_form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("duplicate_quality_profile", %{"id" => id}, socket) do
    profile = Settings.get_quality_profile!(id)

    # Create a new profile with duplicated attributes
    duplicate_attrs = %{
      name: "#{profile.name} (Copy)",
      qualities: profile.qualities,
      upgrades_allowed: profile.upgrades_allowed,
      upgrade_until_quality: profile.upgrade_until_quality,
      rules: profile.rules
    }

    case Settings.create_quality_profile(duplicate_attrs) do
      {:ok, _new_profile} ->
        {:noreply,
         socket
         |> put_flash(:info, "Quality profile duplicated successfully")
         |> load_configuration_data()}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to duplicate quality profile")}
    end
  end

  @impl true
  def handle_event("delete_quality_profile", %{"id" => id}, socket) do
    profile = Settings.get_quality_profile!(id)

    case Settings.delete_quality_profile(profile) do
      {:ok, _profile} ->
        {:noreply,
         socket
         |> put_flash(:info, "Quality profile deleted successfully")
         |> load_configuration_data()}

      {:error, :profile_in_use} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Cannot delete quality profile - it is assigned to one or more media items. Please reassign those items first."
         )}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete quality profile")}
    end
  end

  @impl true
  def handle_event("close_quality_profile_modal", _params, socket) do
    {:noreply, assign(socket, :show_quality_profile_modal, false)}
  end

  ## Download Client Events

  @impl true
  def handle_event("new_download_client", _params, socket) do
    changeset = DownloadClientConfig.changeset(%DownloadClientConfig{}, %{})

    {:noreply,
     socket
     |> assign(:show_download_client_modal, true)
     |> assign(:download_client_form, to_form(changeset))
     |> assign(:download_client_mode, :new)}
  end

  @impl true
  def handle_event("edit_download_client", %{"id" => id}, socket) do
    client = Settings.get_download_client_config!(id)
    changeset = DownloadClientConfig.changeset(client, %{})

    {:noreply,
     socket
     |> assign(:show_download_client_modal, true)
     |> assign(:download_client_form, to_form(changeset))
     |> assign(:download_client_mode, :edit)
     |> assign(:editing_download_client, client)}
  end

  @impl true
  def handle_event("validate_download_client", %{"download_client_config" => params}, socket) do
    client =
      case socket.assigns.download_client_mode do
        :new -> %DownloadClientConfig{}
        :edit -> socket.assigns.editing_download_client
      end

    changeset =
      client
      |> DownloadClientConfig.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :download_client_form, to_form(changeset))}
  end

  @impl true
  def handle_event("save_download_client", %{"download_client_config" => params}, socket) do
    result =
      case socket.assigns.download_client_mode do
        :new ->
          Settings.create_download_client_config(params)

        :edit ->
          Settings.update_download_client_config(
            socket.assigns.editing_download_client,
            params
          )
      end

    case result do
      {:ok, _client} ->
        {:noreply,
         socket
         |> assign(:show_download_client_modal, false)
         |> put_flash(:info, "Download client saved successfully")
         |> load_configuration_data()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :download_client_form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("delete_download_client", %{"id" => id}, socket) do
    client = Settings.get_download_client_config!(id)

    case Settings.delete_download_client_config(client) do
      {:ok, _client} ->
        {:noreply,
         socket
         |> put_flash(:info, "Download client deleted successfully")
         |> load_configuration_data()}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete download client")}
    end
  end

  @impl true
  def handle_event("close_download_client_modal", _params, socket) do
    {:noreply, assign(socket, :show_download_client_modal, false)}
  end

  @impl true
  def handle_event("test_download_client", %{"id" => id}, socket) do
    client = Settings.get_download_client_config!(id)

    # Convert client config to map for adapter
    client_config = %{
      type: String.to_atom(client.type),
      host: client.host,
      port: client.port,
      username: client.username,
      password: client.password,
      use_ssl: client.use_ssl,
      options: %{
        timeout: 10_000,
        connect_timeout: 5_000
      }
    }

    # Get the adapter and test connection
    case test_client_connection(client_config) do
      {:ok, info} ->
        version_info =
          cond do
            Map.has_key?(info, :version) ->
              "Version: #{info.version}"

            Map.has_key?(info, :rpc_version) ->
              "RPC Version: #{info.rpc_version}"

            true ->
              "Connected"
          end

        {:noreply,
         socket
         |> put_flash(:info, "Connection successful! #{version_info}")}

      {:error, error} ->
        error_msg =
          case error do
            %{message: msg} -> msg
            _ -> "Connection failed: #{inspect(error)}"
          end

        {:noreply,
         socket
         |> put_flash(:error, "Connection failed: #{error_msg}")}
    end
  end

  ## Indexer Events

  @impl true
  def handle_event("new_indexer", _params, socket) do
    changeset = IndexerConfig.changeset(%IndexerConfig{}, %{})

    {:noreply,
     socket
     |> assign(:show_indexer_modal, true)
     |> assign(:indexer_form, to_form(changeset))
     |> assign(:indexer_mode, :new)}
  end

  @impl true
  def handle_event("edit_indexer", %{"id" => id}, socket) do
    indexer = Settings.get_indexer_config!(id)
    changeset = IndexerConfig.changeset(indexer, %{})

    {:noreply,
     socket
     |> assign(:show_indexer_modal, true)
     |> assign(:indexer_form, to_form(changeset))
     |> assign(:indexer_mode, :edit)
     |> assign(:editing_indexer, indexer)}
  end

  @impl true
  def handle_event("validate_indexer", %{"indexer_config" => params}, socket) do
    indexer =
      case socket.assigns.indexer_mode do
        :new -> %IndexerConfig{}
        :edit -> socket.assigns.editing_indexer
      end

    changeset =
      indexer
      |> IndexerConfig.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :indexer_form, to_form(changeset))}
  end

  @impl true
  def handle_event("save_indexer", %{"indexer_config" => params}, socket) do
    result =
      case socket.assigns.indexer_mode do
        :new ->
          Settings.create_indexer_config(params)

        :edit ->
          Settings.update_indexer_config(socket.assigns.editing_indexer, params)
      end

    case result do
      {:ok, _indexer} ->
        {:noreply,
         socket
         |> assign(:show_indexer_modal, false)
         |> put_flash(:info, "Indexer saved successfully")
         |> load_configuration_data()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :indexer_form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("delete_indexer", %{"id" => id}, socket) do
    indexer = Settings.get_indexer_config!(id)

    case Settings.delete_indexer_config(indexer) do
      {:ok, _indexer} ->
        {:noreply,
         socket
         |> put_flash(:info, "Indexer deleted successfully")
         |> load_configuration_data()}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete indexer")}
    end
  end

  @impl true
  def handle_event("close_indexer_modal", _params, socket) do
    {:noreply, assign(socket, :show_indexer_modal, false)}
  end

  @impl true
  def handle_event("test_indexer", %{"id" => id}, socket) do
    case IndexerHealth.check_health(id, force: true) do
      {:ok, %{status: :healthy} = health} ->
        details = Map.get(health, :details, %{})
        version = Map.get(details, :version, "unknown")

        {:noreply,
         socket
         |> put_flash(:info, "Indexer connection successful! Version: #{version}")
         |> load_configuration_data()}

      {:ok, %{status: :unhealthy, error: error}} ->
        {:noreply,
         socket
         |> put_flash(:error, "Indexer connection failed: #{error}")
         |> load_configuration_data()}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Indexer not found")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Health check failed: #{inspect(reason)}")
         |> load_configuration_data()}
    end
  end

  ## Library Path Events

  @impl true
  def handle_event("new_library_path", _params, socket) do
    changeset = LibraryPath.changeset(%LibraryPath{}, %{})

    {:noreply,
     socket
     |> assign(:show_library_path_modal, true)
     |> assign(:library_path_form, to_form(changeset))
     |> assign(:library_path_mode, :new)}
  end

  @impl true
  def handle_event("edit_library_path", %{"id" => id}, socket) do
    path = Settings.get_library_path!(id)
    changeset = LibraryPath.changeset(path, %{})

    {:noreply,
     socket
     |> assign(:show_library_path_modal, true)
     |> assign(:library_path_form, to_form(changeset))
     |> assign(:library_path_mode, :edit)
     |> assign(:editing_library_path, path)}
  end

  @impl true
  def handle_event("validate_library_path", %{"library_path" => params}, socket) do
    path =
      case socket.assigns.library_path_mode do
        :new -> %LibraryPath{}
        :edit -> socket.assigns.editing_library_path
      end

    changeset =
      path
      |> LibraryPath.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :library_path_form, to_form(changeset))}
  end

  @impl true
  def handle_event("save_library_path", %{"library_path" => params}, socket) do
    # Validate directory exists
    path = params["path"]

    case validate_directory(path) do
      :ok ->
        result =
          case socket.assigns.library_path_mode do
            :new ->
              Settings.create_library_path(params)

            :edit ->
              Settings.update_library_path(socket.assigns.editing_library_path, params)
          end

        case result do
          {:ok, _path} ->
            {:noreply,
             socket
             |> assign(:show_library_path_modal, false)
             |> put_flash(:info, "Library path saved successfully")
             |> load_configuration_data()}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, :library_path_form, to_form(changeset))}
        end

      {:error, reason} ->
        library_path =
          case socket.assigns.library_path_mode do
            :new -> %Mydia.Settings.LibraryPath{}
            :edit -> socket.assigns.editing_library_path
          end

        changeset =
          library_path
          |> Mydia.Settings.LibraryPath.changeset(params)
          |> Ecto.Changeset.add_error(:path, reason)

        {:noreply,
         socket
         |> assign(:library_path_form, to_form(changeset))
         |> put_flash(:error, "Invalid directory: #{reason}")}
    end
  end

  @impl true
  def handle_event("delete_library_path", %{"id" => id}, socket) do
    path = Settings.get_library_path!(id)

    case Settings.delete_library_path(path) do
      {:ok, _path} ->
        {:noreply,
         socket
         |> put_flash(:info, "Library path deleted successfully")
         |> load_configuration_data()}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete library path")}
    end
  end

  @impl true
  def handle_event("close_library_path_modal", _params, socket) do
    {:noreply, assign(socket, :show_library_path_modal, false)}
  end

  ## Private Functions

  defp test_client_connection(client_config) do
    alias Mydia.Downloads.Client.Registry

    with {:ok, adapter} <- Registry.get_adapter(client_config.type),
         {:ok, result} <- adapter.test_connection(client_config) do
      {:ok, result}
    else
      {:error, _} = error -> error
    end
  end

  defp validate_directory(nil), do: {:error, "path cannot be blank"}
  defp validate_directory(""), do: {:error, "path cannot be blank"}

  defp validate_directory(path) when is_binary(path) do
    cond do
      not File.exists?(path) ->
        {:error, "directory does not exist"}

      not File.dir?(path) ->
        {:error, "path is not a directory"}

      true ->
        # Check if directory is readable
        case File.ls(path) do
          {:ok, _} -> :ok
          {:error, :eacces} -> {:error, "directory is not accessible (permission denied)"}
          {:error, reason} -> {:error, "cannot read directory: #{reason}"}
        end
    end
  end

  defp load_configuration_data(socket) do
    download_clients = Settings.list_download_client_configs()
    client_health = get_client_health_status(download_clients)

    indexers = Settings.list_indexer_configs()
    indexer_health = get_indexer_health_status(indexers)

    socket
    |> assign(:config, Settings.get_runtime_config())
    |> assign(:config_settings_with_sources, get_all_settings_with_sources())
    |> assign(:quality_profiles, Settings.list_quality_profiles())
    |> assign(:download_clients, download_clients)
    |> assign(:client_health, client_health)
    |> assign(:indexers, indexers)
    |> assign(:indexer_health, indexer_health)
    |> assign(:library_paths, Settings.list_library_paths())
    |> assign(:show_quality_profile_modal, false)
    |> assign(:show_download_client_modal, false)
    |> assign(:show_indexer_modal, false)
    |> assign(:show_library_path_modal, false)
  end

  defp get_client_health_status(clients) do
    clients
    |> Enum.map(fn client ->
      case ClientHealth.check_health(client.id) do
        {:ok, health} -> {client.id, health}
        {:error, _} -> {client.id, %{status: :unknown, error: "Unable to check health"}}
      end
    end)
    |> Map.new()
  end

  defp get_indexer_health_status(indexers) do
    indexers
    |> Enum.map(fn indexer ->
      case IndexerHealth.check_health(indexer.id) do
        {:ok, health} ->
          # Add failure count to health status
          failure_count = IndexerHealth.get_failure_count(indexer.id)
          health_with_failures = Map.put(health, :consecutive_failures, failure_count)
          {indexer.id, health_with_failures}

        {:error, _} ->
          {indexer.id, %{status: :unknown, error: "Unable to check health"}}
      end
    end)
    |> Map.new()
  end

  defp maybe_setup_form(socket, _tab) do
    # Setup forms for the active tab if needed
    socket
  end

  defp get_all_settings_with_sources do
    config = Settings.get_runtime_config()

    # Group settings by category with their sources
    %{
      "Server" => [
        %{
          key: "server.port",
          label: "Port",
          value: config.server.port,
          source: get_source("PORT", "server.port")
        },
        %{
          key: "server.host",
          label: "Host",
          value: config.server.host,
          source: get_source("HOST", "server.host")
        },
        %{
          key: "server.url_scheme",
          label: "URL Scheme",
          value: config.server.url_scheme,
          source: get_source("URL_SCHEME", "server.url_scheme")
        },
        %{
          key: "server.url_host",
          label: "URL Host",
          value: config.server.url_host,
          source: get_source("URL_HOST", "server.url_host")
        }
      ],
      "Database" => [
        %{
          key: "database.path",
          label: "Database Path",
          value: config.database.path,
          source: get_source("DATABASE_PATH", "database.path")
        },
        %{
          key: "database.pool_size",
          label: "Pool Size",
          value: config.database.pool_size,
          source: get_source("POOL_SIZE", "database.pool_size")
        }
      ],
      "Authentication" => [
        %{
          key: "auth.local_enabled",
          label: "Local Auth Enabled",
          value: config.auth.local_enabled,
          source: get_source("LOCAL_AUTH_ENABLED", "auth.local_enabled")
        },
        %{
          key: "auth.oidc_enabled",
          label: "OIDC Enabled",
          value: config.auth.oidc_enabled,
          source: get_source("OIDC_ENABLED", "auth.oidc_enabled")
        }
      ],
      "Media" => [
        %{
          key: "media.movies_path",
          label: "Movies Path",
          value: config.media.movies_path,
          source: get_source("MOVIES_PATH", "media.movies_path")
        },
        %{
          key: "media.tv_path",
          label: "TV Path",
          value: config.media.tv_path,
          source: get_source("TV_PATH", "media.tv_path")
        },
        %{
          key: "media.scan_interval_hours",
          label: "Scan Interval (hours)",
          value: config.media.scan_interval_hours,
          source: get_source("MEDIA_SCAN_INTERVAL_HOURS", "media.scan_interval_hours")
        }
      ],
      "Downloads" => [
        %{
          key: "downloads.monitor_interval_minutes",
          label: "Monitor Interval (minutes)",
          value: config.downloads.monitor_interval_minutes,
          source:
            get_source("DOWNLOAD_MONITOR_INTERVAL_MINUTES", "downloads.monitor_interval_minutes")
        }
      ]
    }
  end

  defp get_source(env_var_name, key) do
    cond do
      # Check if set via environment variable
      System.get_env(env_var_name) ->
        :env

      # Check if set in database
      Settings.get_config_setting_by_key(key) ->
        :database

      # TODO: Check if set in YAML file when file config is implemented
      # For now, we'll assume it's default if not in ENV or DB
      true ->
        :default
    end
  end

  defp upsert_config_setting(attrs) do
    case Settings.get_config_setting_by_key(attrs.key) do
      nil ->
        Settings.create_config_setting(attrs)

      existing ->
        Settings.update_config_setting(existing, attrs)
    end
  end

  defp parse_category(category_string) do
    case String.downcase(category_string) do
      "server" -> :server
      "database" -> :database
      "authentication" -> :auth
      "media" -> :media
      "downloads" -> :downloads
      _ -> :general
    end
  end

  defp source_badge_class(:env), do: "badge-primary"
  defp source_badge_class(:database), do: "badge-info"
  defp source_badge_class(:file), do: "badge-warning"
  defp source_badge_class(:default), do: "badge-ghost"

  defp source_label(:env), do: "ENV"
  defp source_label(:database), do: "DB"
  defp source_label(:file), do: "FILE"
  defp source_label(:default), do: "DEFAULT"

  defp source_description(:env),
    do: "Set via environment variable (read-only in UI)"

  defp source_description(:database), do: "Overridden via database/UI"
  defp source_description(:file), do: "Set in config.yml file"
  defp source_description(:default), do: "Using default value"

  defp health_status_badge_class(:healthy), do: "badge-success"
  defp health_status_badge_class(:unhealthy), do: "badge-error"
  defp health_status_badge_class(:unknown), do: "badge-ghost"

  defp health_status_icon(:healthy), do: "hero-check-circle"
  defp health_status_icon(:unhealthy), do: "hero-x-circle"
  defp health_status_icon(:unknown), do: "hero-question-mark-circle"

  defp health_status_label(:healthy), do: "Healthy"
  defp health_status_label(:unhealthy), do: "Unhealthy"
  defp health_status_label(:unknown), do: "Unknown"

  # Transforms quality profile form params to match the schema structure
  defp transform_quality_profile_params(params) do
    # Extract rules fields from params
    rules = %{}

    rules =
      if params["rules"] do
        # Parse min_size_mb
        rules =
          case params["rules"]["min_size_mb"] do
            "" -> rules
            nil -> rules
            val when is_binary(val) -> Map.put(rules, "min_size_mb", String.to_integer(val))
            val when is_integer(val) -> Map.put(rules, "min_size_mb", val)
            _ -> rules
          end

        # Parse max_size_mb
        rules =
          case params["rules"]["max_size_mb"] do
            "" -> rules
            nil -> rules
            val when is_binary(val) -> Map.put(rules, "max_size_mb", String.to_integer(val))
            val when is_integer(val) -> Map.put(rules, "max_size_mb", val)
            _ -> rules
          end

        # Parse preferred_sources (comma-separated string to array)
        rules =
          case params["rules"]["preferred_sources"] do
            "" ->
              rules

            nil ->
              rules

            val when is_binary(val) ->
              sources =
                val
                |> String.split(",")
                |> Enum.map(&String.trim/1)
                |> Enum.reject(&(&1 == ""))

              Map.put(rules, "preferred_sources", sources)

            val when is_list(val) ->
              Map.put(rules, "preferred_sources", val)

            _ ->
              rules
          end

        # Add description
        rules =
          case params["rules"]["description"] do
            "" -> rules
            nil -> rules
            val -> Map.put(rules, "description", val)
          end

        rules
      else
        rules
      end

    # Handle qualities array - if empty or nil, set to empty list to satisfy validation
    qualities =
      case params["qualities"] do
        nil -> []
        [] -> []
        list when is_list(list) -> list
        _ -> []
      end

    # Build the final params map
    %{
      "name" => params["name"],
      "qualities" => qualities,
      "upgrades_allowed" =>
        params["upgrades_allowed"] == "true" || params["upgrades_allowed"] == true,
      "upgrade_until_quality" => params["upgrade_until_quality"],
      "rules" => rules
    }
  end
end
