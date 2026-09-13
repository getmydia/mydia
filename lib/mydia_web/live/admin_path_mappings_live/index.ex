defmodule MydiaWeb.AdminPathMappingsLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.Downloads
  alias Mydia.Library.DirectoryBrowser
  alias Mydia.Settings
  alias Mydia.Settings.PathMappingConfig

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Configuration - Path Mappings")
     |> load_data()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("new_path_mapping", _params, socket) do
    changeset = PathMappingConfig.changeset(%PathMappingConfig{}, %{})

    {:noreply,
     socket
     |> assign(:show_modal, true)
     |> assign(:mode, :new)
     |> assign(:editing, nil)
     |> assign(:remote_suggestions, Downloads.list_failed_remote_paths())
     |> assign(:local_suggestions, [])
     |> assign(:form, to_form(changeset))}
  end

  @impl true
  def handle_event("edit_path_mapping", %{"id" => id}, socket) do
    mapping = Settings.get_path_mapping_config!(id)

    if Settings.runtime_config?(mapping) do
      {:noreply, put_flash(socket, :error, env_readonly_message())}
    else
      changeset = PathMappingConfig.changeset(mapping, %{})

      {:noreply,
       socket
       |> assign(:show_modal, true)
       |> assign(:mode, :edit)
       |> assign(:editing, mapping)
       |> assign(:remote_suggestions, Downloads.list_failed_remote_paths())
       |> assign(:local_suggestions, DirectoryBrowser.suggest(mapping.local_prefix))
       |> assign(:form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("validate_path_mapping", %{"path_mapping_config" => params}, socket) do
    base =
      case socket.assigns.mode do
        :new -> %PathMappingConfig{}
        :edit -> socket.assigns.editing
      end

    changeset =
      base
      |> PathMappingConfig.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset))
     |> assign(:local_suggestions, DirectoryBrowser.suggest(params["local_prefix"]))}
  end

  @impl true
  def handle_event("save_path_mapping", %{"path_mapping_config" => params}, socket) do
    result =
      case socket.assigns.mode do
        :new -> Settings.create_path_mapping_config(params)
        :edit -> Settings.update_path_mapping_config(socket.assigns.editing, params)
      end

    case result do
      {:ok, _mapping} ->
        {:noreply,
         socket
         |> assign(:show_modal, false)
         |> put_flash(:info, "Path mapping saved")
         |> load_data()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("delete_path_mapping", %{"id" => id}, socket) do
    mapping = Settings.get_path_mapping_config!(id)

    if Settings.runtime_config?(mapping) do
      {:noreply, put_flash(socket, :error, env_readonly_message())}
    else
      case Settings.delete_path_mapping_config(mapping) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Path mapping deleted")
           |> load_data()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete path mapping")}
      end
    end
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :show_modal, false)}
  end

  defp load_data(socket) do
    socket
    |> assign(:path_mappings, Settings.list_path_mapping_configs())
    |> assign(:show_modal, false)
    |> assign(:remote_suggestions, [])
    |> assign(:local_suggestions, [])
  end

  defp env_readonly_message do
    "This mapping is configured via environment variables and is read-only in the UI."
  end
end
