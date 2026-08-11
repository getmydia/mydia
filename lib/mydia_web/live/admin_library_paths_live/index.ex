defmodule MydiaWeb.AdminLibraryPathsLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.Settings
  alias Mydia.Settings.LibraryPath

  require Logger
  alias Mydia.Logger, as: MydiaLogger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mydia.PubSub, "library_scanner")
    end

    {:ok,
     socket
     |> assign(:page_title, "Configuration - Library Paths")
     |> assign(:active_tab, :library_paths)
     |> assign(:reorganizing_library_ids, MapSet.new())
     |> assign(:reclassifying_library_ids, MapSet.new())
     |> load_data()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  ## PubSub handlers

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

  # Ignore other library scan messages
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
    library_path =
      case socket.assigns.library_path_mode do
        :new -> %LibraryPath{}
        :edit -> socket.assigns.editing_library_path
      end

    changeset = LibraryPath.changeset(library_path, params)

    if changeset.valid? do
      validated_data = Ecto.Changeset.apply_changes(changeset)

      case validate_directory(validated_data.path) do
        :ok ->
          save_params = strip_new_default_flags(params, library_path)

          result =
            case socket.assigns.library_path_mode do
              :new ->
                with {:ok, path} <- Settings.create_library_path(save_params) do
                  apply_default_flags(path, params)
                end

              :edit ->
                with {:ok, path} <-
                       Settings.update_library_path(
                         socket.assigns.editing_library_path,
                         save_params
                       ) do
                  apply_default_flags(path, params)
                end
            end

          case result do
            {:ok, _path} ->
              {:noreply,
               socket
               |> assign(:show_library_path_modal, false)
               |> put_flash(:info, "Library path saved successfully")
               |> load_data()}

            {:error, %Ecto.Changeset{} = changeset} ->
              {:noreply, assign(socket, :library_path_form, to_form(changeset))}

            {:error, :incompatible_type} ->
              {:noreply,
               put_flash(socket, :error, "Library type cannot serve as default for that kind")}
          end

        {:error, reason} ->
          changeset = Ecto.Changeset.add_error(changeset, :path, reason)

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
         |> load_data()}

      {:error, error} ->
        MydiaLogger.log_error(:liveview, "Failed to delete library path",
          error: error,
          operation: :delete_library_path,
          path_id: id,
          path: path.path,
          user_id: socket.assigns.current_user.id
        )

        error_msg = MydiaLogger.user_error_message(:delete_library_path, error)

        {:noreply, put_flash(socket, :error, error_msg)}
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

  ## Private Helpers

  defp strip_new_default_flags(params, library_path) do
    Enum.reduce(["default_for_movies", "default_for_series"], params, fn key, acc ->
      field = String.to_existing_atom(key)
      already? = Map.fetch!(library_path, field) == true

      if acc[key] in ["true", true] and not already? do
        Map.delete(acc, key)
      else
        acc
      end
    end)
  end

  defp apply_default_flags(library_path, params) do
    Enum.reduce_while(
      [{:movies, "default_for_movies"}, {:series, "default_for_series"}],
      {:ok, library_path},
      fn
        {kind, param_key}, {:ok, acc} ->
          if params[param_key] in ["true", true] and
               not Map.fetch!(acc, String.to_existing_atom(param_key)) do
            case Settings.set_default_library(acc, kind) do
              {:ok, updated} -> {:cont, {:ok, updated}}
              error -> {:halt, error}
            end
          else
            {:cont, {:ok, acc}}
          end
      end
    )
  end

  defp load_data(socket) do
    socket
    |> assign(:library_paths, Settings.list_library_paths())
    |> assign(:show_library_path_modal, false)
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
        case File.ls(path) do
          {:ok, _} -> :ok
          {:error, :eacces} -> {:error, "directory is not accessible (permission denied)"}
          {:error, reason} -> {:error, "cannot read directory: #{reason}"}
        end
    end
  end
end
