defmodule MydiaWeb.AdminConfigLive.Index do
  use MydiaWeb, :live_view
  alias Mydia.DB
  alias Mydia.Repo
  alias Mydia.Settings
  alias Mydia.Streaming
  alias Mydia.Playback
  alias Mydia.Downloads

  alias Mydia.Settings.{
    QualityProfile,
    DownloadClientConfig,
    IndexerConfig,
    LibraryPath,
    MediaServerConfig
  }

  alias Mydia.MediaServer.Client, as: MediaServerClient
  alias Mydia.MediaServer.PlexOAuth
  alias Mydia.Downloads.ClientHealth
  alias Mydia.Indexers
  alias Mydia.Indexers.Health, as: IndexerHealth
  alias Mydia.Indexers.CardigannFeatureFlags
  alias Mydia.System
  alias MydiaWeb.AdminConfigLive.Components
  alias MydiaWeb.AdminConfigLive.FlareSolverrStatusComponent

  require Logger
  alias Mydia.Logger, as: MydiaLogger

  # Capture Mix.env at compile time since Mix is not available in releases
  @env Mix.env()

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Refresh system data every 5 seconds for real-time updates
      :timer.send_interval(5000, self(), :refresh_system_data)
      # Subscribe to library scanner topic for job updates
      Phoenix.PubSub.subscribe(Mydia.PubSub, "library_scanner")
      # Subscribe to remote access claim events (for auto-closing pairing modal)
      Phoenix.PubSub.subscribe(Mydia.PubSub, "remote_access:claims")
      # Subscribe to player session events
      Phoenix.PubSub.subscribe(Mydia.PubSub, "hls_sessions")
      # Subscribe to transcode job updates
      Phoenix.PubSub.subscribe(Mydia.PubSub, "transcodes")
    end

    {:ok,
     socket
     |> assign(:page_title, "Configuration")
     |> assign(:active_tab, "status")
     |> assign(:cardigann_enabled, CardigannFeatureFlags.enabled?())
     |> assign(:remote_access_enabled, remote_access_enabled?())
     |> assign(:reorganizing_library_ids, MapSet.new())
     |> assign(:reclassifying_library_ids, MapSet.new())
     |> assign(:flaresolverr_status, %{configured: false, status: :loading})
     |> load_configuration_data()
     |> load_system_data()
     |> load_player_data()
     |> check_flaresolverr_async()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    tab = params["tab"] || "status"

    {:noreply,
     socket
     |> assign(:active_tab, tab)
     |> maybe_setup_form(tab)}
  end

  @impl true
  def handle_info(:refresh_system_data, socket) do
    {:noreply,
     socket
     |> load_system_data()
     |> check_flaresolverr_async()}
  end

  @impl true
  def handle_info({ref, {:flaresolverr_status, status}}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, assign(socket, :flaresolverr_status, status)}
  end

  # Ignore DOWN messages from async tasks (e.g. flaresolverr health check)
  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket) do
    {:noreply, socket}
  end

  # Player session handlers
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

  # Library reorganization job handlers
  @impl true
  def handle_info({:library_reorganize_started, %{library_path_id: id}}, socket) do
    {:noreply, update(socket, :reorganizing_library_ids, &MapSet.put(&1, id))}
  end

  @impl true
  def handle_info({:library_reorganize_completed, %{library_path_id: id} = result}, socket) do
    message =
      cond do
        result.moved == 0 && result.total == 0 ->
          "Reorganization complete: No files to reorganize"

        result.moved == 0 ->
          "Reorganization complete: No files needed moving (#{result.total} already in correct locations)"

        true ->
          "Reorganization complete: Moved #{result.moved} of #{result.total} files"
      end

    {:noreply,
     socket
     |> update(:reorganizing_library_ids, &MapSet.delete(&1, id))
     |> put_flash(:info, message)}
  end

  # Media reclassification job handlers
  @impl true
  def handle_info({:media_reclassify_started, %{library_path_id: id}}, socket) do
    {:noreply, update(socket, :reclassifying_library_ids, &MapSet.put(&1, id))}
  end

  @impl true
  def handle_info({:media_reclassify_completed, %{library_path_id: id} = result}, socket) do
    message =
      cond do
        result.updated > 0 && result.skipped > 0 ->
          "Reclassification complete: #{result.updated} updated (#{result.skipped} skipped with override)"

        result.updated > 0 ->
          "Reclassification complete: #{result.updated} items updated"

        result.skipped > 0 ->
          "Reclassification complete: No changes (#{result.skipped} items have override)"

        true ->
          "Reclassification complete: No category changes detected"
      end

    {:noreply,
     socket
     |> update(:reclassifying_library_ids, &MapSet.delete(&1, id))
     |> put_flash(:info, message)}
  end

  @impl true
  def handle_info(:reload_library_indexers, socket) do
    # Reload library indexers when a library indexer is toggled
    cardigann_enabled = CardigannFeatureFlags.enabled?()

    library_indexers =
      if cardigann_enabled do
        Indexers.list_cardigann_definitions(enabled: true)
      else
        []
      end

    library_indexer_stats =
      if cardigann_enabled do
        Indexers.count_cardigann_definitions()
      else
        %{total: 0, enabled: 0, disabled: 0}
      end

    {:noreply,
     socket
     |> assign(:library_indexers, library_indexers)
     |> assign(:library_indexer_stats, library_indexer_stats)}
  end

  @impl true
  def handle_info({:sync_complete, component_id, result}, socket) do
    # Forward the sync result to the IndexerLibraryComponent
    send_update(MydiaWeb.AdminConfigLive.IndexerLibraryComponent,
      id: component_id,
      sync_result: result
    )

    # Also reload the library indexers data for the main indexers tab
    cardigann_enabled = CardigannFeatureFlags.enabled?()

    library_indexers =
      if cardigann_enabled do
        Indexers.list_cardigann_definitions(enabled: true)
      else
        []
      end

    library_indexer_stats =
      if cardigann_enabled do
        Indexers.count_cardigann_definitions()
      else
        %{total: 0, enabled: 0, disabled: 0}
      end

    {:noreply,
     socket
     |> assign(:library_indexers, library_indexers)
     |> assign(:library_indexer_stats, library_indexer_stats)}
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
  def handle_info({:plex_connection_tested, uri, result}, socket) do
    # Only update if we're still in connection selection state
    if socket.assigns[:plex_oauth_state] == :selecting_connection do
      statuses = socket.assigns[:plex_connection_statuses] || %{}
      updated_statuses = Map.put(statuses, uri, result)

      {:noreply, assign(socket, :plex_connection_statuses, updated_statuses)}
    else
      {:noreply, socket}
    end
  end

  # Remote Access Component handlers
  @impl true
  def handle_info({:remote_access_countdown_tick, component_id}, socket) do
    # Schedule the tick and update the component
    Process.send_after(self(), {:remote_access_do_countdown_tick, component_id}, 1000)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:remote_access_do_countdown_tick, component_id}, socket) do
    send_update(MydiaWeb.AdminConfigLive.RemoteAccessComponent,
      id: component_id,
      countdown_tick: true
    )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:remote_access_refresh_p2p, component_id}, socket) do
    send_update(MydiaWeb.AdminConfigLive.RemoteAccessComponent,
      id: component_id,
      refresh_p2p: true
    )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:claim_consumed, %{code: code, user_id: user_id}}, socket) do
    # Forward claim consumed event to the RemoteAccessComponent
    # Only if the current user matches (to avoid clearing other users' modals)
    if socket.assigns.current_scope && socket.assigns.current_scope.user.id == user_id do
      send_update(MydiaWeb.AdminConfigLive.RemoteAccessComponent,
        id: "remote_access",
        claim_consumed: code
      )
    end

    {:noreply, socket}
  end

  # Ignore library scan messages (started, progress, completed, failed)
  # that are broadcast on the "library_scanner" topic but not relevant here
  @impl true
  def handle_info({event, _}, socket)
      when event in [
             :library_scan_started,
             :library_scan_progress,
             :library_scan_completed,
             :library_scan_failed
           ] do
    {:noreply, socket}
  end

  @impl true
  def handle_event("change_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/config?tab=#{tab}")}
  end

  @impl true
  def handle_event("delete_transcode_job", %{"id" => job_id}, socket) do
    case Mydia.Repo.get(Mydia.Downloads.TranscodeJob, job_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Job not found")}

      job ->
        # cancel_transcode_job always returns {:ok, job}
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

  ## General Settings Events

  @impl true
  def handle_event(
        "update_setting_form",
        %{"category" => category, "settings" => settings},
        socket
      ) do
    # Convert category string to atom for schema compatibility
    category_atom = category_string_to_atom(category)

    # Process each changed setting with validation
    results =
      settings
      |> Enum.map(fn {key, value} ->
        # Validate each setting through a changeset
        changeset =
          validate_config_setting(%{
            key: key,
            value: to_string(value),
            category: category_atom
          })

        if changeset.valid? do
          validated_data = Ecto.Changeset.apply_changes(changeset)
          # Add updated_by_id for audit trail
          validated_data_with_user =
            Map.put(validated_data, :updated_by_id, socket.assigns.current_user.id)

          upsert_config_setting(validated_data_with_user)
        else
          {:error, changeset}
        end
      end)

    # Check if all updates succeeded
    if Enum.all?(results, fn result -> match?({:ok, _}, result) end) do
      {:noreply,
       socket
       |> put_flash(:info, "Settings updated successfully")
       |> load_configuration_data()}
    else
      # Log failed updates
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
    # Convert category string to atom for schema compatibility
    category_atom = category_string_to_atom(category)

    # Get the new value, either from params or by looking up current value and toggling it
    new_value =
      case Map.get(params, "value") do
        nil ->
          # Value not provided (Phoenix drops false values), look up current setting
          case Settings.get_config_setting_by_key(key) do
            nil -> "true"
            setting -> to_string(!parse_boolean_value(setting.value))
          end

        value ->
          to_string(value)
      end

    # Handle boolean toggle with validation
    changeset =
      validate_config_setting(%{
        key: key,
        value: new_value,
        category: category_atom
      })

    if changeset.valid? do
      validated_data = Ecto.Changeset.apply_changes(changeset)
      # Add updated_by_id for audit trail
      validated_data_with_user =
        Map.put(validated_data, :updated_by_id, socket.assigns.current_user.id)

      case upsert_config_setting(validated_data_with_user) do
        {:ok, _setting} ->
          {:noreply,
           socket
           |> put_flash(:info, "Setting updated successfully")
           |> load_configuration_data()}

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
    # Convert category string to atom for schema compatibility
    category_atom = category_string_to_atom(category)

    # Generic select setting handling for future select settings
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
           |> load_configuration_data()}

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

  ## Quality Profile Events

  @impl true
  def handle_event("update_default_quality_profile", params, socket) do
    Logger.debug("update_default_quality_profile params: #{inspect(params)}")

    profile_id = params["profile_id"]
    profile_id = if profile_id == "", do: nil, else: profile_id

    case Settings.set_default_quality_profile(profile_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Default quality profile updated")
         |> assign(:default_quality_profile_id, profile_id)}

      {:error, reason} ->
        Logger.error("Failed to update default quality profile: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(:error, "Failed to update default quality profile")}
    end
  end

  @impl true
  def handle_event("new_quality_profile", _params, socket) do
    changeset = Settings.change_quality_profile(%QualityProfile{})

    {:noreply,
     socket
     |> assign(:show_quality_profile_modal, true)
     |> assign(:quality_profile_form, to_form(changeset))
     |> assign(:quality_profile_mode, :new)
     |> assign(:quality_profile_active_tab, "basic")}
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
     |> assign(:editing_quality_profile, profile)
     |> assign(:quality_profile_active_tab, "basic")}
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

    case Settings.clone_quality_profile(profile) do
      {:ok, _new_profile} ->
        {:noreply,
         socket
         |> put_flash(:info, "Quality profile cloned successfully")
         |> load_configuration_data()}

      {:error, changeset} ->
        MydiaLogger.log_error(:liveview, "Failed to clone quality profile",
          error: changeset,
          operation: :duplicate_quality_profile,
          profile_id: id,
          user_id: socket.assigns.current_user.id
        )

        error_msg = MydiaLogger.user_error_message(:duplicate_quality_profile, changeset)

        {:noreply,
         socket
         |> put_flash(:error, error_msg)}
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
        # Show confirmation modal instead of error
        affected_count = Settings.count_media_items_for_profile(id)

        {:noreply,
         socket
         |> assign(:show_delete_profile_modal, true)
         |> assign(:profile_to_delete, profile)
         |> assign(:affected_media_count, affected_count)}

      {:error, error} ->
        MydiaLogger.log_error(:liveview, "Failed to delete quality profile",
          error: error,
          operation: :delete_quality_profile,
          profile_id: id,
          profile_name: profile.name,
          user_id: socket.assigns.current_user.id
        )

        error_msg = MydiaLogger.user_error_message(:delete_quality_profile, error)

        {:noreply,
         socket
         |> put_flash(:error, error_msg)}
    end
  end

  @impl true
  def handle_event("confirm_delete_quality_profile", _params, socket) do
    profile = socket.assigns.profile_to_delete

    case Settings.force_delete_quality_profile(profile) do
      {:ok, _deleted_profile} ->
        MydiaLogger.log_info(:liveview, "Force deleted quality profile",
          operation: :force_delete_quality_profile,
          profile_id: profile.id,
          profile_name: profile.name,
          affected_media_count: socket.assigns.affected_media_count,
          user_id: socket.assigns.current_user.id
        )

        {:noreply,
         socket
         |> assign(:show_delete_profile_modal, false)
         |> assign(:profile_to_delete, nil)
         |> assign(:affected_media_count, 0)
         |> put_flash(:info, "Quality profile deleted and unassigned from media items")
         |> load_configuration_data()}

      {:error, error} ->
        MydiaLogger.log_error(:liveview, "Failed to force delete quality profile",
          error: error,
          operation: :force_delete_quality_profile,
          profile_id: profile.id,
          profile_name: profile.name,
          user_id: socket.assigns.current_user.id
        )

        error_msg = MydiaLogger.user_error_message(:force_delete_quality_profile, error)

        {:noreply,
         socket
         |> assign(:show_delete_profile_modal, false)
         |> put_flash(:error, error_msg)}
    end
  end

  @impl true
  def handle_event("cancel_delete_quality_profile", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_delete_profile_modal, false)
     |> assign(:profile_to_delete, nil)
     |> assign(:affected_media_count, 0)}
  end

  @impl true
  def handle_event("close_quality_profile_modal", _params, socket) do
    {:noreply, assign(socket, :show_quality_profile_modal, false)}
  end

  @impl true
  def handle_event("change_quality_profile_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :quality_profile_active_tab, tab)}
  end

  @impl true
  def handle_event("export_quality_profile", %{"id" => id, "format" => format}, socket) do
    profile = Settings.get_quality_profile!(id)
    format_atom = String.to_existing_atom(format)

    case Settings.export_profile(profile, format: format_atom) do
      {:ok, content} ->
        # Trigger file download via JavaScript
        {:noreply,
         socket
         |> push_event("download_file", %{
           content: content,
           filename: "#{profile.name}.#{format}",
           mime_type: get_export_mime_type(format_atom)
         })}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, "Export failed: #{reason}")}
    end
  end

  @impl true
  def handle_event("import_quality_profile_url", %{"url" => url}, socket) do
    case Settings.import_profile(url, dry_run: false) do
      {:ok, _profile} ->
        {:noreply,
         socket
         |> assign(:show_import_modal, false)
         |> assign(:import_error, nil)
         |> put_flash(:info, "Profile imported successfully from URL")
         |> load_configuration_data()}

      {:error, reason} ->
        MydiaLogger.log_error(:liveview, "Failed to import quality profile from URL",
          error: reason,
          operation: :import_quality_profile,
          url: url,
          user_id: socket.assigns.current_user.id
        )

        error_msg =
          case reason do
            msg when is_binary(msg) -> msg
            _ -> "Failed to import profile: #{inspect(reason)}"
          end

        {:noreply, socket |> assign(:import_error, error_msg)}
    end
  end

  @impl true
  def handle_event("show_import_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_import_modal, true)
     |> assign(:import_error, nil)}
  end

  @impl true
  def handle_event("close_import_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_import_modal, false)
     |> assign(:import_error, nil)}
  end

  ## Browse Presets Events

  @impl true
  def handle_event("show_browse_presets_modal", _params, socket) do
    alias Mydia.Settings.QualityProfilePresets

    {:noreply,
     socket
     |> assign(:show_browse_presets_modal, true)
     |> assign(:browse_presets_category, :all)
     |> assign(:browse_presets, QualityProfilePresets.list_presets())}
  end

  @impl true
  def handle_event("close_browse_presets_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_browse_presets_modal, false)
     |> assign(:browse_presets, [])
     |> assign(:browse_presets_category, :all)}
  end

  @impl true
  def handle_event("filter_presets", %{"category" => category}, socket) do
    alias Mydia.Settings.QualityProfilePresets
    category_atom = String.to_existing_atom(category)

    {:noreply,
     socket
     |> assign(:browse_presets_category, category_atom)
     |> assign(:browse_presets, QualityProfilePresets.list_presets_by_category(category_atom))}
  end

  @impl true
  def handle_event("import_preset", %{"preset-id" => preset_id}, socket) do
    alias Mydia.Settings.QualityProfilePresets

    case QualityProfilePresets.get_preset(preset_id) do
      {:ok, preset} ->
        # Import the preset as a new quality profile
        case Settings.create_quality_profile(preset.profile_data) do
          {:ok, _profile} ->
            {:noreply,
             socket
             |> put_flash(:info, "Preset \"#{preset.name}\" imported successfully")
             |> assign(:show_browse_presets_modal, false)
             |> load_configuration_data()}

          {:error, changeset} ->
            errors = format_changeset_errors(changeset)

            {:noreply,
             socket
             |> put_flash(:error, "Failed to import preset: #{errors}")}
        end

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Preset not found")}
    end
  end

  ## Download Client Events

  @impl true
  def handle_event("new_download_client", _params, socket) do
    changeset = DownloadClientConfig.changeset(%DownloadClientConfig{}, %{})

    {:noreply,
     socket
     |> assign(:show_download_client_modal, true)
     |> assign(:download_client_form, to_form(changeset))
     |> assign(:download_client_mode, :new)
     |> assign(:testing_download_client_connection, false)}
  end

  @impl true
  def handle_event("edit_download_client", %{"id" => id}, socket) do
    client = Settings.get_download_client_config!(id)

    # Check if this is a runtime config and prevent editing
    if Settings.runtime_config?(client) do
      {:noreply,
       socket
       |> put_flash(
         :error,
         "Cannot edit runtime-configured download client. This client is configured via environment variables and is read-only in the UI."
       )}
    else
      changeset = DownloadClientConfig.changeset(client, %{})

      {:noreply,
       socket
       |> assign(:show_download_client_modal, true)
       |> assign(:download_client_form, to_form(changeset))
       |> assign(:download_client_mode, :edit)
       |> assign(:editing_download_client, client)
       |> assign(:testing_download_client_connection, false)}
    end
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

    # Check if this is a runtime config and prevent deletion
    if Settings.runtime_config?(client) do
      {:noreply,
       socket
       |> put_flash(
         :error,
         "Cannot delete runtime-configured download client. This client is configured via environment variables and is read-only in the UI."
       )}
    else
      case Settings.delete_download_client_config(client) do
        {:ok, _client} ->
          {:noreply,
           socket
           |> put_flash(:info, "Download client deleted successfully")
           |> load_configuration_data()}

        {:error, error} ->
          MydiaLogger.log_error(:liveview, "Failed to delete download client",
            error: error,
            operation: :delete_download_client,
            client_id: id,
            client_name: client.name,
            user_id: socket.assigns.current_user.id
          )

          error_msg = MydiaLogger.user_error_message(:delete_download_client, error)

          {:noreply,
           socket
           |> put_flash(:error, error_msg)}
      end
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
    client_config =
      if client.type == :blackhole do
        # Blackhole uses connection_settings for folder paths
        %{
          type: :blackhole,
          connection_settings: client.connection_settings || %{}
        }
      else
        # Network-based clients
        %{
          type: client.type,
          host: client.host,
          port: client.port,
          use_ssl: client.use_ssl,
          username: client.username,
          password: client.password,
          api_key: client.api_key,
          url_base: client.url_base,
          options: client.connection_settings || %{}
        }
      end

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
        MydiaLogger.log_error(:liveview, "Download client connection test failed",
          error: error,
          operation: :test_download_client,
          client_id: id,
          client_type: client.type,
          client_host: client.host,
          user_id: socket.assigns.current_user.id
        )

        error_msg =
          case error do
            %{message: msg} -> msg
            _ -> MydiaLogger.extract_error_message(error)
          end

        {:noreply,
         socket
         |> put_flash(:error, "Connection failed: #{error_msg}")}
    end
  end

  @impl true
  def handle_event("test_download_client_connection", _params, socket) do
    # Extract form params from the current changeset
    changeset = socket.assigns.download_client_form.source

    # Get the changeset data (which includes user input)
    params = Ecto.Changeset.apply_changes(changeset)

    # Convert string type to atom if needed
    type =
      case params.type do
        type when is_atom(type) -> type
        type when is_binary(type) -> String.to_existing_atom(type)
      end

    # Build config map for test_connection
    test_config =
      if type == :blackhole do
        # Blackhole uses connection_settings for folder paths
        %{
          type: :blackhole,
          connection_settings: params.connection_settings || %{}
        }
      else
        # Network-based clients
        %{
          type: type,
          host: params.host,
          port: params.port,
          use_ssl: params.use_ssl || false,
          username: params.username,
          password: params.password,
          api_key: params.api_key,
          url_base: params.url_base,
          options: params.connection_settings || %{}
        }
      end

    # Test the connection (adapters already handle timeouts via receive_timeout)
    case test_client_connection(test_config) do
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
         |> assign(:testing_download_client_connection, false)
         |> put_flash(:info, "Connection successful! #{version_info}")}

      {:error, error} ->
        MydiaLogger.log_warning(:liveview, "Download client connection test failed",
          operation: :test_download_client_connection,
          error: error,
          client_type: type,
          user_id: socket.assigns.current_user.id
        )

        error_msg =
          case error do
            %{message: msg} -> msg
            _ -> MydiaLogger.extract_error_message(error)
          end

        {:noreply,
         socket
         |> assign(:testing_download_client_connection, false)
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

    # Check if this is a runtime config - convert to DB-managed with env_name
    if Settings.runtime_config?(indexer) do
      # Find matching env source by base_url
      matching_env =
        Enum.find(available_env_indexers, fn env ->
          env.base_url == indexer.base_url
        end)

      # Pre-fill with runtime config data, setting env_name if we found a match
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
    # Add selected Prowlarr indexer IDs to params
    params = merge_prowlarr_indexer_ids(params, socket.assigns)

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

    # Check if this is a runtime config and prevent deletion
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
           |> load_configuration_data()}

        {:error, error} ->
          MydiaLogger.log_error(:liveview, "Failed to delete indexer",
            error: error,
            operation: :delete_indexer,
            indexer_id: id,
            indexer_name: indexer.name,
            user_id: socket.assigns.current_user.id
          )

          error_msg = MydiaLogger.user_error_message(:delete_indexer, error)

          {:noreply,
           socket
           |> put_flash(:error, error_msg)}
      end
    end
  end

  @impl true
  def handle_event("close_indexer_modal", _params, socket) do
    {:noreply, assign(socket, :show_indexer_modal, false)}
  end

  @impl true
  def handle_event("fetch_prowlarr_indexers", _params, socket) do
    # Get connection details from the form
    changeset = socket.assigns.indexer_form.source
    params = Ecto.Changeset.apply_changes(changeset)

    # Check if we're using env-based config
    env_name = params.env_name

    {base_url, api_key} =
      if env_name && env_name != "" do
        # Get connection details from environment variables
        # Use Elixir.System to avoid conflict with aliased Mydia.System
        base_url = Elixir.System.get_env("#{env_name}_BASE_URL")
        api_key = Elixir.System.get_env("#{env_name}_API_KEY")
        {base_url, api_key}
      else
        {params.base_url, params.api_key}
      end

    if is_nil(base_url) or base_url == "" or is_nil(api_key) or api_key == "" do
      {:noreply,
       socket
       |> assign(:prowlarr_indexers_error, "Base URL and API Key are required to fetch indexers")}
    else
      socket = assign(socket, :fetching_prowlarr_indexers, true)

      # Fetch indexers asynchronously
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
      if MapSet.member?(selected, id) do
        MapSet.delete(selected, id)
      else
        MapSet.put(selected, id)
      end

    {:noreply, assign(socket, :selected_prowlarr_indexer_ids, updated)}
  end

  @impl true
  def handle_event("select_all_prowlarr_indexers", _params, socket) do
    indexers = socket.assigns.prowlarr_indexers || []

    # Select only enabled indexers
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
    {:noreply, assign(socket, :show_indexer_library_modal, true)}
  end

  @impl true
  def handle_event("close_indexer_library", _params, socket) do
    {:noreply, assign(socket, :show_indexer_library_modal, false)}
  end

  @impl true
  def handle_event("test_indexer_connection", _params, socket) do
    # Wrap the entire handler in try/rescue to prevent LiveView crashes
    # that would cause the flash message to be lost on reconnect
    try do
      changeset = socket.assigns.indexer_form.source
      params = Ecto.Changeset.apply_changes(changeset)

      type =
        case params.type do
          type when is_atom(type) -> type
          type when is_binary(type) -> String.to_existing_atom(type)
        end

      test_config = %{
        type: type,
        base_url: params.base_url,
        api_key: params.api_key
      }

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
    rescue
      e ->
        {:noreply,
         socket
         |> assign(:testing_indexer_connection, false)
         |> put_flash(:error, "Connection failed: #{Exception.message(e)}")}
    catch
      kind, reason ->
        {:noreply,
         socket
         |> assign(:testing_indexer_connection, false)
         |> put_flash(:error, "Connection failed: #{inspect(kind)} - #{inspect(reason)}")}
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
         |> load_configuration_data()}

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
         |> load_configuration_data()}

      {:error, :not_found} ->
        MydiaLogger.log_error(:liveview, "Indexer not found for health check",
          operation: :test_indexer,
          indexer_id: id,
          user_id: socket.assigns.current_user.id
        )

        {:noreply,
         socket
         |> put_flash(:error, "Indexer not found")}

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
         |> load_configuration_data()}
    end
  end

  @impl true
  def handle_event("test_library_indexer", %{"id" => id}, socket) do
    case Indexers.test_cardigann_connection(id) do
      {:ok, result} ->
        flash_message =
          if result.success do
            "Connection successful (#{result.response_time_ms}ms)"
          else
            "Connection failed: #{result.error || "Unknown error"}"
          end

        flash_type = if result.success, do: :info, else: :error

        {:noreply,
         socket
         |> put_flash(flash_type, flash_message)
         |> load_configuration_data()}

      {:error, reason} ->
        MydiaLogger.log_error(:liveview, "Failed to test library indexer connection",
          error: reason,
          operation: :test_library_indexer,
          definition_id: id,
          user_id: socket.assigns.current_user.id
        )

        {:noreply,
         socket
         |> put_flash(:error, "Failed to test connection: #{inspect(reason)}")}
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
         |> load_configuration_data()}

      {:error, changeset} ->
        MydiaLogger.log_error(:liveview, "Failed to toggle FlareSolverr",
          error: changeset,
          operation: :toggle_library_flaresolverr,
          definition_id: id,
          user_id: socket.assigns.current_user.id
        )

        error_msg = MydiaLogger.user_error_message(:toggle_library_flaresolverr, changeset)

        {:noreply,
         socket
         |> put_flash(:error, error_msg)}
    end
  end

  @impl true
  def handle_event("toggle_library_indexer", %{"id" => id}, socket) do
    definition = Indexers.get_cardigann_definition!(id)

    result =
      if definition.enabled do
        Indexers.disable_cardigann_definition(definition)
      else
        Indexers.enable_cardigann_definition(definition)
      end

    case result do
      {:ok, updated_definition} ->
        socket =
          if updated_definition.enabled do
            # Re-enabling: show success flash, clear undo banner
            socket
            |> put_flash(:info, "#{definition.name} enabled")
            |> assign(:recently_disabled_indexer, nil)
          else
            # Disabling: show undo banner instead of flash
            socket
            |> assign(:recently_disabled_indexer, updated_definition)
          end

        {:noreply, load_configuration_data(socket)}

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
             |> load_configuration_data()}

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

    # Parse the definition to get the settings
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

    # First save the config, then test
    case Indexers.configure_cardigann_definition(definition, config_params) do
      {:ok, updated_definition} ->
        # Start testing
        socket =
          socket
          |> assign(:library_config_testing, true)
          |> assign(:library_config_test_result, nil)
          |> assign(:configuring_library_indexer, updated_definition)

        # Run test in background and send result back
        parent = self()
        definition_id = updated_definition.id

        Task.start(fn ->
          result = Indexers.test_cardigann_connection(definition_id)
          send(parent, {:library_config_test_complete, result})
        end)

        {:noreply, socket}

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
  def handle_event(
        "save_library_indexer_config",
        %{"config" => config_params, "action" => "save"},
        socket
      ) do
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
         |> load_configuration_data()}

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

  # Fallback for form without action (backwards compatibility)
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
         |> load_configuration_data()}

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

  ## FlareSolverr Events

  @impl true
  def handle_event("test_flaresolverr", _params, socket) do
    alias Mydia.Indexers.FlareSolverr

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
         |> assign(:flaresolverr_status, FlareSolverrStatusComponent.get_status())
         |> load_system_data()}

      {:error, :disabled} ->
        {:noreply,
         socket
         |> put_flash(:error, "FlareSolverr is disabled. Enable it in configuration.")}

      {:error, :not_configured} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "FlareSolverr is not configured. Set FLARESOLVERR_URL in environment."
         )}

      {:error, {:connection_error, reason}} ->
        {:noreply,
         socket
         |> put_flash(:error, "FlareSolverr connection failed: #{reason}")}

      {:error, reason} ->
        MydiaLogger.log_error(:liveview, "FlareSolverr health check failed",
          error: reason,
          operation: :test_flaresolverr,
          user_id: socket.assigns.current_user.id
        )

        {:noreply,
         socket
         |> put_flash(:error, "FlareSolverr test failed: #{inspect(reason)}")}
    end
  end

  ## Crash Reporting Events

  @impl true
  def handle_event("clear_crash_queue", _params, socket) do
    Mydia.CrashReporter.clear_queue()

    {:noreply,
     socket
     |> put_flash(:info, "Crash report queue cleared")
     |> load_configuration_data()}
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
    # First validate through changeset
    library_path =
      case socket.assigns.library_path_mode do
        :new -> %LibraryPath{}
        :edit -> socket.assigns.editing_library_path
      end

    changeset = LibraryPath.changeset(library_path, params)

    if changeset.valid? do
      validated_data = Ecto.Changeset.apply_changes(changeset)

      # Validate directory exists using validated data
      case validate_directory(validated_data.path) do
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
          changeset =
            changeset
            |> Ecto.Changeset.add_error(:path, reason)

          {:noreply,
           socket
           |> assign(:library_path_form, to_form(changeset))
           |> put_flash(:error, "Invalid directory: #{reason}")}
      end
    else
      {:noreply,
       socket
       |> assign(:library_path_form, to_form(changeset))
       |> put_flash(:error, "Please fix the validation errors")}
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

      {:error, error} ->
        MydiaLogger.log_error(:liveview, "Failed to delete library path",
          error: error,
          operation: :delete_library_path,
          path_id: id,
          path: path.path,
          user_id: socket.assigns.current_user.id
        )

        error_msg = MydiaLogger.user_error_message(:delete_library_path, error)

        {:noreply,
         socket
         |> put_flash(:error, error_msg)}
    end
  end

  @impl true
  def handle_event("close_library_path_modal", _params, socket) do
    {:noreply, assign(socket, :show_library_path_modal, false)}
  end

  @impl true
  def handle_event("preview_reorganize", %{"id" => id}, socket) do
    alias Mydia.Library.FileOrganizer

    library_path = Settings.get_library_path!(id)

    {:ok, summary} = FileOrganizer.reorganize_library(library_path, dry_run: true)

    message =
      if summary.total == 0 do
        "No files need reorganization"
      else
        "Preview: #{summary.moved} of #{summary.total} files would be moved to category folders"
      end

    {:noreply, put_flash(socket, :info, message)}
  end

  @impl true
  def handle_event("reorganize_library", %{"id" => id}, socket) do
    alias Mydia.Jobs.LibraryReorganize

    case LibraryReorganize.enqueue(id) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> update(:reorganizing_library_ids, &MapSet.put(&1, id))
         |> put_flash(:info, "Library reorganization started...")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start reorganization")}
    end
  end

  @impl true
  def handle_event("reclassify_library", %{"id" => id}, socket) do
    alias Mydia.Jobs.MediaReclassify

    case MediaReclassify.enqueue(id) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> update(:reclassifying_library_ids, &MapSet.put(&1, id))
         |> put_flash(:info, "Media reclassification started...")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start reclassification")}
    end
  end

  ## Media Server Events

  @impl true
  def handle_event("new_media_server", _params, socket) do
    # Set default type to :plex so the OAuth UI shows immediately
    changeset = Settings.change_media_server_config(%MediaServerConfig{}, %{type: :plex})

    {:noreply,
     socket
     |> assign(:show_media_server_modal, true)
     |> assign(:media_server_form, to_form(changeset))
     |> assign(:media_server_mode, :new)
     |> assign(:testing_media_server_connection, false)
     |> assign(:plex_oauth_state, :idle)
     |> assign(:plex_oauth_pin_id, nil)
     |> assign(:plex_oauth_servers, [])
     |> assign(:plex_oauth_token, nil)
     |> assign(:plex_manual_entry, false)}
  end

  @impl true
  def handle_event("edit_media_server", %{"id" => id}, socket) do
    server = Settings.get_media_server_config!(id)

    # Check if this is a runtime config and prevent editing
    if Settings.runtime_config?(server) do
      {:noreply,
       socket
       |> put_flash(
         :error,
         "Cannot edit runtime-configured media server. This server is configured via environment variables and is read-only in the UI."
       )}
    else
      changeset = Settings.change_media_server_config(server)

      {:noreply,
       socket
       |> assign(:show_media_server_modal, true)
       |> assign(:media_server_form, to_form(changeset))
       |> assign(:media_server_mode, :edit)
       |> assign(:editing_media_server, server)
       |> assign(:testing_media_server_connection, false)
       |> assign(:plex_oauth_state, :idle)
       |> assign(:plex_oauth_pin_id, nil)
       |> assign(:plex_oauth_servers, [])
       |> assign(:plex_oauth_token, nil)
       |> assign(:plex_manual_entry, true)}
    end
  end

  @impl true
  def handle_event("validate_media_server", %{"media_server_config" => params}, socket) do
    server =
      case socket.assigns.media_server_mode do
        :new -> %MediaServerConfig{}
        :edit -> socket.assigns.editing_media_server
      end

    changeset =
      server
      |> Settings.change_media_server_config(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :media_server_form, to_form(changeset))}
  end

  @impl true
  def handle_event("save_media_server", %{"media_server_config" => params}, socket) do
    # Merge connection_settings with existing values to preserve fields like last_watched_sync_at
    params =
      case socket.assigns.media_server_mode do
        :edit ->
          existing = socket.assigns.editing_media_server.connection_settings || %{}
          new_settings = Map.get(params, "connection_settings", %{})
          merged = Map.merge(existing, new_settings)
          Map.put(params, "connection_settings", merged)

        :new ->
          params
      end

    result =
      case socket.assigns.media_server_mode do
        :new ->
          Settings.create_media_server_config(params)

        :edit ->
          Settings.update_media_server_config(socket.assigns.editing_media_server, params)
      end

    case result do
      {:ok, _server} ->
        {:noreply,
         socket
         |> assign(:show_media_server_modal, false)
         |> put_flash(:info, "Media server saved successfully")
         |> load_configuration_data()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :media_server_form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("delete_media_server", %{"id" => id}, socket) do
    server = Settings.get_media_server_config!(id)

    # Check if this is a runtime config and prevent deletion
    if Settings.runtime_config?(server) do
      {:noreply,
       socket
       |> put_flash(
         :error,
         "Cannot delete runtime-configured media server. This server is configured via environment variables and is read-only in the UI."
       )}
    else
      case Settings.delete_media_server_config(server) do
        {:ok, _server} ->
          {:noreply,
           socket
           |> put_flash(:info, "Media server deleted successfully")
           |> load_configuration_data()}

        {:error, error} ->
          MydiaLogger.log_error(:liveview, "Failed to delete media server",
            error: error,
            operation: :delete_media_server,
            server_id: id,
            server_name: server.name,
            user_id: socket.assigns.current_user.id
          )

          error_msg = MydiaLogger.user_error_message(:delete_media_server, error)

          {:noreply,
           socket
           |> put_flash(:error, error_msg)}
      end
    end
  end

  @impl true
  def handle_event("close_media_server_modal", _params, socket) do
    {:noreply, assign(socket, :show_media_server_modal, false)}
  end

  ## Plex OAuth Events

  @impl true
  def handle_event("start_plex_oauth", _params, socket) do
    case PlexOAuth.create_pin() do
      {:ok, %{id: pin_id, code: code}} ->
        auth_url = PlexOAuth.get_auth_url(code)

        {:noreply,
         socket
         |> assign(:plex_oauth_state, :authorizing)
         |> assign(:plex_oauth_pin_id, pin_id)
         |> push_event("open_plex_auth", %{url: auth_url, pin_id: pin_id})}

      {:error, reason} ->
        Logger.error("Failed to start Plex OAuth: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(:error, "Failed to start Plex authentication: #{reason}")}
    end
  end

  @impl true
  def handle_event("check_plex_pin", %{"pin_id" => pin_id}, socket) do
    case PlexOAuth.check_pin(pin_id) do
      {:ok, %{auth_token: token}} ->
        # PIN has been authorized! Fetch servers
        case PlexOAuth.list_servers(token) do
          {:ok, servers} ->
            {:noreply,
             socket
             |> assign(:plex_oauth_state, :selecting_server)
             |> assign(:plex_oauth_token, token)
             |> assign(:plex_oauth_servers, servers)
             |> push_event("plex_auth_complete", %{})}

          {:error, reason} ->
            Logger.error("Failed to fetch Plex servers: #{inspect(reason)}")

            {:noreply,
             socket
             |> assign(:plex_oauth_state, :error)
             |> put_flash(:error, "Failed to fetch Plex servers: #{reason}")
             |> push_event("plex_auth_failed", %{})}
        end

      :pending ->
        # User hasn't authorized yet, keep polling
        {:noreply, socket}

      {:error, reason} ->
        Logger.error("Plex PIN check failed: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:plex_oauth_state, :error)
         |> put_flash(:error, "Authentication failed: #{reason}")
         |> push_event("plex_auth_failed", %{})}
    end
  end

  @impl true
  def handle_event("plex_popup_closed", _params, socket) do
    # User closed the popup before completing auth
    if socket.assigns.plex_oauth_state == :authorizing do
      {:noreply,
       socket
       |> assign(:plex_oauth_state, :idle)
       |> assign(:plex_oauth_pin_id, nil)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_plex_server", %{"server_id" => server_id}, socket) do
    servers = socket.assigns.plex_oauth_servers
    token = socket.assigns.plex_oauth_token

    case Enum.find(servers, &(&1.client_identifier == server_id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Server not found")}

      server ->
        if server.connections == [] do
          {:noreply, put_flash(socket, :error, "No available connections for this server")}
        else
          # Initialize connection statuses as :testing
          initial_statuses =
            Map.new(server.connections, fn conn -> {conn.uri, :testing} end)

          # Start testing each connection asynchronously
          parent = self()

          for conn <- server.connections do
            Task.start(fn ->
              result = test_plex_connection(conn, token)
              send(parent, {:plex_connection_tested, conn.uri, result})
            end)
          end

          {:noreply,
           socket
           |> assign(:plex_oauth_state, :selecting_connection)
           |> assign(:plex_selected_server, server)
           |> assign(:plex_connection_statuses, initial_statuses)}
        end
    end
  end

  @impl true
  def handle_event("select_plex_connection", %{"url" => url}, socket) do
    server = socket.assigns.plex_selected_server
    token = socket.assigns.plex_oauth_token

    server_base =
      case socket.assigns.media_server_mode do
        :new -> %MediaServerConfig{}
        :edit -> socket.assigns.editing_media_server
      end

    changeset =
      Settings.change_media_server_config(server_base, %{
        name: server.name,
        type: :plex,
        url: url,
        token: token,
        enabled: true
      })

    {:noreply,
     socket
     |> assign(:plex_oauth_state, :complete)
     |> assign(:media_server_form, to_form(changeset))}
  end

  @impl true
  def handle_event("cancel_plex_oauth", _params, socket) do
    # If we're selecting a connection, go back to server list instead of starting over
    if socket.assigns.plex_oauth_state == :selecting_connection do
      {:noreply,
       socket
       |> assign(:plex_oauth_state, :selecting_server)
       |> assign(:plex_selected_server, nil)}
    else
      {:noreply,
       socket
       |> assign(:plex_oauth_state, :idle)
       |> assign(:plex_oauth_pin_id, nil)
       |> assign(:plex_oauth_servers, [])
       |> assign(:plex_oauth_token, nil)
       |> assign(:plex_selected_server, nil)
       |> push_event("plex_auth_cancelled", %{})}
    end
  end

  @impl true
  def handle_event("toggle_plex_manual_entry", _params, socket) do
    {:noreply,
     socket
     |> assign(:plex_manual_entry, !socket.assigns.plex_manual_entry)
     |> assign(:plex_oauth_state, :idle)
     |> assign(:plex_oauth_pin_id, nil)
     |> assign(:plex_oauth_servers, [])
     |> assign(:plex_oauth_token, nil)}
  end

  @impl true
  def handle_event("test_media_server", %{"id" => id}, socket) do
    server = Settings.get_media_server_config!(id)
    adapter = MediaServerClient.adapter_for(server)

    case adapter.test_connection(server) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Connection to #{server.name} successful!")
         |> load_configuration_data()}

      {:error, reason} ->
        MydiaLogger.log_warning(:liveview, "Media server connection test failed",
          operation: :test_media_server,
          server_id: id,
          server_type: server.type,
          error: reason,
          user_id: socket.assigns.current_user.id
        )

        {:noreply,
         socket
         |> put_flash(:error, "Connection failed: #{reason}")
         |> load_configuration_data()}
    end
  end

  @impl true
  def handle_event("sync_watched", %{"id" => id}, socket) do
    server = Settings.get_media_server_config!(id)
    user_id = socket.assigns.current_user.id

    changeset =
      Mydia.Jobs.MediaServerWatchedSync.new(%{
        "config_id" => server.id,
        "user_id" => user_id
      })

    case Oban.insert(changeset) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Watched sync started for #{server.name}")
         |> load_configuration_data()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to start watched sync for #{server.name}")}
    end
  end

  @impl true
  def handle_event("test_media_server_connection", _params, socket) do
    # Extract form params from the current changeset
    changeset = socket.assigns.media_server_form.source

    # Get the changeset data (which includes user input)
    params = Ecto.Changeset.apply_changes(changeset)

    # Convert string type to atom if needed
    type =
      case params.type do
        type when is_atom(type) -> type
        type when is_binary(type) -> String.to_existing_atom(type)
        _ -> :plex
      end

    # Build a temporary config struct for testing
    test_config = %MediaServerConfig{
      type: type,
      url: params.url,
      token: params.token,
      name: params.name || "Test"
    }

    # Test the connection (adapters already handle timeouts via receive_timeout)
    adapter = MediaServerClient.adapter_for(test_config)

    case adapter.test_connection(test_config) do
      :ok ->
        {:noreply,
         socket
         |> assign(:testing_media_server_connection, false)
         |> put_flash(:info, "Connection successful!")}

      {:error, reason} ->
        MydiaLogger.log_warning(:liveview, "Media server connection test failed",
          operation: :test_media_server_connection,
          server_type: type,
          error: reason,
          user_id: socket.assigns.current_user.id
        )

        {:noreply,
         socket
         |> assign(:testing_media_server_connection, false)
         |> put_flash(:error, "Connection failed: #{reason}")}
    end
  end

  ## Prowlarr Indexer Selection Helpers

  # Auto-fetch Prowlarr indexers when opening modal if type is Prowlarr and we have credentials
  defp maybe_auto_fetch_prowlarr_indexers(socket, changeset) do
    type = Ecto.Changeset.get_field(changeset, :type)
    env_name = Ecto.Changeset.get_field(changeset, :env_name)
    base_url = Ecto.Changeset.get_field(changeset, :base_url)
    api_key = Ecto.Changeset.get_field(changeset, :api_key)

    is_prowlarr = type == :prowlarr or type == "prowlarr"

    if is_prowlarr do
      # Get connection details - either from env or from form fields
      {url, key} =
        if env_name && env_name != "" do
          {Elixir.System.get_env("#{env_name}_BASE_URL"),
           Elixir.System.get_env("#{env_name}_API_KEY")}
        else
          {base_url, api_key}
        end

      if url && url != "" && key && key != "" do
        fetch_prowlarr_indexers_async(socket, url, key)
      else
        socket
      end
    else
      socket
    end
  end

  # Fetch indexers from Prowlarr API
  defp fetch_prowlarr_indexers_async(socket, base_url, api_key) do
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

  # Initialize assigns for Prowlarr indexer selection in the modal
  # Stores IDs as integers internally (for MapSet membership checks against Prowlarr API response)
  defp init_prowlarr_indexer_assigns(socket, existing_ids) do
    # Convert existing IDs to integers and create MapSet
    # The schema stores strings, but Prowlarr API returns integers
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

  # Merge selected Prowlarr indexer IDs into save params
  defp merge_prowlarr_indexer_ids(params, assigns) do
    # Get selected IDs from assigns
    selected_ids = Map.get(assigns, :selected_prowlarr_indexer_ids, MapSet.new())

    # Convert to list of strings for storage (schema expects {:array, :string})
    indexer_ids =
      selected_ids
      |> MapSet.to_list()
      |> Enum.map(&to_string/1)

    # Only add indexer_ids if type is prowlarr
    type = params["type"]

    if type == "prowlarr" do
      Map.put(params, "indexer_ids", indexer_ids)
    else
      params
    end
  end

  ## Private Functions

  defp test_plex_connection(conn, token) do
    # Build URL directly from address/port to avoid plex.direct DNS issues in Docker
    protocol = conn.protocol || "https"
    address = conn.address
    port = conn.port

    # Use direct IP URL for testing
    test_url = "#{protocol}://#{address}:#{port}/identity"

    headers = [
      {"X-Plex-Token", token},
      {"Accept", "application/json"}
    ]

    Logger.info("Testing Plex connection: #{test_url}")

    # Req options for connection testing
    # Disable SSL verification since plex.direct certs don't match direct IPs
    opts = [
      headers: headers,
      receive_timeout: 5_000,
      pool_timeout: 5_000,
      retry: false,
      connect_options: [
        timeout: 3_000,
        transport_opts: [verify: :verify_none]
      ]
    ]

    case Req.get(test_url, opts) do
      {:ok, %{status: 200}} ->
        Logger.info("Plex connection OK: #{conn.uri}")
        :ok

      {:ok, %{status: status}} ->
        Logger.info("Plex connection failed HTTP #{status}: #{conn.uri}")
        :error

      {:error, error} ->
        Logger.info("Plex connection error: #{conn.uri} - #{inspect(error)}")
        :error
    end
  rescue
    e ->
      Logger.info("Plex connection exception: #{conn.uri} - #{inspect(e)}")
      :error
  end

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

    # Load media servers
    media_servers = Settings.list_media_server_configs()
    media_server_health = get_media_server_health_status(media_servers)

    # Load enabled library indexers if Cardigann feature is enabled
    cardigann_enabled = CardigannFeatureFlags.enabled?()

    library_indexers =
      if cardigann_enabled do
        Indexers.list_cardigann_definitions(enabled: true)
      else
        []
      end

    library_indexer_stats =
      if cardigann_enabled do
        Indexers.count_cardigann_definitions()
      else
        %{total: 0, enabled: 0, disabled: 0}
      end

    socket
    |> assign(:config, Settings.get_runtime_config())
    |> assign(:config_settings_with_sources, get_all_settings_with_sources())
    |> assign(:quality_profiles, Settings.list_quality_profiles())
    |> assign(:default_quality_profile_id, Settings.get_default_quality_profile_id())
    |> assign(:download_clients, download_clients)
    |> assign(:client_health, client_health)
    |> assign(:indexers, indexers)
    |> assign(:indexer_health, indexer_health)
    |> assign(:library_indexers, library_indexers)
    |> assign(:library_indexer_stats, library_indexer_stats)
    |> assign(:library_paths, Settings.list_library_paths())
    |> assign(:media_servers, media_servers)
    |> assign(:media_server_health, media_server_health)
    |> assign(:crash_report_stats, Mydia.CrashReporter.stats())
    |> assign(:queued_crash_reports, Mydia.CrashReporter.list_queued_reports())
    |> assign(:show_quality_profile_modal, false)
    |> assign(:show_delete_profile_modal, false)
    |> assign(:profile_to_delete, nil)
    |> assign(:affected_media_count, 0)
    |> assign(:show_download_client_modal, false)
    |> assign(:show_indexer_modal, false)
    |> assign(:show_library_path_modal, false)
    |> assign(:show_media_server_modal, false)
    |> assign(:show_manual_report_modal, false)
    |> assign(:show_import_modal, false)
    |> assign(:show_indexer_library_modal, false)
    |> assign(:show_library_config_modal, false)
    |> assign(:configuring_library_indexer, nil)
    |> assign(:library_indexer_settings, [])
    |> assign_new(:recently_disabled_indexer, fn -> nil end)
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

  defp get_media_server_health_status(media_servers) do
    # For now, we don't track health status actively (would require background polling)
    # Return unknown status for all servers - test connection is done on demand
    media_servers
    |> Enum.map(fn server -> {server.id, %{status: :unknown}} end)
    |> Map.new()
  end

  defp maybe_setup_form(socket, _tab) do
    # Setup forms for the active tab if needed
    socket
  end

  defp get_all_settings_with_sources do
    config = Settings.get_runtime_config()

    # In test environments, config might be a simple map. Use defaults if needed.
    config =
      if is_struct(config) do
        config
      else
        Mydia.Config.Schema.defaults()
      end

    # Ensure embedded schemas have defaults if nil (can happen with stale caches)
    flaresolverr = config.flaresolverr || %Mydia.Config.Schema.FlareSolverr{}

    # Group settings by category with their sources
    %{
      "Server" => [
        %{
          key: "server.port",
          label: "Port",
          type: :integer,
          value: config.server.port,
          source: get_source("PORT", "server.port")
        },
        %{
          key: "server.host",
          label: "Host",
          type: :string,
          value: config.server.host,
          source: get_source("HOST", "server.host")
        },
        %{
          key: "server.url_scheme",
          label: "URL Scheme",
          type: :string,
          value: config.server.url_scheme,
          source: get_source("URL_SCHEME", "server.url_scheme")
        },
        %{
          key: "server.url_host",
          label: "URL Host",
          type: :string,
          value: config.server.url_host,
          source: get_source("URL_HOST", "server.url_host")
        }
      ],
      "Database" => [
        %{
          key: "database.path",
          label: "Database Path",
          type: :string,
          value: config.database.path,
          source: get_source("DATABASE_PATH", "database.path")
        },
        %{
          key: "database.pool_size",
          label: "Pool Size",
          type: :integer,
          value: config.database.pool_size,
          source: get_source("POOL_SIZE", "database.pool_size")
        }
      ],
      "Authentication" => [
        %{
          key: "auth.local_enabled",
          label: "Local Auth Enabled",
          type: :boolean,
          value: config.auth.local_enabled,
          source: get_source("LOCAL_AUTH_ENABLED", "auth.local_enabled")
        },
        %{
          key: "auth.oidc_enabled",
          label: "OIDC Enabled",
          type: :boolean,
          value: config.auth.oidc_enabled,
          source: get_source("OIDC_ENABLED", "auth.oidc_enabled")
        }
      ],
      "Media" => [
        %{
          key: "media.movies_path",
          label: "Movies Path",
          type: :string,
          value: config.media.movies_path,
          source: get_source("MOVIES_PATH", "media.movies_path")
        },
        %{
          key: "media.tv_path",
          label: "TV Path",
          type: :string,
          value: config.media.tv_path,
          source: get_source("TV_PATH", "media.tv_path")
        },
        %{
          key: "media.scan_interval_hours",
          label: "Scan Interval (hours)",
          type: :integer,
          value: config.media.scan_interval_hours,
          source: get_source("MEDIA_SCAN_INTERVAL_HOURS", "media.scan_interval_hours")
        }
      ],
      "Downloads" => [
        %{
          key: "downloads.monitor_interval_minutes",
          label: "Monitor Interval (minutes)",
          type: :integer,
          value: config.downloads.monitor_interval_minutes,
          source:
            get_source("DOWNLOAD_MONITOR_INTERVAL_MINUTES", "downloads.monitor_interval_minutes")
        }
      ],
      "Crash Reporting" => [
        %{
          key: "crash_reporting.enabled",
          label: "Share Crashes with Developers",
          type: :boolean,
          value: get_crash_reporting_enabled(),
          source: get_source("CRASH_REPORTING_ENABLED", "crash_reporting.enabled")
        }
      ],
      "Library" => [
        %{
          key: "library.auto_repair_enabled",
          label: "Auto-Repair Database Issues",
          description:
            "Automatically queue a library re-scan on startup when database issues are detected",
          type: :boolean,
          value: get_library_auto_repair_enabled(),
          source: get_source("DATABASE_AUTO_REPAIR", "library.auto_repair_enabled")
        },
        %{
          key: "library.auto_repair_threshold",
          label: "Auto-Repair Threshold",
          description: "Minimum number of issues required to trigger auto-repair",
          type: :integer,
          value: get_library_auto_repair_threshold(),
          source: get_source("DATABASE_AUTO_REPAIR_THRESHOLD", "library.auto_repair_threshold")
        }
      ],
      "FlareSolverr" => [
        %{
          key: "flaresolverr.enabled",
          label: "Enabled",
          type: :boolean,
          value: flaresolverr.enabled,
          source: get_source("FLARESOLVERR_ENABLED", "flaresolverr.enabled")
        },
        %{
          key: "flaresolverr.url",
          label: "FlareSolverr URL",
          type: :string,
          value: flaresolverr.url || "",
          source: get_source("FLARESOLVERR_URL", "flaresolverr.url"),
          placeholder: "http://flaresolverr:8191"
        },
        %{
          key: "flaresolverr.timeout",
          label: "Timeout (ms)",
          type: :integer,
          value: flaresolverr.timeout,
          source: get_source("FLARESOLVERR_TIMEOUT", "flaresolverr.timeout")
        },
        %{
          key: "flaresolverr.max_timeout",
          label: "Max Timeout (ms)",
          type: :integer,
          value: flaresolverr.max_timeout,
          source: get_source("FLARESOLVERR_MAX_TIMEOUT", "flaresolverr.max_timeout")
        }
      ]
    }
  end

  defp get_crash_reporting_enabled do
    case Settings.get_config_setting_by_key("crash_reporting.enabled") do
      nil ->
        # Fall back to environment variable
        case Elixir.System.get_env("CRASH_REPORTING_ENABLED") do
          nil -> false
          value -> parse_boolean_value(value)
        end

      setting ->
        parse_boolean_value(setting.value)
    end
  end

  defp get_library_auto_repair_enabled do
    # Priority: ENV > Database > Application config > Default
    case Elixir.System.get_env("DATABASE_AUTO_REPAIR") do
      nil ->
        case Settings.get_config_setting_by_key("library.auto_repair_enabled") do
          nil ->
            Application.get_env(:mydia, :database_auto_repair, true)

          setting ->
            parse_boolean_value(setting.value)
        end

      value ->
        parse_boolean_value(value)
    end
  end

  defp get_library_auto_repair_threshold do
    # Priority: ENV > Database > Application config > Default
    case Elixir.System.get_env("DATABASE_AUTO_REPAIR_THRESHOLD") do
      nil ->
        case Settings.get_config_setting_by_key("library.auto_repair_threshold") do
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

  defp parse_boolean_value(value) when is_boolean(value), do: value
  defp parse_boolean_value("true"), do: true
  defp parse_boolean_value("1"), do: true
  defp parse_boolean_value("yes"), do: true
  defp parse_boolean_value(_), do: false

  defp get_source(env_var_name, key) do
    cond do
      # Check if set via environment variable (skip if env_var_name is nil)
      env_var_name != nil and Elixir.System.get_env(env_var_name) != nil ->
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

  defp validate_config_setting(attrs) do
    Logger.debug("validate_config_setting called with attrs: #{inspect(attrs)}")

    # Include category in types so it gets included in apply_changes result
    types = %{
      key: :string,
      value: :string,
      category: :string
    }

    # Category is already an atom from category_string_to_atom/1,
    # Convert it to string before casting to avoid issues
    attrs_with_string_category =
      case Map.get(attrs, :category) do
        nil ->
          Logger.error("Category is nil in attrs!")
          attrs

        category when is_atom(category) ->
          Logger.debug("Converting category atom to string: #{inspect(category)}")
          Map.put(attrs, :category, to_string(category))

        category ->
          Logger.debug("Category is already a string: #{inspect(category)}")
          attrs
      end

    changeset =
      {%{}, types}
      |> Ecto.Changeset.cast(attrs_with_string_category, Map.keys(types))

    Logger.debug("After cast, changeset.changes: #{inspect(changeset.changes)}")

    # Only require key and category to match ConfigSetting schema validation
    # Value is optional and can be nil/empty for some settings
    result =
      changeset
      |> Ecto.Changeset.validate_required([:key, :category])

    Logger.debug(
      "Validation result - valid?: #{result.valid?}, errors: #{inspect(result.errors)}"
    )

    result
  end

  defp category_string_to_atom(category_string) do
    case category_string do
      "Server" -> :server
      "Database" -> :general
      "Authentication" -> :auth
      "Media" -> :media
      "Downloads" -> :downloads
      "Crash Reporting" -> :crash_reporting
      "Notifications" -> :notifications
      "FlareSolverr" -> :flaresolverr
      "Library" -> :library
      _ -> :general
    end
  end

  defp upsert_config_setting(attrs) do
    # attrs is now a map from apply_changes, convert to map with atom keys if needed
    attrs_map = if is_struct(attrs), do: Map.from_struct(attrs), else: attrs

    # Ensure we're accessing the key correctly (might be atom or string key)
    key = Map.get(attrs_map, :key) || Map.get(attrs_map, "key")

    # Convert atom keys to string keys for Ecto.Changeset.cast/3
    # Category is already a string from validate_config_setting
    string_attrs = %{
      "key" => Map.get(attrs_map, :key),
      "value" => Map.get(attrs_map, :value),
      "category" => Map.get(attrs_map, :category),
      "updated_by_id" => Map.get(attrs_map, :updated_by_id)
    }

    # Debug logging
    Logger.debug("Upserting config setting: key=#{inspect(key)}, attrs=#{inspect(string_attrs)}")

    case Settings.get_config_setting_by_key(key) do
      nil ->
        result = Settings.create_config_setting(string_attrs)
        Logger.debug("Create result: #{inspect(result)}")
        result

      existing ->
        result = Settings.update_config_setting(existing, string_attrs)
        Logger.debug("Update result: #{inspect(result)}")
        result
    end
  end

  # Transforms quality profile form params to match the schema structure
  defp transform_quality_profile_params(params) do
    # Handle qualities array - if empty or nil, set to empty list to satisfy validation
    qualities =
      case params["qualities"] do
        nil -> []
        [] -> []
        list when is_list(list) -> list
        _ -> []
      end

    # Extract and transform quality_standards
    # Only include if there's actual data (not nil/empty) to avoid overwriting existing data
    quality_standards =
      if params["quality_standards"] do
        transform_quality_standards(params["quality_standards"])
      else
        nil
      end

    # Build the final params map, excluding nil quality_standards to preserve existing data
    base_params = %{
      "name" => params["name"],
      "description" => params["description"],
      "qualities" => qualities
    }

    # Only include quality_standards if it has actual data
    if quality_standards do
      Map.put(base_params, "quality_standards", quality_standards)
    else
      base_params
    end
  end

  defp transform_quality_standards(standards) when is_map(standards) do
    standards
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case transform_quality_standard_value(key, value) do
        nil ->
          acc

        # Convert string keys to atoms for consistency with how templates access them
        transformed_value ->
          atom_key = if is_binary(key), do: String.to_atom(key), else: key
          Map.put(acc, atom_key, transformed_value)
      end
    end)
    |> case do
      empty when empty == %{} -> nil
      non_empty -> non_empty
    end
  end

  defp transform_quality_standard_value(_key, ""), do: nil
  defp transform_quality_standard_value(_key, nil), do: nil

  defp transform_quality_standard_value(key, value)
       when key in [
              "min_video_bitrate_mbps",
              "max_video_bitrate_mbps",
              "preferred_video_bitrate_mbps"
            ] do
    case Float.parse(value) do
      {float, ""} -> float
      _ -> nil
    end
  end

  defp transform_quality_standard_value(key, value)
       when key in [
              "min_audio_bitrate_kbps",
              "max_audio_bitrate_kbps",
              "preferred_audio_bitrate_kbps",
              "movie_min_size_mb",
              "movie_max_size_mb",
              "episode_min_size_mb",
              "episode_max_size_mb"
            ] do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp transform_quality_standard_value(key, value)
       when key in [
              "preferred_video_codecs",
              "preferred_audio_codecs",
              "preferred_audio_channels",
              "preferred_resolutions",
              "preferred_sources",
              "hdr_formats"
            ] do
    case value do
      list when is_list(list) -> list
      str when is_binary(str) -> String.split(str, ",") |> Enum.map(&String.trim/1)
      _ -> nil
    end
  end

  defp transform_quality_standard_value("require_hdr", value) do
    value == "true" || value == true
  end

  defp transform_quality_standard_value(_key, value), do: value

  # Helper function for export MIME types
  defp get_export_mime_type(:json), do: "application/json"
  defp get_export_mime_type(:yaml), do: "application/x-yaml"
  defp get_export_mime_type(_), do: "application/octet-stream"

  # System Status Functions (consolidated from AdminStatusLive)

  defp load_system_data(socket) do
    socket
    |> assign(:database_info, get_database_info())
    |> assign(:system_info, get_system_info())
  end

  defp check_flaresolverr_async(socket) do
    if connected?(socket) do
      Task.async(fn ->
        {:flaresolverr_status, FlareSolverrStatusComponent.get_status()}
      end)
    end

    socket
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

    # Get database size from PostgreSQL
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
    # In test environment, consider the database healthy if a connection exists
    # This avoids issues with SQL sandbox in LiveView processes
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

  defp format_changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, errors} ->
      "#{field}: #{Enum.join(errors, ", ")}"
    end)
    |> Enum.join("; ")
  end

  defp remote_access_enabled? do
    Application.get_env(:mydia, :features, [])
    |> Keyword.get(:remote_access_enabled, false)
  end
end
