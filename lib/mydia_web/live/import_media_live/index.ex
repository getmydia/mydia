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
  alias Mydia.Library.FileIngest
  alias MydiaWeb.Live.Authorization
  alias MydiaWeb.ImportMediaLive.{Inbox, RunControl}

  # The inbox is a single global queue across every library path (matching
  # how @active_run/@outcome_run already treat "the import run" as one thing
  # rather than one per path), paged at a fixed size rather than a
  # user-configurable one -- there is no UI for changing it yet.
  @inbox_page_size 100

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
     |> assign(:outcome_run, outcome_run)
     |> assign(:inbox_filter, :all)
     |> assign(:inbox_offset, 0)
     |> assign(:inbox_limit, @inbox_page_size)
     # A row is `%{media_file:, candidate:}`, not a struct with its own :id --
     # stream/3 needs to be told how to derive a DOM id from that shape.
     |> stream_configure(:inbox_rows, dom_id: &"inbox-row-#{&1.media_file.id}")
     |> load_inbox()}
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

  def handle_event("filter_inbox", %{"filter" => filter}, socket) do
    {:noreply,
     socket
     |> assign(:inbox_filter, String.to_existing_atom(filter))
     |> assign(:inbox_offset, 0)
     |> load_inbox()}
  end

  def handle_event("inbox_page", %{"offset" => offset}, socket) do
    {:noreply,
     socket
     |> assign(:inbox_offset, String.to_integer(offset))
     |> load_inbox()}
  end

  def handle_event("approve_file", %{"id" => media_file_id}, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      media_file = Library.get_media_file!(media_file_id)

      case Library.list_match_candidates(media_file_id) do
        [%{provider_id: provider_id} = candidate | _] when not is_nil(provider_id) ->
          match = candidate_to_match(candidate)

          case FileIngest.ingest(media_file, match, policy: :create_items, threshold: 0.0) do
            {:linked, _media_item} ->
              {:noreply,
               socket
               |> put_flash(:info, "Added #{candidate.title}")
               |> load_inbox()}

            _ ->
              {:noreply, put_flash(socket, :error, "Could not add #{candidate.title}")}
          end

        _ ->
          {:noreply, put_flash(socket, :error, "That file has no match to add yet.")}
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

  # threshold: 0.0 below is deliberate. A human pressed Add, so their
  # judgement replaces the confidence gate rather than being second-guessed
  # by it -- the same reasoning FileIngest.default_threshold/0 documents for
  # unattended mode, inverted: a person is standing in for the gate here.
  defp candidate_to_match(candidate) do
    %{
      provider_id: candidate.provider_id,
      provider_type: String.to_existing_atom(candidate.provider_type || "tmdb"),
      title: candidate.title,
      year: candidate.year,
      match_confidence: candidate.confidence || 1.0,
      metadata: %{},
      manually_edited: true,
      parsed_info: restore_parsed_info(candidate)
    }
  end

  defp restore_parsed_info(candidate) do
    parsed = candidate.parsed_info || %{}

    %{
      type: String.to_existing_atom(candidate.media_type || "movie"),
      season: Map.get(parsed, "season"),
      episodes: Map.get(parsed, "episodes") || []
    }
  end

  # The inbox is a live query, not socket state: every mutation that can
  # change it (approving a row, changing the filter, paging) reloads from the
  # database rather than patching @streams.inbox_rows by hand, so it can
  # never drift from what a fresh page load would show.
  defp load_inbox(socket) do
    filter = socket.assigns.inbox_filter
    total = Library.count_inbox_files(filter: filter)

    # Clamp rather than render a page past the end: approving the last row on
    # the last page (or switching to a filter with fewer results) would
    # otherwise leave the offset pointing beyond `total`, showing an empty
    # list even though earlier rows still exist.
    offset =
      if socket.assigns.inbox_offset > 0 and socket.assigns.inbox_offset >= total do
        max(total - socket.assigns.inbox_limit, 0)
      else
        socket.assigns.inbox_offset
      end

    rows =
      Library.list_inbox_files(filter: filter, limit: socket.assigns.inbox_limit, offset: offset)

    socket
    |> assign(:inbox_total, total)
    |> assign(:inbox_offset, offset)
    |> stream(:inbox_rows, rows, reset: true)
  end
end
