defmodule MydiaWeb.ImportMediaLive.Index do
  @moduledoc """
  Import Media: start a run, watch it, stop it, and work the inbox it leaves.

  There is no wizard and no session state. The run lives in Oban and the inbox
  is a live query, so this LiveView holds no import progress of its own beyond
  what it reads back.
  """
  use MydiaWeb, :live_view

  alias Mydia.{Library, Settings}
  alias Mydia.Jobs.ImportRun, as: ImportRunJob
  alias MydiaWeb.Live.Authorization
  alias MydiaWeb.ImportMediaLive.RunControl

  @impl true
  def mount(_params, _session, socket) do
    library_paths = Settings.list_library_paths()
    active_run = Enum.find_value(library_paths, &Library.active_import_run(&1.id))

    # No run in flight: fall back to the most recent one so a finished,
    # failed, or stopped run stays visible after a reload instead of the
    # panel silently reverting to a blank start form. active_import_run/1
    # itself stays untouched -- Task 6's coordinator and Task 2's uniqueness
    # guard both depend on it excluding terminal states.
    outcome_run =
      if active_run do
        nil
      else
        Enum.find_value(library_paths, &Library.last_import_run(&1.id))
      end

    run_to_watch = active_run || outcome_run

    if connected?(socket) and run_to_watch do
      Phoenix.PubSub.subscribe(Mydia.PubSub, ImportRunJob.progress_topic(run_to_watch.id))
    end

    {:ok,
     socket
     |> assign(:page_title, "Import Media")
     |> assign(:library_paths, library_paths)
     |> assign(:active_run, active_run)
     |> assign(:outcome_run, outcome_run)}
  end

  @impl true
  def handle_event("start_run", %{"library_path_id" => path_id, "mode" => mode}, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      attrs = %{
        library_path_id: path_id,
        user_id: socket.assigns.current_user.id,
        mode: String.to_existing_atom(mode)
      }

      case Library.create_import_run(attrs) do
        {:ok, run} ->
          %{"import_run_id" => run.id}
          |> ImportRunJob.new()
          |> Oban.insert!()

          if connected?(socket) do
            Phoenix.PubSub.subscribe(Mydia.PubSub, ImportRunJob.progress_topic(run.id))
          end

          {:noreply,
           socket
           |> assign(:active_run, run)
           |> assign(:outcome_run, nil)}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "That library is already being imported.")}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("stop_run", _params, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      case socket.assigns.active_run do
        nil ->
          {:noreply, socket}

        run ->
          {:ok, stopping} = Library.request_import_run_stop(Library.get_import_run(run.id))
          {:noreply, assign(socket, :active_run, stopping)}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:import_run_progress, run}, socket) do
    socket =
      if run.status in [:running, :stopping] do
        assign(socket, :active_run, run)
      else
        # Terminal: don't just clear the panel. Keep the run visible as an
        # outcome so a user who walked away comes back to "it finished" /
        # "it failed" / "it stopped", not a blank start form that looks like
        # nothing ever happened.
        socket
        |> assign(:active_run, nil)
        |> assign(:outcome_run, run)
      end

    {:noreply, socket}
  end

  def handle_info({:import_run_current_file, name}, socket) do
    case socket.assigns.active_run do
      nil -> {:noreply, socket}
      run -> {:noreply, assign(socket, :active_run, %{run | current_file: name})}
    end
  end
end
