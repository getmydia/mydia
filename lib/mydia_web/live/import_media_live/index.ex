defmodule MydiaWeb.ImportMediaLive.Index do
  @moduledoc """
  Import Media: start a run, watch it, stop it, then review what it found.

  The run itself lives in Oban, so the run-control section holds no import
  progress of its own beyond what it reads back. The review section below it
  is a streamed, keyset-paged table of `Mydia.Library.ImportGroup` rows (one
  row per anchor folder, not one per file), so opening this page never loads
  more than one page of groups regardless of how large the library is.
  """
  use MydiaWeb, :live_view

  require Logger

  alias Mydia.{Library, Repo, Settings}
  alias Mydia.ImportGroups
  alias Mydia.Jobs.ImportRun, as: ImportRunJob
  alias Mydia.Library.{ImportGroup, ImportRun, SelectionScope}
  alias MydiaWeb.Live.Authorization
  alias MydiaWeb.ImportMediaLive.{Components, RunControl}

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
    importable_library_paths = Enum.filter(library_paths, &importable?/1)
    selected_library_path_id = default_library_path_id(importable_library_paths)

    if connected?(socket) do
      if run_to_watch do
        Phoenix.PubSub.subscribe(Mydia.PubSub, ImportRunJob.progress_topic(run_to_watch.id))
      end

      if selected_library_path_id do
        Phoenix.PubSub.subscribe(Mydia.PubSub, "import_groups:#{selected_library_path_id}")
      end
    end

    socket =
      socket
      |> assign(:page_title, "Import Media")
      |> assign(:library_paths, library_paths)
      # The start form offers only what the coordinator can actually import.
      # `@library_paths` deliberately keeps every path so a run left on a
      # music path by an older build is still found, shown, and stoppable.
      |> assign(:importable_library_paths, importable_library_paths)
      |> assign(:active_run, active_run)
      |> assign(:outcome_run, outcome_run)
      |> assign(:outcome_inbox_count, inbox_count_for_outcome(outcome_run))
      |> assign(:band, :all)
      |> assign(:search, "")
      |> assign(:cursor, nil)
      |> assign(:next_cursor, nil)
      |> assign(:cursor_stack, [])
      |> assign(:expanded_group_id, nil)
      |> assign(:band_counts, %{ready: 0, needs_attention: 0, no_match: 0, total: 0})
      |> assign(:selected_library_path_id, selected_library_path_id)
      |> assign(:selection, SelectionScope.new(selected_library_path_id))
      # `ImportGroup` rows carry an `:id` field, so the default `"groups-<id>"`
      # naming would be adequate, but the page's key elements are addressed as
      # `#group-<id>` (singular). `ImportGroups.members/2` rows are plain
      # `%{media_file:, candidate:}` maps with no top-level `:id` at all, so
      # without an explicit `:dom_id` here streaming them crashes outright --
      # LiveView's default id function requires one. `member-row-` (not
      # `member-`) keeps the stream item's id distinct from the
      # `#member-<file id>` span `group_row/1` renders inside each row.
      |> stream_configure(:groups, dom_id: &"group-#{&1.id}")
      |> stream_configure(:members, dom_id: &"member-row-#{&1.media_file.id}")
      |> stream(:groups, [])
      |> stream(:members, [])

    # The disconnected branch does no database work at all beyond what the
    # run-control section already needed. That is what keeps the initial HTTP
    # response fast on a large library, and it is the property pinned by the
    # "issues no query on the disconnected render" test.
    if connected?(socket) do
      {:ok, load_groups(socket)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_params(_params, uri, socket) do
    # `/review` is kept as a redirect for old bookmarks and links (including
    # the outcome CTA below, which still points there on purpose -- see its
    # moduledoc). The module it used to point to is gone; this page is the
    # only one there is now.
    if URI.parse(uri).path == "/review" do
      {:noreply, push_navigate(socket, to: ~p"/import")}
    else
      {:noreply, socket}
    end
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

  def handle_event("select_band", %{"band" => band}, socket) do
    {:noreply,
     socket
     |> assign(:band, String.to_existing_atom(band))
     |> assign(:cursor, nil)
     |> assign(:cursor_stack, [])
     |> assign(:selection, SelectionScope.new(socket.assigns.selected_library_path_id))
     |> load_groups()}
  end

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply,
     socket
     |> assign(:search, q)
     |> assign(:cursor, nil)
     |> assign(:cursor_stack, [])
     |> load_groups()}
  end

  def handle_event("next_page", _params, socket) do
    {:noreply,
     socket
     |> assign(:cursor_stack, [socket.assigns.cursor | socket.assigns.cursor_stack])
     |> assign(:cursor, socket.assigns.next_cursor)
     |> load_groups()}
  end

  def handle_event("prev_page", _params, socket) do
    case socket.assigns.cursor_stack do
      [] ->
        {:noreply, socket}

      [previous | rest] ->
        {:noreply,
         socket
         |> assign(:cursor, previous)
         |> assign(:cursor_stack, rest)
         |> load_groups()}
    end
  end

  def handle_event("toggle_group", %{"id" => id}, socket) do
    socket = assign(socket, :selection, SelectionScope.toggle(socket.assigns.selection, id))
    {:noreply, refresh_group_row(socket, id)}
  end

  def handle_event("select_all_matching", _params, socket) do
    filter = %{band: socket.assigns.band, q: socket.assigns.search}

    selection =
      socket.assigns.selected_library_path_id
      |> SelectionScope.new()
      |> SelectionScope.select_all_matching(filter)

    {:noreply, assign(socket, :selection, selection)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selection, SelectionScope.clear(socket.assigns.selection))}
  end

  def handle_event("accept_selected", _params, socket) do
    # accept/1 can fail at the enqueue step, in which case the groups are
    # marked accepted but nothing will apply them. Say so rather than
    # reporting success.
    case ImportGroups.accept(socket.assigns.selection) do
      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(:info, "Accepted #{count} group(s). Linking in the background.")
         |> assign(:selection, SelectionScope.clear(socket.assigns.selection))
         |> load_groups()}

      {:error, reason} ->
        Logger.error("Could not enqueue the import group apply job", reason: inspect(reason))

        {:noreply,
         put_flash(
           socket,
           :error,
           "Marked for import, but the background job could not be started. Try again."
         )}
    end
  end

  def handle_event("ignore_selected", _params, socket) do
    {:ok, count} = ImportGroups.ignore(socket.assigns.selection)

    {:noreply,
     socket
     |> put_flash(:info, "Ignored #{count} group(s).")
     |> assign(:selection, SelectionScope.clear(socket.assigns.selection))
     |> load_groups()}
  end

  def handle_event("expand_group", %{"id" => id}, socket) do
    previously_expanded = socket.assigns.expanded_group_id

    socket =
      if previously_expanded == id do
        socket
        |> assign(:expanded_group_id, nil)
        |> stream(:members, [], reset: true)
      else
        members = ImportGroups.members(id, limit: 200)

        socket
        |> assign(:expanded_group_id, id)
        |> stream(:members, members, reset: true)
      end

    # A group row's `expanded` (and, on toggle, `selected`) attribute is
    # computed from assigns outside the `:groups` stream itself. Stream items
    # only redraw when explicitly re-inserted -- LiveView diffs a stream by
    # its own insert/delete/reset operations, not by the outer assigns a
    # `:for` over it happens to close over -- so both the row losing focus
    # and the row gaining it must be re-inserted, or neither's chevron or
    # member list would ever change on screen.
    socket =
      if previously_expanded && previously_expanded != id do
        refresh_group_row(socket, previously_expanded)
      else
        socket
      end

    {:noreply, refresh_group_row(socket, id)}
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

  def handle_info({:import_groups_changed, _library_path_id}, socket) do
    {:noreply, load_groups(socket)}
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

  # The review section works one library path at a time and, unlike the start
  # form, has no picker of its own yet -- so it defaults to the first
  # importable path, same as the start form's own radio default.
  defp default_library_path_id([%{id: id} | _rest]), do: id
  defp default_library_path_id([]), do: nil

  defp load_groups(socket) do
    library_path_id = socket.assigns.selected_library_path_id

    {groups, next_cursor} =
      ImportGroups.page(library_path_id,
        band: socket.assigns.band,
        q: socket.assigns.search,
        after: socket.assigns.cursor
      )

    socket
    |> stream(:groups, groups, reset: true)
    |> assign(:next_cursor, next_cursor)
    |> assign(:band_counts, ImportGroups.band_counts(library_path_id))
  end

  # Re-inserts one group, purely to force LiveView to redraw its row.
  # `group_row/1`'s `selected` and `expanded` attributes are derived from
  # `@selection`/`@expanded_group_id`, not from the group struct itself, and a
  # stream only redraws an item on an explicit insert/delete/reset -- so a
  # handler that only reassigns those has nothing else that would make the
  # checkbox or chevron move. A stream's contents can only be walked from
  # inside the `:for` a template compiles it into, not from a handler, so
  # this re-reads the one row by primary key rather than searching the
  # in-memory stream. A group that has vanished between render and click
  # (accepted or ignored from another session) is a silent no-op: the row
  # will drop out on the next full `load_groups/1` regardless.
  defp refresh_group_row(socket, id) do
    case Repo.get(ImportGroup, id) do
      nil -> socket
      group -> stream_insert(socket, :groups, group)
    end
  end
end
