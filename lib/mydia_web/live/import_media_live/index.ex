defmodule MydiaWeb.ImportMediaLive.Index do
  @moduledoc """
  Import Media: start a run, watch it, stop it.

  There is no wizard and no session state. The run lives in Oban, so this
  LiveView holds no import progress of its own beyond what it reads back.
  """
  use MydiaWeb, :live_view

  alias Mydia.{Library, Settings}
  alias Mydia.Jobs.ImportRun, as: ImportRunJob
  alias Mydia.Library.ImportRun
  alias MydiaWeb.Live.Authorization
  alias MydiaWeb.ImportMediaLive.RunControl

  # Everything a client can name is mapped from an explicit table rather than
  # converted. `String.to_existing_atom/1` and `String.to_integer/1` both raise
  # on anything unexpected, and a raise inside a handler takes the LiveView
  # process down: a tab left open across a deploy, a replayed event, or a
  # crafted one would close the page instead of getting an answer back.
  @modes %{"review" => :review, "unattended" => :unattended}

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
     # The start form offers only what the coordinator can actually import.
     # `@library_paths` deliberately keeps every path so a run left on a
     # music path by an older build is still found, shown, and stoppable.
     |> assign(:importable_library_paths, Enum.filter(library_paths, &importable?/1))
     |> assign(:active_run, active_run)
     |> assign(:outcome_run, outcome_run)
     |> assign(:outcome_inbox_count, inbox_count_for_outcome(outcome_run))}
  end

  @impl true
  def handle_event("start_run", %{"library_path_id" => path_id, "mode" => mode}, socket) do
    with :ok <- Authorization.authorize_import_media(socket),
         :ok <- authorize_library_path(socket, path_id),
         {:ok, mode} <- Map.fetch(@modes, mode) do
      attrs = %{
        library_path_id: path_id,
        user_id: socket.assigns.current_user.id,
        mode: mode
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
           |> assign(:outcome_run, nil)
           |> assign(:outcome_inbox_count, 0)}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "That library is already being imported.")}
      end
    else
      {:unauthorized, socket} ->
        {:noreply, socket}

      {:unsupported_type, socket} ->
        {:noreply, socket}

      # Map.fetch/2 on an unknown mode. Only reachable from a stale or crafted
      # form, so the sentence is deliberately vague rather than echoing back
      # whatever string arrived.
      :error ->
        {:noreply, put_flash(socket, :error, "That import mode is not available.")}
    end
  end

  def handle_event("stop_run", _params, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      case socket.assigns.active_run do
        nil ->
          {:noreply, socket}

        run ->
          case Library.request_import_run_stop(run.id) do
            {:ok, stopping} ->
              {:noreply, assign(socket, :active_run, stopping)}

            # The run reached a terminal state between this page rendering and
            # the click landing. Show what it actually did rather than forcing
            # it back into an active status nothing would ever advance.
            {:error, _changeset} ->
              {:noreply, show_outcome(socket, Library.get_import_run(run.id))}
          end
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
        |> assign(:outcome_inbox_count, inbox_count_for_outcome(run))
      end

    {:noreply, socket}
  end

  def handle_info({:import_run_current_file, name}, socket) do
    case socket.assigns.active_run do
      nil -> {:noreply, socket}
      run -> {:noreply, assign(socket, :active_run, %{run | current_file: name})}
    end
  end

  defp importable?(library_path), do: ImportRun.importable_type?(library_path.type)

  # The start form only lists importable paths, but a stale bookmark or a
  # crafted event can still name any id. `run_scan_phase/2` refuses the same
  # set; this layer only exists so the user gets a sentence instead of a run
  # that starts and immediately fails.
  defp authorize_library_path(socket, path_id) do
    if Enum.any?(socket.assigns.importable_library_paths, &(&1.id == path_id)) do
      :ok
    else
      {:unsupported_type,
       put_flash(socket, :error, "Only movie, TV and mixed libraries can be imported.")}
    end
  end

  # A terminal run stays on screen as an outcome rather than reverting the
  # panel to a blank start form, matching what mount/3 does after a reload.
  defp show_outcome(socket, run) do
    socket
    |> assign(:active_run, nil)
    |> assign(:outcome_run, run)
    |> assign(:outcome_inbox_count, inbox_count_for_outcome(run))
  end

  # Queries the inbox count once when a run reaches a terminal state so the
  # outcome_review_cta component never calls the DB directly from its body.
  defp inbox_count_for_outcome(nil), do: 0

  defp inbox_count_for_outcome(run) do
    Library.count_inbox_files(library_path_id: run.library_path_id)
  end
end
