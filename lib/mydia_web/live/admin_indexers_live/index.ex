defmodule MydiaWeb.AdminIndexersLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.Settings
  alias Mydia.Settings.IndexerConfig
  alias Mydia.Indexers
  alias Mydia.Indexers.Health, as: IndexerHealth
  alias Mydia.Indexers.CardigannFeatureFlags
  alias Mydia.Indexers.FlareSolverr

  require Logger
  alias Mydia.Logger, as: MydiaLogger

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Configuration - Indexers")
     |> assign(:active_tab, :indexers)
     |> assign(:cardigann_enabled, CardigannFeatureFlags.enabled?())
     |> assign(:flaresolverr_status, %{configured: false, status: :loading})
     |> assign(:flaresolverr_modal_open, false)
     |> assign(:flaresolverr_sources, %{})
     |> assign(:flaresolverr_form, to_form(flaresolverr_changeset(%{}), as: :flaresolverr))
     |> init_library_assigns()
     |> load_data()
     |> maybe_load_flaresolverr_status()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  ## Handle info callbacks

  @impl true
  def handle_info(:reload_library_indexers, socket) do
    {:noreply, reload_library_indexers(socket)}
  end

  @impl true
  def handle_info({:sync_complete, result}, socket) do
    socket =
      case result do
        {:ok, stats} ->
          socket
          |> assign(:library_syncing, false)
          |> put_flash(
            :info,
            "Sync completed: #{stats.created} created, #{stats.updated} updated, #{stats.failed} failed"
          )
          |> load_library_definitions()

        {:error, reason} ->
          Logger.error("[IndexerLibrary] Sync failed: #{inspect(reason)}")

          socket
          |> assign(:library_syncing, false)
          |> put_flash(:error, "Sync failed: #{format_sync_error(reason)}")
      end

    {:noreply, reload_library_indexers(socket)}
  end

  @impl true
  def handle_info({:library_config_test_complete, result}, socket) do
    test_result =
      case result do
        {:ok, test_result} ->
          test_result

        {:error, reason} ->
          %{
            success: false,
            message: "Test failed",
            error: inspect(reason),
            response_time_ms: nil
          }
      end

    {:noreply,
     socket
     |> assign(:library_config_testing, false)
     |> assign(:library_config_test_result, test_result)}
  end

  @impl true
  def handle_info({:flaresolverr_status, status}, socket) do
    {:noreply, assign(socket, :flaresolverr_status, status)}
  end

  ## Indexer Events

  @impl true
  def handle_event("new_indexer", _params, socket) do
    changeset = IndexerConfig.changeset(%IndexerConfig{}, %{})

    {:noreply,
     socket
     |> assign(:show_indexer_modal, true)
     |> assign(:indexer_form, to_form(changeset))
     |> assign(:indexer_mode, :new)
     |> assign(:testing_indexer_connection, false)
     |> assign(:available_env_indexers, Settings.list_available_env_indexers())
     |> init_prowlarr_indexer_assigns([])
     |> maybe_auto_fetch_prowlarr_indexers(changeset)}
  end

  @impl true
  def handle_event("edit_indexer", %{"id" => id}, socket) do
    indexer = Settings.get_indexer_config!(id)
    available_env_indexers = Settings.list_available_env_indexers()
    existing_indexer_ids = indexer.indexer_ids || []

    if Settings.runtime_config?(indexer) do
      matching_env =
        Enum.find(available_env_indexers, fn env ->
          env.base_url == indexer.base_url
        end)

      attrs = %{
        "name" => indexer.name,
        "type" => to_string(indexer.type),
        "enabled" => indexer.enabled,
        "priority" => indexer.priority,
        "indexer_ids" => indexer.indexer_ids,
        "categories" => indexer.categories,
        "rate_limit" => indexer.rate_limit,
        "env_name" => if(matching_env, do: matching_env.env_name, else: nil),
        "base_url" => if(matching_env, do: nil, else: indexer.base_url),
        "api_key" => if(matching_env, do: nil, else: indexer.api_key)
      }

      changeset = IndexerConfig.changeset(%IndexerConfig{}, attrs)

      {:noreply,
       socket
       |> assign(:show_indexer_modal, true)
       |> assign(:indexer_form, to_form(changeset))
       |> assign(:indexer_mode, :new)
       |> assign(:testing_indexer_connection, false)
       |> assign(:available_env_indexers, available_env_indexers)
       |> init_prowlarr_indexer_assigns(existing_indexer_ids)
       |> maybe_auto_fetch_prowlarr_indexers(changeset)
       |> put_flash(:info, "Converting runtime indexer to database-managed configuration")}
    else
      changeset = IndexerConfig.changeset(indexer, %{})

      {:noreply,
       socket
       |> assign(:show_indexer_modal, true)
       |> assign(:indexer_form, to_form(changeset))
       |> assign(:indexer_mode, :edit)
       |> assign(:editing_indexer, indexer)
       |> assign(:testing_indexer_connection, false)
       |> assign(:available_env_indexers, available_env_indexers)
       |> init_prowlarr_indexer_assigns(existing_indexer_ids)
       |> maybe_auto_fetch_prowlarr_indexers(changeset)}
    end
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
    params = merge_prowlarr_indexer_ids(params, socket.assigns)

    result =
      case socket.assigns.indexer_mode do
        :new -> Settings.create_indexer_config(params)
        :edit -> Settings.update_indexer_config(socket.assigns.editing_indexer, params)
      end

    case result do
      {:ok, _indexer} ->
        {:noreply,
         socket
         |> assign(:show_indexer_modal, false)
         |> put_flash(:info, "Indexer saved successfully")
         |> load_data()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :indexer_form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("delete_indexer", %{"id" => id}, socket) do
    indexer = Settings.get_indexer_config!(id)

    if Settings.runtime_config?(indexer) do
      {:noreply,
       socket
       |> put_flash(
         :error,
         "Cannot delete runtime-configured indexer. This indexer is configured via environment variables and is read-only in the UI."
       )}
    else
      case Settings.delete_indexer_config(indexer) do
        {:ok, _indexer} ->
          {:noreply,
           socket
           |> put_flash(:info, "Indexer deleted successfully")
           |> load_data()}

        {:error, error} ->
          MydiaLogger.log_error(:liveview, "Failed to delete indexer",
            error: error,
            operation: :delete_indexer,
            indexer_id: id,
            indexer_name: indexer.name,
            user_id: socket.assigns.current_user.id
          )

          error_msg = MydiaLogger.user_error_message(:delete_indexer, error)
          {:noreply, put_flash(socket, :error, error_msg)}
      end
    end
  end

  @impl true
  def handle_event("close_indexer_modal", _params, socket) do
    {:noreply, assign(socket, :show_indexer_modal, false)}
  end

  @impl true
  def handle_event("fetch_prowlarr_indexers", _params, socket) do
    changeset = socket.assigns.indexer_form.source
    params = Ecto.Changeset.apply_changes(changeset)
    env_name = params.env_name

    {base_url, api_key} =
      if env_name && env_name != "" do
        {System.get_env("#{env_name}_BASE_URL"), System.get_env("#{env_name}_API_KEY")}
      else
        {params.base_url, params.api_key}
      end

    if is_nil(base_url) or base_url == "" or is_nil(api_key) or api_key == "" do
      {:noreply,
       assign(
         socket,
         :prowlarr_indexers_error,
         "Base URL and API Key are required to fetch indexers"
       )}
    else
      socket = assign(socket, :fetching_prowlarr_indexers, true)
      config = %{base_url: base_url, api_key: api_key}

      case Indexers.list_prowlarr_indexers(config) do
        {:ok, indexers} ->
          {:noreply,
           socket
           |> assign(:prowlarr_indexers, indexers)
           |> assign(:fetching_prowlarr_indexers, false)
           |> assign(:prowlarr_indexers_error, nil)}

        {:error, error} ->
          error_msg =
            case error do
              %{message: msg} -> msg
              msg when is_binary(msg) -> msg
              _ -> "Failed to fetch indexers"
            end

          {:noreply,
           socket
           |> assign(:prowlarr_indexers, nil)
           |> assign(:fetching_prowlarr_indexers, false)
           |> assign(:prowlarr_indexers_error, error_msg)}
      end
    end
  end

  @impl true
  def handle_event("toggle_prowlarr_indexer", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    selected = socket.assigns.selected_prowlarr_indexer_ids

    updated =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, :selected_prowlarr_indexer_ids, updated)}
  end

  @impl true
  def handle_event("select_all_prowlarr_indexers", _params, socket) do
    indexers = socket.assigns.prowlarr_indexers || []

    all_enabled_ids =
      indexers
      |> Enum.filter(& &1.enabled)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    {:noreply, assign(socket, :selected_prowlarr_indexer_ids, all_enabled_ids)}
  end

  @impl true
  def handle_event("deselect_all_prowlarr_indexers", _params, socket) do
    {:noreply, assign(socket, :selected_prowlarr_indexer_ids, MapSet.new())}
  end

  @impl true
  def handle_event("show_indexer_library", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_indexer_library_modal, true)
     |> load_library_definitions()}
  end

  @impl true
  def handle_event("close_indexer_library", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_indexer_library_modal, false)
     |> init_library_assigns()}
  end

  @impl true
  def handle_event("test_indexer_connection", _params, socket) do
    changeset = socket.assigns.indexer_form.source
    params = Ecto.Changeset.apply_changes(changeset)

    type =
      case params.type do
        type when is_atom(type) -> type
        type when is_binary(type) -> String.to_existing_atom(type)
      end

    test_config = %{type: type, base_url: params.base_url, api_key: params.api_key}

    case Mydia.Indexers.test_connection(test_config) do
      {:ok, info} ->
        version = Map.get(info, :version, "unknown")

        {:noreply,
         socket
         |> assign(:testing_indexer_connection, false)
         |> put_flash(:info, "Connection successful! Version: #{version}")}

      {:error, error} ->
        error_msg =
          case error do
            msg when is_binary(msg) -> msg
            %{message: msg} -> msg
            _ -> MydiaLogger.extract_error_message(error)
          end

        {:noreply,
         socket
         |> assign(:testing_indexer_connection, false)
         |> put_flash(:error, "Connection failed: #{error_msg}")}
    end
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
         |> load_data()}

      {:ok, %{status: :unhealthy, error: error}} ->
        MydiaLogger.log_warning(:liveview, "Indexer health check returned unhealthy status",
          operation: :test_indexer,
          indexer_id: id,
          error: error,
          user_id: socket.assigns.current_user.id
        )

        {:noreply,
         socket
         |> put_flash(:error, "Indexer connection failed: #{error}")
         |> load_data()}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Indexer not found")}

      {:error, reason} ->
        MydiaLogger.log_error(:liveview, "Indexer health check failed",
          error: reason,
          operation: :test_indexer,
          indexer_id: id,
          user_id: socket.assigns.current_user.id
        )

        error_msg = MydiaLogger.extract_error_message(reason)

        {:noreply,
         socket
         |> put_flash(:error, "Health check failed: #{error_msg}")
         |> load_data()}
    end
  end

  @impl true
  def handle_event("test_library_indexer", %{"id" => id}, socket) do
    case Indexers.test_cardigann_connection(id) do
      {:ok, result} ->
        {flash_type, flash_message} = library_test_flash(result)
        {:noreply, socket |> put_flash(flash_type, flash_message) |> load_data()}

      {:error, reason} ->
        MydiaLogger.log_error(:liveview, "Failed to test library indexer connection",
          error: reason,
          operation: :test_library_indexer,
          definition_id: id,
          user_id: socket.assigns.current_user.id
        )

        {:noreply, put_flash(socket, :error, "Failed to test connection: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("toggle_library_flaresolverr", %{"id" => id}, socket) do
    definition = Indexers.get_cardigann_definition!(id)
    new_enabled = !definition.flaresolverr_enabled

    case Indexers.update_flaresolverr_settings(definition, %{flaresolverr_enabled: new_enabled}) do
      {:ok, updated_definition} ->
        action = if updated_definition.flaresolverr_enabled, do: "enabled", else: "disabled"

        {:noreply,
         socket
         |> put_flash(:info, "FlareSolverr #{action} for #{definition.name}")
         |> load_data()}

      {:error, changeset} ->
        MydiaLogger.log_error(:liveview, "Failed to toggle FlareSolverr",
          error: changeset,
          operation: :toggle_library_flaresolverr,
          definition_id: id,
          user_id: socket.assigns.current_user.id
        )

        error_msg = MydiaLogger.user_error_message(:toggle_library_flaresolverr, changeset)
        {:noreply, put_flash(socket, :error, error_msg)}
    end
  end

  @impl true
  def handle_event("toggle_library_indexer", %{"id" => id}, socket) do
    definition = Indexers.get_cardigann_definition!(id)

    result =
      if definition.enabled,
        do: Indexers.disable_cardigann_definition(definition),
        else: Indexers.enable_cardigann_definition(definition)

    case result do
      {:ok, updated_definition} ->
        socket =
          if updated_definition.enabled do
            socket
            |> put_flash(:info, "#{definition.name} enabled")
            |> assign(:recently_disabled_indexer, nil)
          else
            assign(socket, :recently_disabled_indexer, updated_definition)
          end

        {:noreply, load_data(socket)}

      {:error, changeset} ->
        MydiaLogger.log_error(:liveview, "Failed to toggle library indexer",
          error: changeset,
          operation: :toggle_library_indexer,
          definition_id: id,
          user_id: socket.assigns.current_user.id
        )

        error_msg = MydiaLogger.user_error_message(:toggle_library_indexer, changeset)
        {:noreply, put_flash(socket, :error, error_msg)}
    end
  end

  @impl true
  def handle_event("undo_disable_library_indexer", _params, socket) do
    case socket.assigns.recently_disabled_indexer do
      nil ->
        {:noreply, socket}

      definition ->
        case Indexers.enable_cardigann_definition(definition) do
          {:ok, _updated} ->
            {:noreply,
             socket
             |> assign(:recently_disabled_indexer, nil)
             |> put_flash(:info, "#{definition.name} re-enabled")
             |> load_data()}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to re-enable indexer")}
        end
    end
  end

  @impl true
  def handle_event("dismiss_undo_banner", _params, socket) do
    {:noreply, assign(socket, :recently_disabled_indexer, nil)}
  end

  @impl true
  def handle_event("configure_library_indexer", %{"id" => id}, socket) do
    alias Mydia.Indexers.CardigannParser

    definition = Indexers.get_cardigann_definition!(id)

    settings =
      case CardigannParser.parse_definition(definition.definition) do
        {:ok, parsed} -> parsed.settings || []
        {:error, _} -> []
      end

    {:noreply,
     socket
     |> assign(:show_library_config_modal, true)
     |> assign(:configuring_library_indexer, definition)
     |> assign(:library_indexer_settings, settings)}
  end

  @impl true
  def handle_event("close_library_config_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_library_config_modal, false)
     |> assign(:configuring_library_indexer, nil)
     |> assign(:library_indexer_settings, [])
     |> assign(:library_config_testing, false)
     |> assign(:library_config_test_result, nil)}
  end

  @impl true
  def handle_event(
        "save_library_indexer_config",
        %{"config" => config_params, "action" => "test"},
        socket
      ) do
    definition = socket.assigns.configuring_library_indexer

    case Indexers.configure_cardigann_definition(definition, config_params) do
      {:ok, updated_definition} ->
        parent = self()
        definition_id = updated_definition.id

        Task.start(fn ->
          result = Indexers.test_cardigann_connection(definition_id)
          send(parent, {:library_config_test_complete, result})
        end)

        {:noreply,
         socket
         |> assign(:library_config_testing, true)
         |> assign(:library_config_test_result, nil)
         |> assign(:configuring_library_indexer, updated_definition)}

      {:error, changeset} ->
        MydiaLogger.log_error(:liveview, "Failed to save config before test",
          error: changeset,
          operation: :configure_library_indexer,
          definition_id: definition.id,
          user_id: socket.assigns.current_user.id
        )

        error_msg = MydiaLogger.user_error_message(:configure_library_indexer, changeset)
        {:noreply, put_flash(socket, :error, error_msg)}
    end
  end

  @impl true
  def handle_event("save_library_indexer_config", %{"config" => config_params}, socket) do
    definition = socket.assigns.configuring_library_indexer

    case Indexers.configure_cardigann_definition(definition, config_params) do
      {:ok, _updated_definition} ->
        {:noreply,
         socket
         |> assign(:show_library_config_modal, false)
         |> assign(:configuring_library_indexer, nil)
         |> assign(:library_indexer_settings, [])
         |> assign(:library_config_testing, false)
         |> assign(:library_config_test_result, nil)
         |> put_flash(:info, "Configuration saved for #{definition.name}")
         |> load_data()}

      {:error, changeset} ->
        MydiaLogger.log_error(:liveview, "Failed to configure library indexer",
          error: changeset,
          operation: :configure_library_indexer,
          definition_id: definition.id,
          user_id: socket.assigns.current_user.id
        )

        error_msg = MydiaLogger.user_error_message(:configure_library_indexer, changeset)
        {:noreply, put_flash(socket, :error, error_msg)}
    end
  end

  @impl true
  def handle_event("test_flaresolverr", _params, socket) do
    case FlareSolverr.health_check() do
      {:ok, info} ->
        version = info[:version] || "unknown"
        sessions = length(info[:sessions] || [])

        {:noreply,
         socket
         |> put_flash(
           :info,
           "FlareSolverr connection successful! Version: #{version}, Active sessions: #{sessions}"
         )
         |> assign(:flaresolverr_status, FlareSolverr.status())}

      {:error, :disabled} ->
        {:noreply,
         put_flash(socket, :error, "FlareSolverr is disabled. Enable it in configuration.")}

      {:error, :not_configured} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "FlareSolverr is not configured. Set FLARESOLVERR_URL in environment."
         )}

      {:error, {:connection_error, reason}} ->
        {:noreply, put_flash(socket, :error, "FlareSolverr connection failed: #{reason}")}

      {:error, reason} ->
        MydiaLogger.log_error(:liveview, "FlareSolverr health check failed",
          error: reason,
          operation: :test_flaresolverr,
          user_id: socket.assigns.current_user.id
        )

        {:noreply, put_flash(socket, :error, "FlareSolverr test failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("edit_flaresolverr", _params, socket) do
    {values, sources} = flaresolverr_values_and_sources()

    params = %{
      "enabled" => values.enabled,
      "url" => values.url,
      "timeout" => values.timeout,
      "max_timeout" => values.max_timeout
    }

    {:noreply,
     socket
     |> assign(:flaresolverr_modal_open, true)
     |> assign(:flaresolverr_sources, sources)
     |> assign(
       :flaresolverr_form,
       to_form(flaresolverr_changeset(params, sources), as: :flaresolverr)
     )}
  end

  @impl true
  def handle_event("validate_flaresolverr", %{"flaresolverr" => params}, socket) do
    changeset =
      params
      |> flaresolverr_changeset(socket.assigns.flaresolverr_sources)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :flaresolverr_form, to_form(changeset, as: :flaresolverr))}
  end

  @impl true
  def handle_event("save_flaresolverr", %{"flaresolverr" => params}, socket) do
    sources = socket.assigns.flaresolverr_sources

    case Ecto.Changeset.apply_action(flaresolverr_changeset(params, sources), :insert) do
      {:ok, data} ->
        case persist_flaresolverr(data, sources, socket.assigns.current_user.id) do
          :ok ->
            # Reload first so the freshly-saved values are live before load_data and
            # the status probe read the cached runtime config.
            reload_result = reload_runtime_config(socket)

            socket =
              socket
              |> assign(:flaresolverr_modal_open, false)
              |> load_data()
              |> maybe_load_flaresolverr_status()

            {:noreply, flash_flaresolverr_save(socket, reload_result)}

          {:error, changeset} ->
            MydiaLogger.log_error(:liveview, "Failed to persist FlareSolverr settings",
              error: changeset,
              operation: :save_flaresolverr,
              user_id: socket.assigns.current_user.id
            )

            {:noreply,
             socket
             |> assign(:flaresolverr_form, to_form(changeset, as: :flaresolverr))
             |> put_flash(:error, "Failed to save FlareSolverr settings")}
        end

      {:error, changeset} ->
        {:noreply, assign(socket, :flaresolverr_form, to_form(changeset, as: :flaresolverr))}
    end
  end

  @impl true
  def handle_event("close_flaresolverr_modal", _params, socket) do
    {:noreply, assign(socket, :flaresolverr_modal_open, false)}
  end

  ## Indexer Library Events (flattened from IndexerLibraryComponent)

  @impl true
  def handle_event("library_filter", params, socket) do
    {:noreply,
     socket
     |> assign(:library_filter_type, params["type"] || socket.assigns.library_filter_type)
     |> assign(
       :library_filter_language,
       params["language"] || socket.assigns.library_filter_language
     )
     |> assign(
       :library_filter_enabled,
       params["enabled"] || socket.assigns.library_filter_enabled
     )
     |> load_library_definitions()}
  end

  @impl true
  def handle_event("library_search", %{"search" => %{"query" => query}}, socket) do
    {:noreply,
     socket
     |> assign(:library_search_query, query)
     |> load_library_definitions()}
  end

  @impl true
  def handle_event("library_toggle_indexer", %{"id" => id}, socket) do
    definition = Indexers.get_cardigann_definition!(id)

    result =
      if definition.enabled do
        Indexers.disable_cardigann_definition(definition)
      else
        Indexers.enable_cardigann_definition(definition)
      end

    case result do
      {:ok, _updated_definition} ->
        {:noreply,
         socket
         |> load_library_definitions()
         |> reload_library_indexers()}

      {:error, changeset} ->
        MydiaLogger.log_error(:liveview, "Failed to toggle indexer",
          error: changeset,
          operation: :toggle_library_indexer,
          definition_id: id,
          user_id: socket.assigns.current_user.id
        )

        error_msg = MydiaLogger.user_error_message(:toggle_library_indexer, changeset)
        {:noreply, put_flash(socket, :error, error_msg)}
    end
  end

  @impl true
  def handle_event("library_sync_definitions", _params, socket) do
    parent = self()

    Task.start(fn ->
      result = Mydia.Indexers.DefinitionSync.sync_from_github()
      send(parent, {:sync_complete, result})
    end)

    {:noreply,
     socket
     |> assign(:library_syncing, true)
     |> put_flash(:info, "Sync started - this may take a few minutes...")}
  end

  @impl true
  def handle_event("library_configure_indexer", %{"id" => id}, socket) do
    definition = Indexers.get_cardigann_definition!(id)
    config = definition.config || %{}

    config_form =
      to_form(%{
        "username" => config["username"] || "",
        "password" => config["password"] || ""
      })

    {:noreply,
     socket
     |> assign(:library_configuring_definition, definition)
     |> assign(:library_config_form, config_form)}
  end

  @impl true
  def handle_event("library_close_config", _params, socket) do
    {:noreply,
     socket
     |> assign(:library_configuring_definition, nil)
     |> assign(:library_config_form, nil)}
  end

  @impl true
  def handle_event(
        "library_save_config",
        %{"definition_id" => id, "config" => config_params},
        socket
      ) do
    definition = Indexers.get_cardigann_definition!(id)

    case Indexers.configure_cardigann_definition(definition, config_params) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> assign(:library_configuring_definition, nil)
         |> assign(:library_config_form, nil)
         |> put_flash(:info, "Configuration saved successfully")
         |> load_library_definitions()}

      {:error, changeset} ->
        MydiaLogger.log_error(:liveview, "Failed to save indexer config",
          error: changeset,
          operation: :save_indexer_config,
          definition_id: id,
          user_id: socket.assigns.current_user.id
        )

        error_msg = MydiaLogger.user_error_message(:save_indexer_config, changeset)
        {:noreply, put_flash(socket, :error, error_msg)}
    end
  end

  ## Private Helpers

  defp load_data(socket) do
    indexers = Settings.list_indexer_configs()
    indexer_health = get_indexer_health_status(indexers)
    cardigann_enabled = CardigannFeatureFlags.enabled?()

    library_indexers =
      if cardigann_enabled,
        do: Indexers.list_cardigann_definitions(enabled: true),
        else: []

    library_indexer_stats =
      if cardigann_enabled,
        do: Indexers.count_cardigann_definitions(),
        else: %{total: 0, enabled: 0, disabled: 0}

    socket
    |> assign(:indexers, indexers)
    |> assign(:indexer_health, indexer_health)
    |> assign(:library_indexers, library_indexers)
    |> assign(:library_indexer_stats, library_indexer_stats)
    |> assign(:show_indexer_modal, false)
    |> assign(:show_indexer_library_modal, false)
    |> assign(:show_library_config_modal, false)
    |> assign(:configuring_library_indexer, nil)
    |> assign(:library_indexer_settings, [])
    |> assign(:library_config_testing, false)
    |> assign(:library_config_test_result, nil)
    |> assign_new(:recently_disabled_indexer, fn -> nil end)
    |> assign_flaresolverr()
  end

  defp reload_library_indexers(socket) do
    cardigann_enabled = CardigannFeatureFlags.enabled?()

    library_indexers =
      if cardigann_enabled,
        do: Indexers.list_cardigann_definitions(enabled: true),
        else: []

    library_indexer_stats =
      if cardigann_enabled,
        do: Indexers.count_cardigann_definitions(),
        else: %{total: 0, enabled: 0, disabled: 0}

    socket
    |> assign(:library_indexers, library_indexers)
    |> assign(:library_indexer_stats, library_indexer_stats)
  end

  defp get_indexer_health_status(indexers) do
    indexers
    |> Task.async_stream(
      fn indexer ->
        case IndexerHealth.check_health(indexer.id) do
          {:ok, health} -> {indexer.id, health}
          {:error, _} -> {indexer.id, %{status: :unknown, error: "Unable to check health"}}
        end
      end,
      timeout: :infinity,
      max_concurrency: 10
    )
    |> Enum.map(fn {:ok, result} -> result end)
    |> Map.new()
  end

  defp maybe_load_flaresolverr_status(socket) do
    if connected?(socket) do
      parent = self()

      Task.start(fn ->
        # Always send a status, even if the probe crashes, so the row never gets
        # stuck on the :loading ("Checking…") state with no recovery path.
        status =
          try do
            FlareSolverr.status()
          rescue
            error ->
              %{
                configured: false,
                status: :unhealthy,
                error: {:probe_failed, Exception.message(error)}
              }
          end

        send(parent, {:flaresolverr_status, status})
      end)

      socket
    else
      socket
    end
  end

  ## FlareSolverr global config (row + edit modal)

  @flaresolverr_specs [
    {:enabled, "FLARESOLVERR_ENABLED", "flaresolverr.enabled", :boolean},
    {:url, "FLARESOLVERR_URL", "flaresolverr.url", :string},
    {:timeout, "FLARESOLVERR_TIMEOUT", "flaresolverr.timeout", :integer},
    {:max_timeout, "FLARESOLVERR_MAX_TIMEOUT", "flaresolverr.max_timeout", :integer}
  ]

  # Single source of truth: derive the cast types from the specs above.
  @flaresolverr_types Map.new(@flaresolverr_specs, fn {field, _env, _key, type} ->
                        {field, type}
                      end)

  defp assign_flaresolverr(socket) do
    {values, sources} = flaresolverr_values_and_sources()

    summary = %{
      enabled: values.enabled || false,
      url: values.url,
      configured: is_binary(values.url) and values.url != "",
      env?: Enum.any?(Map.values(sources), &(&1 == :env))
    }

    assign(socket, :flaresolverr, summary)
  end

  # Returns `{values, sources}` for the four flaresolverr.* keys. Display values
  # come from the DB side when a row exists (so a save reflects without an app
  # restart); env- and default-sourced fields use the effective runtime config.
  defp flaresolverr_values_and_sources do
    config = Settings.get_runtime_config()
    config = if is_struct(config), do: config, else: Mydia.Config.Schema.defaults()
    fs = config.flaresolverr || %Mydia.Config.Schema.FlareSolverr{}
    all_db = Settings.list_config_settings() |> Map.new(&{&1.key, &1})

    Enum.reduce(@flaresolverr_specs, {%{}, %{}}, fn {field, env_var, key, type},
                                                    {values, sources} ->
      source = Settings.config_source(env_var, key, all_db)
      fallback = Map.get(fs, field)

      value =
        case source do
          :database -> parse_flaresolverr_value(Map.get(all_db, key).value, type, fallback)
          _ -> fallback
        end

      {Map.put(values, field, value), Map.put(sources, key, source)}
    end)
  end

  # A missing/NULL stored value falls back to the schema default rather than
  # coercing to a misleading empty string (or "nil") in the UI.
  defp parse_flaresolverr_value(nil, _type, fallback), do: fallback

  defp parse_flaresolverr_value(raw, :boolean, _fallback),
    do: Settings.parse_setting_boolean(raw)

  defp parse_flaresolverr_value(raw, :integer, fallback) do
    case Integer.parse(to_string(raw)) do
      {int, _} -> int
      :error -> fallback
    end
  end

  defp parse_flaresolverr_value(raw, :string, _fallback), do: to_string(raw)

  defp flaresolverr_changeset(params, sources \\ %{}) do
    changeset =
      {%{}, @flaresolverr_types}
      |> Ecto.Changeset.cast(params, Map.keys(@flaresolverr_types))
      |> Ecto.Changeset.validate_number(:timeout, greater_than: 0)
      |> Ecto.Changeset.validate_number(:max_timeout, greater_than: 0)
      |> validate_max_timeout_not_below_timeout()

    # Require a URL only when the user is enabling FlareSolverr AND the URL is not
    # already supplied by the environment. An env-sourced URL renders disabled, so
    # it is omitted from the submitted params; requiring it would wrongly block a
    # save whose URL comes from FLARESOLVERR_URL.
    enabling? = Ecto.Changeset.get_field(changeset, :enabled) == true
    url_from_env? = Map.get(sources, "flaresolverr.url") == :env

    if enabling? and not url_from_env? do
      Ecto.Changeset.validate_required(changeset, [:url])
    else
      changeset
    end
  end

  defp validate_max_timeout_not_below_timeout(changeset) do
    timeout = Ecto.Changeset.get_field(changeset, :timeout)
    max_timeout = Ecto.Changeset.get_field(changeset, :max_timeout)

    if is_integer(timeout) and is_integer(max_timeout) and max_timeout < timeout do
      Ecto.Changeset.add_error(
        changeset,
        :max_timeout,
        "must be greater than or equal to timeout"
      )
    else
      changeset
    end
  end

  # Persist each editable field; env-sourced keys are read-only (env wins at
  # runtime) so they are skipped. Returns `:ok` only when every write succeeds, so
  # the caller never reports success on a failed or partial save.
  defp persist_flaresolverr(data, sources, user_id) do
    @flaresolverr_specs
    |> Enum.filter(fn {_field, _env_var, key, _type} -> Map.get(sources, key) != :env end)
    |> Enum.reduce_while(:ok, fn {field, _env_var, key, _type}, _acc ->
      case Settings.upsert_config_setting(%{
             key: key,
             value: to_string(Map.get(data, field)),
             category: :flaresolverr,
             updated_by_id: user_id
           }) do
        {:ok, _setting} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  # Refresh the cached runtime config so the saved FlareSolverr settings take
  # effect immediately (health checks, search, and downloads all read it). Returns
  # `{:error, reason}` when the merged config fails validation so the caller can
  # warn that the save will not apply until a restart.
  defp reload_runtime_config(socket) do
    case Mydia.Config.Loader.reload() do
      {:ok, _config} ->
        :ok

      {:error, reason} ->
        MydiaLogger.log_error(
          :liveview,
          "Failed to reload runtime config after FlareSolverr save",
          error: reason,
          operation: :reload_runtime_config,
          user_id: socket.assigns.current_user.id
        )

        {:error, reason}
    end
  end

  defp flash_flaresolverr_save(socket, :ok),
    do: put_flash(socket, :info, "FlareSolverr settings saved")

  defp flash_flaresolverr_save(socket, {:error, _reason}) do
    put_flash(
      socket,
      :error,
      "FlareSolverr settings saved, but the runtime config could not be reloaded because the " <>
        "merged configuration is invalid. The change will take effect once the configuration " <>
        "is valid. Check the logs for the validation error."
    )
  end

  defp init_library_assigns(socket) do
    socket
    |> assign(:library_definitions, [])
    |> assign(:library_available_languages, [])
    |> assign(:library_filter_type, "all")
    |> assign(:library_filter_language, "all")
    |> assign(:library_filter_enabled, "all")
    |> assign(:library_search_query, "")
    |> assign(:library_syncing, false)
    |> assign(:library_configuring_definition, nil)
    |> assign(:library_config_form, nil)
  end

  defp load_library_definitions(socket) do
    filters = build_library_filters(socket.assigns)
    definitions = Indexers.list_cardigann_definitions(filters)

    all_definitions = Indexers.list_cardigann_definitions()

    languages =
      all_definitions
      |> Enum.map(& &1.language)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    socket
    |> assign(:library_definitions, definitions)
    |> assign(:library_available_languages, languages)
  end

  defp build_library_filters(assigns) do
    filters = []

    filters =
      if assigns.library_filter_type != "all" do
        [{:type, assigns.library_filter_type} | filters]
      else
        filters
      end

    filters =
      if assigns.library_filter_language != "all" do
        [{:language, assigns.library_filter_language} | filters]
      else
        filters
      end

    filters =
      case assigns.library_filter_enabled do
        "enabled" -> [{:enabled, true} | filters]
        "disabled" -> [{:enabled, false} | filters]
        _ -> filters
      end

    if assigns.library_search_query != "" do
      [{:search, assigns.library_search_query} | filters]
    else
      filters
    end
  end

  defp maybe_auto_fetch_prowlarr_indexers(socket, changeset) do
    type = Ecto.Changeset.get_field(changeset, :type)
    env_name = Ecto.Changeset.get_field(changeset, :env_name)
    base_url = Ecto.Changeset.get_field(changeset, :base_url)
    api_key = Ecto.Changeset.get_field(changeset, :api_key)
    is_prowlarr = type == :prowlarr or type == "prowlarr"

    if is_prowlarr do
      {url, key} =
        if env_name && env_name != "" do
          {System.get_env("#{env_name}_BASE_URL"), System.get_env("#{env_name}_API_KEY")}
        else
          {base_url, api_key}
        end

      if url && url != "" && key && key != "" do
        fetch_prowlarr_indexers_sync(socket, url, key)
      else
        socket
      end
    else
      socket
    end
  end

  defp fetch_prowlarr_indexers_sync(socket, base_url, api_key) do
    socket = assign(socket, :fetching_prowlarr_indexers, true)
    config = %{base_url: base_url, api_key: api_key}

    case Indexers.list_prowlarr_indexers(config) do
      {:ok, indexers} ->
        socket
        |> assign(:prowlarr_indexers, indexers)
        |> assign(:fetching_prowlarr_indexers, false)
        |> assign(:prowlarr_indexers_error, nil)

      {:error, error} ->
        error_msg =
          case error do
            %{message: msg} -> msg
            msg when is_binary(msg) -> msg
            _ -> "Failed to fetch indexers"
          end

        socket
        |> assign(:prowlarr_indexers, nil)
        |> assign(:fetching_prowlarr_indexers, false)
        |> assign(:prowlarr_indexers_error, error_msg)
    end
  end

  defp init_prowlarr_indexer_assigns(socket, existing_ids) do
    selected_ids =
      (existing_ids || [])
      |> Enum.map(fn
        id when is_integer(id) ->
          id

        id when is_binary(id) ->
          case Integer.parse(id) do
            {int, ""} -> int
            _ -> nil
          end

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    socket
    |> assign(:prowlarr_indexers, nil)
    |> assign(:fetching_prowlarr_indexers, false)
    |> assign(:prowlarr_indexers_error, nil)
    |> assign(:selected_prowlarr_indexer_ids, selected_ids)
  end

  defp merge_prowlarr_indexer_ids(params, assigns) do
    selected_ids = Map.get(assigns, :selected_prowlarr_indexer_ids, MapSet.new())
    indexer_ids = selected_ids |> MapSet.to_list() |> Enum.map(&to_string/1)
    type = params["type"]

    if type == "prowlarr",
      do: Map.put(params, "indexer_ids", indexer_ids),
      else: params
  end

  defp format_sync_error(:rate_limit_exceeded),
    do: "GitHub API rate limit exceeded. Try again later."

  defp format_sync_error(:not_found), do: "Repository or definitions path not found."
  defp format_sync_error({:unexpected_status, status}), do: "Unexpected HTTP status: #{status}"
  defp format_sync_error(reason) when is_binary(reason), do: reason
  defp format_sync_error(reason), do: inspect(reason)

  # A search that reached the site but parsed nothing is neither a success nor
  # an outage, and flattening it into "Connection successful" is what let five
  # indexers report a green test while every search returned zero results. The
  # flash component only has :info and :error (core_components.ex:45), so a
  # degraded result is :error with a message that says what is degraded; the
  # row's health badge carries the "degraded" state separately.
  defp library_test_flash(%{success: true, status: "degraded"} = result) do
    {:error, "#{result.message} (#{result.response_time_ms}ms)"}
  end

  defp library_test_flash(%{success: true} = result) do
    {:info, "#{result.message} (#{result.response_time_ms}ms)"}
  end

  defp library_test_flash(result) do
    {:error, "#{result.message}: #{result.error || "Unknown error"}"}
  end
end
