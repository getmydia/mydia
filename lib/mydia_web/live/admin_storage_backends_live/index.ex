defmodule MydiaWeb.AdminStorageBackendsLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.Settings
  alias Mydia.Settings.StorageBackend
  alias Mydia.Storage

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Configuration - Storage")
     |> assign(:form, nil)
     |> assign(:mode, :new)
     |> assign(:editing, nil)
     |> assign(:testing, MapSet.new())
     |> load_backends()}
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, open_form(socket, :new, %StorageBackend{})}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case find_editable(socket, id) do
      {:ok, backend} -> {:noreply, open_form(socket, :edit, backend)}
      :error -> {:noreply, put_flash(socket, :error, "That storage backend cannot be edited")}
    end
  end

  def handle_event("close", _params, socket), do: {:noreply, close_form(socket)}

  def handle_event("validate", %{"storage_backend" => params}, socket) do
    changeset =
      socket.assigns.editing
      |> Settings.change_storage_backend(clean_params(socket, params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"storage_backend" => params}, socket) do
    params = clean_params(socket, params)

    result =
      case socket.assigns.mode do
        :new -> Settings.create_storage_backend(params)
        :edit -> Settings.update_storage_backend(socket.assigns.editing, params)
      end

    case result do
      {:ok, backend} ->
        {:noreply,
         socket
         |> close_form()
         |> load_backends()
         |> put_flash(:info, "Storage backend #{backend.name} saved")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case find_editable(socket, id) do
      {:ok, backend} ->
        {:ok, _} = Settings.delete_storage_backend(backend)

        {:noreply,
         socket
         |> load_backends()
         |> put_flash(:info, "Storage backend #{backend.name} deleted")}

      :error ->
        {:noreply, put_flash(socket, :error, "That storage backend cannot be deleted")}
    end
  end

  def handle_event("test", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.backends, &(&1.id == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "That storage backend no longer exists")}

      %StorageBackend{name: name} = backend ->
        # A dead endpoint takes several seconds to give up; never block the page on it.
        {:noreply,
         socket
         |> update(:testing, &MapSet.put(&1, name))
         |> start_async({:test, name}, fn -> Storage.test_connection(backend) end)}
    end
  end

  @impl true
  def handle_async({:test, name}, {:ok, result}, socket) do
    flash =
      case result do
        :ok -> {:info, "#{name}: connected"}
        {:error, %Mydia.Storage.Error{message: message}} -> {:error, "#{name}: #{message}"}
      end

    {:noreply, finish_test(socket, name, flash)}
  end

  def handle_async({:test, name}, {:exit, _reason}, socket) do
    {:noreply, finish_test(socket, name, {:error, "#{name}: the connection test crashed"})}
  end

  defp finish_test(socket, name, {kind, message}) do
    socket
    |> update(:testing, &MapSet.delete(&1, name))
    |> put_flash(kind, message)
  end

  defp load_backends(socket), do: assign(socket, :backends, Settings.list_storage_backends())

  # Runtime (env/YAML) rows have no database row to change.
  defp find_editable(socket, id) do
    case Enum.find(socket.assigns.backends, &(&1.id == id)) do
      %StorageBackend{} = backend ->
        if Settings.RuntimeConfig.runtime_config?(backend),
          do: :error,
          else: {:ok, backend}

      nil ->
        :error
    end
  end

  defp open_form(socket, mode, backend) do
    socket
    |> assign(:mode, mode)
    |> assign(:editing, backend)
    |> assign(:form, to_form(Settings.change_storage_backend(backend)))
  end

  defp close_form(socket) do
    socket |> assign(:form, nil) |> assign(:editing, nil)
  end

  # On edit a blank secret means "keep the stored one".
  defp clean_params(%{assigns: %{mode: :edit}}, %{"secret_access_key" => ""} = params),
    do: Map.delete(params, "secret_access_key")

  defp clean_params(_socket, params), do: params
end
