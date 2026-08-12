defmodule MydiaWeb.AdminSubtitleProvidersLive do
  use MydiaWeb, :live_view

  alias Mydia.Settings
  alias Mydia.Settings.ServiceConfigs
  alias Mydia.Settings.SubtitleProviderConfig
  alias Mydia.Subtitles.Health
  alias Mydia.Subtitles.ProviderRegistry

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Configuration - Subtitle Providers")
     |> assign(:active_tab, :subtitle_providers)
     |> load_data()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("new_subtitle_provider", _params, socket) do
    changeset = SubtitleProviderConfig.changeset(%SubtitleProviderConfig{}, %{})

    {:noreply,
     socket
     |> assign(:show_modal, true)
     |> assign(:form, to_form(changeset))
     |> assign(:mode, :new)
     |> assign(:editing, nil)}
  end

  @impl true
  def handle_event("edit_subtitle_provider", %{"id" => id}, socket) do
    config = Enum.find(socket.assigns.providers, &(&1.id == id))

    cond do
      is_nil(config) ->
        {:noreply, put_flash(socket, :error, "Provider not found")}

      registry_config?(config) ->
        # Registry rows have no database row. Prefill the form and create on save.
        attrs = %{
          "name" => config.name,
          "type" => to_string(config.type),
          "enabled" => config.enabled,
          "priority" => config.priority,
          "api_key" => config.api_key,
          "username" => config.username,
          "password" => config.password
        }

        changeset = SubtitleProviderConfig.changeset(%SubtitleProviderConfig{}, attrs)

        {:noreply,
         socket
         |> assign(:show_modal, true)
         |> assign(:form, to_form(changeset))
         |> assign(:mode, :new)
         |> assign(:editing, nil)
         |> put_flash(
           :info,
           "Saving will create a database-managed configuration for this provider"
         )}

      Settings.runtime_config?(config) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Cannot edit a runtime-configured provider. Configure it in the database instead."
         )}

      true ->
        changeset = SubtitleProviderConfig.changeset(config, %{})

        {:noreply,
         socket
         |> assign(:show_modal, true)
         |> assign(:form, to_form(changeset))
         |> assign(:mode, :edit)
         |> assign(:editing, config)}
    end
  end

  @impl true
  def handle_event("validate_subtitle_provider", %{"subtitle_provider_config" => params}, socket) do
    config =
      case socket.assigns.mode do
        :new -> %SubtitleProviderConfig{}
        :edit -> socket.assigns.editing
      end

    changeset =
      config
      |> SubtitleProviderConfig.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  @impl true
  def handle_event("save_subtitle_provider", %{"subtitle_provider_config" => params}, socket) do
    result =
      case socket.assigns.mode do
        :new -> ServiceConfigs.create_subtitle_provider_config(params)
        :edit -> ServiceConfigs.update_subtitle_provider_config(socket.assigns.editing, params)
      end

    case result do
      {:ok, _config} ->
        {:noreply,
         socket
         |> assign(:show_modal, false)
         |> put_flash(:info, "Subtitle provider saved successfully")
         |> load_data()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("close_subtitle_provider_modal", _params, socket) do
    {:noreply, assign(socket, :show_modal, false)}
  end

  @impl true
  def handle_event("toggle_subtitle_provider", %{"id" => id}, socket) do
    config = Enum.find(socket.assigns.providers, &(&1.id == id))

    cond do
      is_nil(config) ->
        {:noreply, put_flash(socket, :error, "Provider not found")}

      registry_config?(config) ->
        attrs = %{
          name: config.name,
          type: config.type,
          enabled: !config.enabled,
          priority: config.priority
        }

        case ServiceConfigs.create_subtitle_provider_config(attrs) do
          {:ok, _created} ->
            {:noreply, load_data(socket)}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to update provider")}
        end

      Settings.runtime_config?(config) ->
        {:noreply,
         put_flash(socket, :error, "Cannot toggle a runtime-configured provider from the UI")}

      true ->
        case ServiceConfigs.update_subtitle_provider_config(config, %{enabled: !config.enabled}) do
          {:ok, _updated} ->
            {:noreply, load_data(socket)}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to update provider")}
        end
    end
  end

  @impl true
  def handle_event("test_subtitle_provider", %{"id" => id}, socket) do
    config = Enum.find(socket.assigns.providers, &(&1.id == id))

    if is_nil(config) do
      {:noreply, put_flash(socket, :error, "Provider not found")}
    else
      adapter = ProviderRegistry.adapter_for(config)

      case adapter.validate_config(config) do
        {:ok, _config} ->
          {:noreply, put_flash(socket, :info, "Provider configuration is valid")}

        {:error, message} when is_binary(message) ->
          {:noreply, put_flash(socket, :error, message)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Validation failed: #{inspect(reason)}")}
      end
    end
  end

  @impl true
  def handle_event("delete_subtitle_provider", %{"id" => id}, socket) do
    config = Enum.find(socket.assigns.providers, &(&1.id == id))

    cond do
      is_nil(config) ->
        {:noreply, put_flash(socket, :error, "Provider not found")}

      registry_config?(config) or Settings.runtime_config?(config) ->
        {:noreply, put_flash(socket, :error, "Cannot delete a built-in or runtime provider")}

      true ->
        case ServiceConfigs.delete_subtitle_provider_config(config) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Subtitle provider deleted")
             |> load_data()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete provider")}
        end
    end
  end

  defp load_data(socket) do
    providers = ServiceConfigs.list_subtitle_provider_configs()

    circuit =
      Map.new(providers, fn provider ->
        {provider.id, Health.available?(provider.type)}
      end)

    socket
    |> assign(:providers, providers)
    |> assign(:circuit, circuit)
    |> assign(:show_modal, false)
    |> assign_new(:form, fn ->
      to_form(SubtitleProviderConfig.changeset(%SubtitleProviderConfig{}, %{}))
    end)
    |> assign_new(:mode, fn -> :new end)
    |> assign_new(:editing, fn -> nil end)
  end

  defp registry_config?(%{id: id}) when is_binary(id), do: String.starts_with?(id, "registry::")
  defp registry_config?(_), do: false
end
