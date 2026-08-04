defmodule MydiaWeb.AdminQualityProfilesLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.Settings
  alias Mydia.Settings.QualityProfile

  require Logger
  alias Mydia.Logger, as: MydiaLogger

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Configuration - Quality Profiles")
     |> assign(:active_tab, :quality)
     |> load_data()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  ## Quality Profile Events

  @impl true
  def handle_event("update_default_quality_profile", params, socket) do
    profile_id = params["profile_id"]
    profile_id = if profile_id == "", do: nil, else: profile_id

    case Settings.set_default_quality_profile(profile_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Default quality profile updated")
         |> assign(:default_quality_profile_id, profile_id)}

      {:error, reason} ->
        MydiaLogger.log_error(:liveview, "Failed to update default quality profile",
          error: reason,
          operation: :update_default_quality_profile,
          profile_id: profile_id,
          user_id: socket.assigns.current_user.id
        )

        {:noreply, put_flash(socket, :error, "Failed to update default quality profile")}
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

    transformed_params = transform_quality_profile_params(params)

    changeset =
      profile
      |> Settings.change_quality_profile(transformed_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :quality_profile_form, to_form(changeset))}
  end

  @impl true
  def handle_event("save_quality_profile", %{"quality_profile" => params}, socket) do
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
         |> load_data()}

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
         |> load_data()}

      {:error, changeset} ->
        MydiaLogger.log_error(:liveview, "Failed to clone quality profile",
          error: changeset,
          operation: :duplicate_quality_profile,
          profile_id: id,
          user_id: socket.assigns.current_user.id
        )

        error_msg = MydiaLogger.user_error_message(:duplicate_quality_profile, changeset)
        {:noreply, put_flash(socket, :error, error_msg)}
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
         |> load_data()}

      {:error, :profile_in_use} ->
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
        {:noreply, put_flash(socket, :error, error_msg)}
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
         |> load_data()}

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
        {:noreply,
         socket
         |> push_event("download_file", %{
           content: content,
           filename: "#{profile.name}.#{format}",
           mime_type: get_export_mime_type(format_atom)
         })}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Export failed: #{reason}")}
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
         |> load_data()}

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

        {:noreply, assign(socket, :import_error, error_msg)}
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
        case Settings.create_quality_profile(preset.profile_data) do
          {:ok, _profile} ->
            {:noreply,
             socket
             |> put_flash(:info, "Preset \"#{preset.name}\" imported successfully")
             |> assign(:show_browse_presets_modal, false)
             |> load_data()}

          {:error, changeset} ->
            errors = format_changeset_errors(changeset)
            {:noreply, put_flash(socket, :error, "Failed to import preset: #{errors}")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Preset not found")}
    end
  end

  ## Private Helpers

  defp load_data(socket) do
    socket
    |> assign(:quality_profiles, Settings.list_quality_profiles())
    |> assign(:default_quality_profile_id, Settings.get_default_quality_profile_id())
    |> assign(:show_quality_profile_modal, false)
    |> assign(:show_delete_profile_modal, false)
    |> assign(:profile_to_delete, nil)
    |> assign(:affected_media_count, 0)
    |> assign(:show_import_modal, false)
    |> assign(:show_browse_presets_modal, false)
  end

  defp transform_quality_profile_params(params) do
    quality_standards =
      if params["quality_standards"] do
        transform_quality_standards(params["quality_standards"])
      else
        nil
      end

    base_params = %{
      "name" => params["name"],
      "description" => params["description"],
      "upgrades_allowed" => params["upgrades_allowed"],
      "upgrade_until_score" => params["upgrade_until_score"],
      "min_upgrade_margin" => params["min_upgrade_margin"]
    }

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

  defp transform_quality_standard_value("min_ratio", value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {float, ""} -> float
      _ -> nil
    end
  end

  defp transform_quality_standard_value(key, value)
       when key in [
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
              "excluded_sources",
              "hdr_formats"
            ] do
    case value do
      list when is_list(list) -> Enum.reject(list, &(&1 == ""))
      str when is_binary(str) -> String.split(str, ",") |> Enum.map(&String.trim/1)
      _ -> nil
    end
  end

  defp transform_quality_standard_value("require_hdr", value) do
    value == "true" || value == true
  end

  defp transform_quality_standard_value(_key, value), do: value

  defp get_export_mime_type(:json), do: "application/json"
  defp get_export_mime_type(:yaml), do: "application/x-yaml"
  defp get_export_mime_type(_), do: "application/octet-stream"

  defp format_changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} ->
      "#{field}: #{Enum.join(errors, ", ")}"
    end)
  end
end
