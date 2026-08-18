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

  # Same reasoning as @modes: `phx-value-band` is client-controlled, so the
  # atom it names is looked up rather than converted. An unknown value is a
  # silent no-op -- unlike an unknown mode, there is no form state to explain
  # a rejection to, so there is nothing useful to flash.
  # `:ignored` is not a confidence band -- it is a status -- but it rides the
  # same chip row and the same client-controlled atom lookup as the real
  # bands, and load_groups/1 translates it into ImportGroups.page/2's
  # `:status` option rather than its `:band` option (which has no clause for
  # it and would raise).
  @bands %{
    "all" => :all,
    "ready" => :ready,
    "needs_attention" => :needs_attention,
    "no_match" => :no_match,
    "ignored" => :ignored
  }

  @empty_band_counts %{ready: 0, needs_attention: 0, no_match: 0, ignored: 0, total: 0}

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
      |> assign(:outcome_group_count, group_count_for_outcome(outcome_run))
      |> assign(:band, :all)
      |> assign(:search, "")
      |> assign(:cursor, nil)
      |> assign(:next_cursor, nil)
      |> assign(:cursor_stack, [])
      |> assign(:expanded_ids, MapSet.new())
      |> assign(:expanded_group_id, nil)
      |> assign(:band_counts, @empty_band_counts)
      # Per-library pending totals for the picker, keyed by library_path_id.
      # Populated by refresh_counts/1 alongside band_counts, not here: an
      # empty map is the correct disconnected-render value (no query at all),
      # matching band_counts's own placeholder above.
      |> assign(:library_group_counts, %{})
      |> assign(:matching_count, 0)
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
      {:ok, socket |> load_groups() |> refresh_counts()}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_params(_params, uri, socket) do
    # `/review` is kept as a redirect for old bookmarks and links -- the
    # module it used to point to is gone, and this page is the only one there
    # is now. Nothing still links here on purpose; `RunControl`'s outcome CTA
    # points straight at `/import` to avoid this exact round trip.
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
           |> assign(:outcome_group_count, 0)}

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

  # A stale bookmark, an id from before a path was removed, or a crafted
  # event can still name any id -- same guard shape as
  # authorize_library_path/2 above.
  def handle_event("select_library", %{"library_path_id" => id}, socket) do
    if Enum.any?(socket.assigns.importable_library_paths, &(&1.id == id)) do
      {:noreply, switch_library(socket, id)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_band", %{"band" => band}, socket) do
    case Map.fetch(@bands, band) do
      {:ok, band} ->
        {:noreply,
         socket
         |> assign(:band, band)
         |> assign(:cursor, nil)
         |> assign(:cursor_stack, [])
         |> assign(:selection, SelectionScope.new(socket.assigns.selected_library_path_id))
         |> load_groups()}

      :error ->
        {:noreply, socket}
    end
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
    case socket.assigns.next_cursor do
      nil ->
        {:noreply, socket}

      next_cursor ->
        {:noreply,
         socket
         |> assign(:cursor_stack, [socket.assigns.cursor | socket.assigns.cursor_stack])
         |> assign(:cursor, next_cursor)
         |> load_groups()}
    end
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

  # The button this responds to is never rendered on the Ignored view (see
  # ignored_group_row/1 -- ignored rows carry no checkbox at all), but the
  # event name itself is still a valid target for a crafted or stale request.
  # `SelectionScope.apply_band/2` has no clause for `:ignored` (it is a
  # status, not a real band), so building a filter-mode scope with it would
  # raise the first time anything read the scope back -- refusing here instead
  # keeps that a routine no-op rather than a crash.
  def handle_event("select_all_matching", _params, socket) do
    if socket.assigns.band == :ignored do
      {:noreply, socket}
    else
      filter = %{band: socket.assigns.band, q: socket.assigns.search}

      selection =
        socket.assigns.selected_library_path_id
        |> SelectionScope.new()
        |> SelectionScope.select_all_matching(filter)

      # `selected?/2` reads `:selection` fresh on every render, but a stream
      # item's rendered body does not: switching to :filter mode here selects
      # every matching row in the database without touching the `:groups`
      # stream, so every checkbox currently on screen would stay visually
      # unchecked. load_groups/1 re-inserts the whole current page, which is
      # the only thing that makes a stream item's `selected` attribute
      # re-evaluate -- see refresh_group_row/2's comment for the general rule.
      {:noreply, socket |> assign(:selection, selection) |> load_groups()}
    end
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply,
     socket
     |> assign(:selection, SelectionScope.clear(socket.assigns.selection))
     |> load_groups()}
  end

  def handle_event("accept_selected", _params, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      # accept/1 can fail at the enqueue step, in which case the groups are
      # marked accepted but nothing will apply them. Say so rather than
      # reporting success.
      case ImportGroups.accept(socket.assigns.selection) do
        {:ok, count} ->
          {:noreply,
           socket
           |> put_flash(:info, "Accepted #{count} group(s). Linking in the background.")
           |> assign(:selection, SelectionScope.clear(socket.assigns.selection))
           |> load_groups()
           |> refresh_counts()}

        {:error, reason} ->
          Logger.error("Could not enqueue the import group apply job", reason: inspect(reason))

          # accept/1 flips status to "accepted" *before* it tries to enqueue,
          # so the affected rows are already gone from the "pending" set both
          # page/2 and SelectionScope filter on -- regardless of whether the
          # enqueue itself succeeded. Reload so the stream (and the counts)
          # match the database instead of continuing to show rows that no
          # longer match the query, and clear the selection: it names ids
          # that can no longer be acted on, and re-running accept/1 against
          # them would select nothing, short-circuit, and return {:ok, 0} --
          # a second, silent "success" for a selection that already failed
          # once.
          {:noreply,
           socket
           |> put_flash(
             :error,
             "Marked for import, but the background job could not be started. " <>
               "They are not lost: the next successful accept for this library " <>
               "will pick them up."
           )
           |> assign(:selection, SelectionScope.clear(socket.assigns.selection))
           |> load_groups()
           |> refresh_counts()}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("ignore_selected", _params, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      {:ok, count} = ImportGroups.ignore(socket.assigns.selection)

      {:noreply,
       socket
       |> put_flash(:info, "Ignored #{count} group(s).")
       |> assign(:selection, SelectionScope.clear(socket.assigns.selection))
       |> load_groups()
       |> refresh_counts()}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  # `expanded_ids` tracks which groups are visually open (the chevron); a
  # settled group starts absent from it, an unsettled one starts present
  # (seeded in load_groups/1). `expanded_group_id` is a separate, single
  # value tracking which one group's members are actually loaded into
  # `@streams.members` -- auto-expanding every unsettled group on the page
  # must not mean eagerly loading members for all of them, so opening a
  # group only ever populates the member list for the group most recently
  # clicked; every other open group renders its `<ul>` with an empty member
  # list until it, too, is clicked.
  def handle_event("expand_group", %{"id" => id}, socket) do
    expanded = socket.assigns.expanded_ids

    # A group row's `expanded` and `members` are computed from assigns
    # outside the `:groups` stream itself. Stream items only redraw when
    # explicitly re-inserted -- LiveView diffs a stream by its own
    # insert/delete/reset operations, not by the outer assigns a `:for` over
    # it happens to close over -- so every row whose derived output just
    # changed must be re-inserted, or neither its chevron nor its member
    # list would ever change on screen.
    if MapSet.member?(expanded, id) do
      {:noreply,
       socket
       |> assign(:expanded_ids, MapSet.delete(expanded, id))
       |> refresh_group_row(id)}
    else
      previously_loaded = socket.assigns.expanded_group_id

      socket =
        socket
        |> assign(:expanded_ids, MapSet.put(expanded, id))
        |> assign(:expanded_group_id, id)
        |> stream(:members, ImportGroups.members(id, limit: 200), reset: true)
        |> refresh_group_row(id)

      # The group that previously held the loaded member list, if any and if
      # different, just lost it (its `@members` prop now evaluates to `[]`)
      # even though it may still be visually open -- that row needs
      # re-inserting too.
      socket =
        if previously_loaded && previously_loaded != id do
          refresh_group_row(socket, previously_loaded)
        else
          socket
        end

      {:noreply, socket}
    end
  end

  # The escape hatch for a group no provider carries: build the show straight
  # from its folder name instead of waiting on a match that will never come.
  # `total` is read before the call, not after: on success `create_local_show/1`
  # stamps the group with a synthetic provider identity so a second call is
  # refused, and its own `unresolved_count` is the only trace of how many
  # members it started with. A file with no parsed episode number stays
  # orphaned rather than guessed at, and the flash says so rather than
  # reporting a clean success for a partially-done action -- the failure mode
  # this project has already corrected twice.
  def handle_event("create_local_show", %{"id" => id}, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      total = ImportGroups.member_count(id)

      case ImportGroups.create_local_show(id) do
        {:ok, item} ->
          remaining = ImportGroups.member_count(id)
          linked = total - remaining

          message =
            if remaining > 0 do
              "Created #{item.title} and linked #{linked} of #{total} files. " <>
                "#{remaining} had no episode number."
            else
              "Created #{item.title} from the folder name."
            end

          {:noreply,
           socket
           |> put_flash(:info, message)
           |> load_groups()
           |> refresh_counts()}

        # No `phx-disable-with` guards this button, and a crash partway
        # through a previous call would leave nothing else to retry against
        # -- so this is a routine double-click or a stale click on an
        # already-handled row, not a system failure. Say so plainly rather
        # than the generic error message below.
        {:error, :already_created} ->
          {:noreply, put_flash(socket, :info, "That show was already created from this folder.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Could not create the show: #{inspect(reason)}")}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  # Ignore used to be a one-way door: a rescan can never bring a group back
  # (write_group/4 preserves status on purpose), and until now there was no
  # UI that could even see an ignored group to reconsider it. This is the way
  # back -- only reachable from the Ignored view's own row, which is the only
  # place `restore_group` is rendered, but a stale click after another tab
  # already restored the same group is a normal, silent `{:ok, 0}`.
  def handle_event("restore_group", %{"id" => id}, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      case ImportGroups.restore(id) do
        {:ok, count} when count > 0 ->
          {:noreply,
           socket
           |> put_flash(:info, "Restored to pending.")
           |> load_groups()
           |> refresh_counts()}

        {:ok, 0} ->
          {:noreply, put_flash(socket, :info, "That group is no longer ignored.")}
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
        |> assign(:outcome_group_count, group_count_for_outcome(run))
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
    # Only ever arrives for the currently selected library: switch_library/2
    # unsubscribes from the old topic and subscribes to the new one in the
    # same step, so there is nothing to filter on here.
    {:noreply, socket |> load_groups() |> refresh_counts()}
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
    |> assign(:outcome_group_count, group_count_for_outcome(run))
  end

  # Queries the pending group count once when a run reaches a terminal state
  # so the outcome_review_cta component never calls the DB directly from its
  # body.
  #
  # Deliberately `band_counts/1` (scoped to this run's own library path), not
  # `ImportGroups.count_pending/0` (the global nav-badge total, see its own
  # doc): this CTA reports what one specific run just found, and a global
  # count would fold in every other library's backlog too, showing a number
  # that could disagree with -- and in a multi-library install often would --
  # what `/import` actually displays for the library this run touched.
  #
  # Was `Library.count_inbox_files/1`, a `MediaFile`/`MatchCandidate` query
  # that has nothing to do with `import_groups`, the table the review page
  # actually reads. That mismatch is Critical 1 from the whole-branch review:
  # the CTA could say "review N files" while the page it linked to showed
  # nothing at all. Sourcing both from the same table is what makes the
  # number and the destination agree.
  defp group_count_for_outcome(nil), do: 0

  defp group_count_for_outcome(run) do
    ImportGroups.band_counts(run.library_path_id).total
  end

  # The review section works one library path at a time. On mount it defaults
  # to the first importable path, same as the start form's own radio default;
  # after that, select_library/2 (via the picker) is what changes it.
  defp default_library_path_id([%{id: id} | _rest]), do: id
  defp default_library_path_id([]), do: nil

  # Switches which library path the review section shows. Every piece of
  # state the review section owns is either library-scoped (selection,
  # paging, expansion) or would silently act on rows no longer on screen if
  # left as-is (a filter-mode selection built against the old library's
  # groups, most of all) -- so all of it resets here rather than only the
  # pieces that would visibly break.
  defp switch_library(socket, id) do
    previous_id = socket.assigns.selected_library_path_id

    if connected?(socket) and previous_id != id do
      if previous_id, do: Phoenix.PubSub.unsubscribe(Mydia.PubSub, "import_groups:#{previous_id}")
      Phoenix.PubSub.subscribe(Mydia.PubSub, "import_groups:#{id}")
    end

    socket
    |> assign(:selected_library_path_id, id)
    |> assign(:cursor, nil)
    |> assign(:cursor_stack, [])
    |> assign(:expanded_ids, MapSet.new())
    |> assign(:expanded_group_id, nil)
    |> assign(:selection, SelectionScope.new(id))
    |> stream(:members, [], reset: true)
    |> load_groups()
    |> refresh_counts()
  end

  # Paging and filtering (band, search, cursor) never change how many groups
  # exist in each band or in any other library -- only accepting, ignoring,
  # switching libraries, or another session's own accept/ignore (over
  # PubSub) do. So this reloads only the current page of groups; callers
  # that know the counts actually changed also call refresh_counts/1.
  defp load_groups(socket) do
    library_path_id = socket.assigns.selected_library_path_id
    band = socket.assigns.band
    # `:ignored` is a status, not a real band -- ImportGroups.page/2's :band
    # option has no clause for it, so it goes through :status instead and the
    # band filter itself is left at :all (an ignored group's own confidence
    # band plays no part in the Ignored view).
    {status, page_band} = if band == :ignored, do: {"ignored", :all}, else: {"pending", band}
    filter = %{band: page_band, q: socket.assigns.search}

    {groups, next_cursor} =
      ImportGroups.page(library_path_id,
        band: filter.band,
        q: filter.q,
        status: status,
        after: socket.assigns.cursor
      )

    # What "select all matching this filter" would actually select, right
    # now, under the active band and search -- not band_counts/1's total,
    # which only accounts for the band and knows nothing about the search
    # box. A `SelectionScope.count/1` in :filter mode is a single SQL COUNT
    # against the same predicate select_all_matching/1 itself would use, so
    # this stays correct without duplicating that predicate here.
    #
    # Skipped entirely on the Ignored view: SelectionScope's own query is
    # hardcoded to `status == "pending"` (nothing there is selectable), and
    # its `apply_band/2` has no `:ignored` clause to run in the first place.
    matching_count =
      if band == :ignored do
        0
      else
        library_path_id
        |> SelectionScope.new()
        |> SelectionScope.select_all_matching(filter)
        |> SelectionScope.count()
      end

    # The wizard pre-collapsed any season whose episodes all matched confidently,
    # and losing that is why the rewritten page read as one huge list. Same rule,
    # one level up: a settled group starts closed, an unsettled one starts open.
    expanded =
      groups
      |> Enum.reject(&(ImportGroups.band(&1) == :ready))
      |> Enum.map(& &1.id)
      |> MapSet.new()

    socket
    |> stream(:groups, groups, reset: true)
    |> assign(:next_cursor, next_cursor)
    |> assign(:matching_count, matching_count)
    |> assign(:expanded_ids, expanded)
  end

  # Recomputes the counts that only change when a group's status changes,
  # not on every page move or search keystroke: the current library's band
  # breakdown for the filter chips, the Ignored chip's own count, and every
  # importable library's pending total for the picker. band_counts/1 loads
  # every pending group row for each library path it is asked about, so this
  # is deliberately called only from mount/1, switch_library/2,
  # accept/ignore/restore, and the PubSub handler -- never from load_groups/1,
  # which paging and search both go through.
  defp refresh_counts(socket) do
    library_path_id = socket.assigns.selected_library_path_id

    band_counts =
      library_path_id
      |> ImportGroups.band_counts()
      |> Map.put(:ignored, ImportGroups.count_by_status(library_path_id, "ignored"))

    socket
    |> assign(:band_counts, band_counts)
    |> assign(
      :library_group_counts,
      Map.new(socket.assigns.importable_library_paths, fn path ->
        {path.id, ImportGroups.band_counts(path.id).total}
      end)
    )
  end

  # Re-inserts one group, purely to force LiveView to redraw its row.
  # `group_row/1`'s `selected` and `expanded` attributes are derived from
  # `@selection`/`@expanded_ids`, not from the group struct itself, and a
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
