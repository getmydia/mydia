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

  alias Mydia.{Library, Metadata, Repo, Settings}
  alias Mydia.ImportGroups
  alias Mydia.Jobs.ImportRun, as: ImportRunJob
  alias Mydia.Library.{ImportGroup, ImportRun, SelectionScope}
  alias MydiaWeb.Live.Authorization
  alias MydiaWeb.ImportMediaLive.{Components, RunControl}

  # `phx-value-band` is client-controlled, so the atom it names is looked up
  # rather than converted. An unknown value is a silent no-op because there is
  # no form state to explain a rejection to.
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

  # How long an :import_groups_changed burst is allowed to coalesce into one
  # refresh. ApplyImportGroups.broadcast/1 fires once per Oban job, and an
  # active run can enqueue and complete many of those jobs in quick
  # succession -- each one otherwise re-triggering refresh_counts/1's full
  # band_counts/1 read (every pending group row, once per importable library
  # path) on every open page. Mirrors Jobs.ImportRun's own
  # @broadcast_ms_interval for progress updates, just applied on the
  # receiving end here instead of the sending end there, since this
  # broadcast has no single producer to throttle.
  @refresh_debounce_ms 500
  @scan_complete_display_ms 5_000

  @impl true
  def mount(params, _session, socket) do
    library_paths = Settings.list_library_paths()
    importable_library_paths = Enum.filter(library_paths, &importable?/1)
    selected_library_path_id = resolve_library_path_id(params, importable_library_paths)

    selected_library_path =
      Enum.find(importable_library_paths, &(&1.id == selected_library_path_id))

    active_runs_by_library =
      Library.list_active_import_runs()
      |> Map.new(&{&1.library_path_id, &1})

    active_run = Map.get(active_runs_by_library, selected_library_path_id)

    # Run state follows the one library selected by the page-level tabs. A
    # scan on another path is represented by that tab's activity indicator,
    # not by replacing the selected library's scan controls and review list.
    outcome_run =
      if active_run || is_nil(selected_library_path_id) do
        nil
      else
        selected_library_path_id
        |> Library.last_import_run()
        |> persistent_outcome()
      end

    if connected?(socket) do
      if active_run do
        Phoenix.PubSub.subscribe(Mydia.PubSub, ImportRunJob.progress_topic(active_run.id))
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
      |> assign(:active_runs_by_library, active_runs_by_library)
      |> assign(:outcome_run, outcome_run)
      |> assign(:scan_complete_run_id, nil)
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
      |> assign(:page_group_ids, [])
      |> assign(:selected_library_path_id, selected_library_path_id)
      |> assign(:selected_library_path, selected_library_path)
      |> assign(:selection, SelectionScope.new(selected_library_path_id))
      # Guards the :import_groups_changed debounce below: true while a
      # deferred refresh is already scheduled, so a burst of broadcasts
      # schedules exactly one Process.send_after/3 rather than one per
      # message.
      |> assign(:refresh_scheduled?, false)
      # The "Change match" / "Identify" search modal's state, nil when
      # closed. `match_search_token` is a monotonic counter (mirrors
      # SearchLive's own `search_id`) captured by each `start_async` search
      # closure, so a slow response from an earlier keystroke can never
      # overwrite a newer one -- LiveView cancels the previous `start_async`
      # call under the same name, but the result message can already be in
      # flight by the time it does, so the token is the actual guard.
      |> assign(:match_search, nil)
      |> assign(:match_search_token, 0)
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
  def handle_params(params, uri, socket) do
    # `/review` is kept as a redirect for old bookmarks and links -- the
    # module it used to point to is gone, and this page is the only one there
    # is now. Nothing still links here on purpose; `RunControl`'s outcome CTA
    # points straight at `/import` to avoid this exact round trip.
    if URI.parse(uri).path == "/review" do
      {:noreply, push_navigate(socket, to: ~p"/import")}
    else
      target_id = resolve_library_path_id(params, socket.assigns.importable_library_paths)

      socket =
        if target_id && target_id != socket.assigns.selected_library_path_id do
          switch_library(socket, target_id)
        else
          socket
        end

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("start_run", %{"library_path_id" => path_id} = params, socket) do
    mode = if params["auto_import"] == "true", do: :unattended, else: :review

    with :ok <- Authorization.authorize_import_media(socket),
         :ok <- authorize_library_path(socket, path_id) do
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
           |> put_active_run(run)
           |> assign(:outcome_run, nil)
           |> assign(:scan_complete_run_id, nil)}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "That library is already being imported.")}
      end
    else
      {:unauthorized, socket} ->
        {:noreply, socket}

      {:unsupported_type, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event("clear_scan_results", %{"library_path_id" => path_id}, socket) do
    with :ok <- Authorization.authorize_import_media(socket),
         :ok <- authorize_library_path(socket, path_id),
         {:ok, count} <- ImportGroups.clear_for_library(path_id) do
      {:noreply,
       socket
       |> put_flash(:info, "Cleared #{count} scan result group(s).")
       |> assign(:outcome_run, nil)
       |> assign(:scan_complete_run_id, nil)
       |> assign(:selection, SelectionScope.new(path_id))
       |> assign(:match_search, nil)
       |> load_groups()
       |> refresh_counts()}
    else
      {:unauthorized, socket} ->
        {:noreply, socket}

      {:unsupported_type, socket} ->
        {:noreply, socket}

      {:error, :active_run} ->
        {:noreply, put_flash(socket, :error, "Stop this library's scan before clearing results.")}
    end
  end

  def handle_event("import_all_results", _params, socket) do
    with :ok <- Authorization.authorize_import_media(socket),
         library_path_id when is_binary(library_path_id) <-
           socket.assigns.selected_library_path_id do
      {:noreply,
       socket
       |> accept_result(ImportGroups.accept_all_matched(library_path_id))}
    else
      {:unauthorized, socket} -> {:noreply, socket}
      nil -> {:noreply, put_flash(socket, :error, "Select a library before importing results.")}
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
              {:noreply, put_active_run(socket, stopping)}

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
    if Enum.any?(socket.assigns.importable_library_paths, &(&1.id == id)) and
         id != socket.assigns.selected_library_path_id do
      {:noreply, switch_library(socket, id)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_band", %{"band" => band}, socket) do
    case Map.fetch(@bands, band) do
      {:ok, band} ->
        status = if band == :ignored, do: "ignored", else: "pending"

        {:noreply,
         socket
         |> assign(:band, band)
         |> assign(:cursor, nil)
         |> assign(:cursor_stack, [])
         |> assign(
           :selection,
           SelectionScope.new(socket.assigns.selected_library_path_id, status)
         )
         |> load_groups()}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("search", %{"q" => q}, socket) do
    status = if socket.assigns.band == :ignored, do: "ignored", else: "pending"

    {:noreply,
     socket
     |> assign(:search, q)
     |> assign(:cursor, nil)
     |> assign(:cursor_stack, [])
     # A selection made under one search must not survive into another: in
     # :filter mode select_all_matching/1 captures the current :q, and both
     # SelectionScope.selected?/2 (checkbox state) and to_query/1 (what
     # accept_selected/ignore_selected act on) would otherwise disagree with
     # what is actually on screen after the search changes. select_band/1
     # resets the selection for the same reason.
     |> assign(:selection, SelectionScope.new(socket.assigns.selected_library_path_id, status))
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

  def handle_event("select_current_page", _params, socket) do
    status = if socket.assigns.band == :ignored, do: "ignored", else: "pending"

    selection =
      socket.assigns.selected_library_path_id
      |> SelectionScope.new(status)
      |> SelectionScope.select_page(socket.assigns.page_group_ids)

    {:noreply, socket |> assign(:selection, selection) |> load_groups()}
  end

  def handle_event("select_all_matching", _params, socket) do
    status = if socket.assigns.band == :ignored, do: "ignored", else: "pending"
    page_band = if socket.assigns.band == :ignored, do: :all, else: socket.assigns.band
    filter = %{band: page_band, q: socket.assigns.search}

    selection =
      socket.assigns.selected_library_path_id
      |> SelectionScope.new(status)
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

  def handle_event("clear_selection", _params, socket) do
    {:noreply,
     socket
     |> assign(:selection, SelectionScope.clear(socket.assigns.selection))
     |> load_groups()}
  end

  def handle_event("accept_selected", _params, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      {:noreply,
       socket
       |> accept_result(ImportGroups.accept(socket.assigns.selection))}
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

  def handle_event("restore_selected", _params, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      {:ok, count} = ImportGroups.restore(socket.assigns.selection)

      {:noreply,
       socket
       |> put_flash(:info, "Restored #{count} group(s) to pending.")
       |> assign(:selection, SelectionScope.clear(socket.assigns.selection))
       |> load_groups()
       |> refresh_counts()}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("rematch_selected", _params, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      {:ok, count} = ImportGroups.rematch(socket.assigns.selection)

      {:noreply,
       socket
       |> put_flash(:info, "Re-matched #{count} group(s).")
       |> assign(:selection, SelectionScope.clear(socket.assigns.selection))
       |> load_groups()
       |> refresh_counts()}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  # `expanded_ids` tracks which groups are visually open (the chevron).
  # Expanding a group populates `@streams.members` with its files and collapses
  # any previously open group so that only the active group shows as expanded
  # and the file list matches the open chevron.
  def handle_event("expand_group", %{"id" => id}, socket) do
    if socket.assigns.expanded_group_id == id do
      # Collapsing the currently open group
      socket =
        socket
        |> assign(:expanded_ids, MapSet.delete(socket.assigns.expanded_ids, id))
        |> assign(:expanded_group_id, nil)
        |> stream(:members, [], reset: true)
        |> refresh_group_row(id)

      {:noreply, socket}
    else
      # Expanding a new group: collapse any previously expanded group so
      # state stays in sync and only the active group shows open.
      old_expanded_ids = socket.assigns.expanded_ids

      socket =
        socket
        |> assign(:expanded_ids, MapSet.new([id]))
        |> assign(:expanded_group_id, id)
        |> stream(:members, ImportGroups.members(id, limit: 200), reset: true)
        |> refresh_group_row(id)

      # Redraw any rows that were previously expanded so their chevrons close
      socket =
        Enum.reduce(old_expanded_ids, socket, fn old_id, acc ->
          if old_id != id, do: refresh_group_row(acc, old_id), else: acc
        end)

      {:noreply, socket}
    end
  end

  def handle_event("update_member_episode", %{"file_id" => file_id} = params, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      season = Map.get(params, "season")
      episode = Map.get(params, "episode")

      case ImportGroups.update_member_episode(file_id, season, episode) do
        {:ok, updated_member} ->
          socket =
            socket
            |> stream_insert(:members, updated_member)
            |> maybe_refresh_group_row(updated_member.media_file.import_group_id)

          {:noreply, socket}

        {:error, _reason} ->
          {:noreply, socket}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
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

  # Opens the "Change match" / "Identify" modal for one group and kicks off
  # its first search, prefilled from the group's own suggested (or folder)
  # title -- a reviewer correcting a wrong match almost always wants to see
  # alternatives immediately, not type the title back in from scratch. Not
  # authorization-guarded: this only reads from the metadata relay and opens
  # UI state, it writes nothing. `select_match/2` below is the mutation, and
  # that is where the guard and the readonly-user test live, matching how
  # `create_local_show`'s button is rendered for every viewer but its handler
  # is the one that checks.
  def handle_event("open_match_search", %{"id" => id}, socket) do
    case Repo.get(ImportGroup, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That group is no longer available.")}

      group ->
        query = group.suggested_title || group.display_title || ""

        state = %{
          group_id: group.id,
          media_type: group.media_type,
          query: query,
          results: [],
          searching: true,
          error: nil
        }

        {:noreply, socket |> assign(:match_search, state) |> run_match_search(query)}
    end
  end

  def handle_event("match_search_query", %{"q" => query}, socket) do
    case socket.assigns.match_search do
      nil ->
        {:noreply, socket}

      state ->
        {:noreply,
         socket
         |> assign(:match_search, %{state | query: query, searching: true, error: nil})
         |> run_match_search(query)}
    end
  end

  def handle_event("close_match_search", _params, socket) do
    {:noreply, assign(socket, :match_search, nil)}
  end

  # The mutation: applies one chosen search result to the whole group. Keyed
  # by `provider_id` *and* `provider` together (not `provider_id` alone) so a
  # numeric collision between two different providers' ids can never resolve
  # to the wrong result -- within one search both always agree (the query is
  # scoped to a single provider, see run_match_search/2), but nothing here
  # depends on that staying true.
  def handle_event(
        "select_match",
        %{"provider_id" => provider_id, "provider" => provider},
        socket
      ) do
    with :ok <- Authorization.authorize_import_media(socket) do
      state = socket.assigns.match_search

      result =
        state &&
          Enum.find(state.results, fn r ->
            to_string(r.provider_id) == provider_id and to_string(r.provider) == provider
          end)

      case {state, result} do
        {nil, _} ->
          {:noreply, socket}

        {_, nil} ->
          {:noreply,
           put_flash(socket, :error, "That result is no longer available. Search again.")}

        {%{group_id: group_id}, result} ->
          apply_selected_match(socket, group_id, result)
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:group_match_search, {:ok, {token, group_id, result}}, socket) do
    if stale_match_search?(socket, token, group_id) do
      {:noreply, socket}
    else
      {:noreply,
       assign(socket, :match_search, apply_search_result(socket.assigns.match_search, result))}
    end
  end

  def handle_async(:group_match_search, {:exit, reason}, socket) do
    Logger.warning("Group match search crashed", reason: inspect(reason))

    socket =
      case socket.assigns.match_search do
        nil ->
          socket

        state ->
          assign(socket, :match_search, %{
            state
            | searching: false,
              error: "Search failed. Try again."
          })
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:import_run_progress, run}, socket) do
    socket =
      if run.status in [:running, :stopping] do
        put_active_run(socket, run)
      else
        # Successful completion is a short acknowledgement beside Review;
        # failed and stopped runs remain in the scan panel with their details.
        socket
        |> show_outcome(run)
        |> load_groups()
        |> refresh_counts()
      end

    {:noreply, socket}
  end

  def handle_info({:dismiss_scan_complete, run_id}, socket) do
    socket =
      if socket.assigns.scan_complete_run_id == run_id do
        assign(socket, :scan_complete_run_id, nil)
      else
        socket
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
    #
    # Coalesced rather than acted on immediately: see @refresh_debounce_ms.
    # A refresh already scheduled means a broadcast earlier in this burst
    # already queued one, so this message is dropped -- it will be covered
    # by that refresh once it fires.
    if socket.assigns.refresh_scheduled? do
      {:noreply, socket}
    else
      Process.send_after(self(), :run_deferred_group_refresh, @refresh_debounce_ms)
      {:noreply, assign(socket, :refresh_scheduled?, true)}
    end
  end

  def handle_info(:run_deferred_group_refresh, socket) do
    {:noreply,
     socket
     |> assign(:refresh_scheduled?, false)
     |> load_groups()
     |> refresh_counts()}
  end

  defp importable?(library_path), do: ImportRun.importable_type?(library_path.type)

  # The start form only lists importable paths, but a stale bookmark or a
  # crafted event can still name any id. `run_scan_phase/2` refuses the same
  # set; this layer only exists so the user gets a sentence instead of a run
  # that starts and immediately fails.
  defp authorize_library_path(socket, path_id) do
    cond do
      path_id != socket.assigns.selected_library_path_id ->
        {:unsupported_type,
         put_flash(socket, :error, "Select that library before starting its scan.")}

      Enum.any?(socket.assigns.importable_library_paths, &(&1.id == path_id)) ->
        :ok

      true ->
        {:unsupported_type,
         put_flash(socket, :error, "Only movie, TV and mixed libraries can be imported.")}
    end
  end

  defp accept_result(socket, {:ok, count}) do
    socket
    |> put_flash(:info, "Accepted #{count} group(s). Linking in the background.")
    |> assign(:selection, SelectionScope.clear(socket.assigns.selection))
    |> load_groups()
    |> refresh_counts()
  end

  defp accept_result(socket, {:error, reason}) do
    Logger.error("Could not enqueue the import group apply job", reason: inspect(reason))

    # The status update commits before the enqueue is attempted, so affected
    # rows are already outside the pending review query even on this error.
    # Refresh the page and keep the recovery guidance consistent for selected
    # accepts and Import All.
    socket
    |> put_flash(
      :error,
      "Marked for import, but the background job could not be started. " <>
        "They are not lost: the next successful accept for this library " <>
        "will pick them up."
    )
    |> assign(:selection, SelectionScope.clear(socket.assigns.selection))
    |> load_groups()
    |> refresh_counts()
  end

  defp show_outcome(socket, run) do
    socket =
      socket
      |> assign(:active_run, nil)
      |> update(:active_runs_by_library, &Map.delete(&1, run.library_path_id))

    if run.status == :done do
      Process.send_after(
        self(),
        {:dismiss_scan_complete, run.id},
        @scan_complete_display_ms
      )

      socket
      |> assign(:outcome_run, nil)
      |> assign(:scan_complete_run_id, run.id)
    else
      socket
      |> assign(:outcome_run, persistent_outcome(run))
      |> assign(:scan_complete_run_id, nil)
    end
  end

  defp put_active_run(socket, run) do
    socket
    |> assign(:active_run, run)
    |> update(:active_runs_by_library, &Map.put(&1, run.library_path_id, run))
  end

  defp persistent_outcome(%ImportRun{status: status} = run)
       when status in [:failed, :stopped],
       do: run

  defp persistent_outcome(_run), do: nil

  defp resolve_library_path_id(params, library_paths) do
    cond do
      id = params["library_path_id"] || params["library_id"] ->
        Enum.find_value(library_paths, &(&1.id == id && &1.id)) ||
          default_library_path_id(library_paths)

      type = params["type"] || params["library_type"] ->
        resolve_library_by_type(type, library_paths) || default_library_path_id(library_paths)

      true ->
        default_library_path_id(library_paths)
    end
  end

  defp resolve_library_by_type(type, library_paths) when type in ["movies", "movie"] do
    Enum.find_value(library_paths, fn lp -> lp.default_for_movies && lp.id end) ||
      Enum.find_value(library_paths, fn lp -> lp.type == :movies && lp.id end) ||
      Enum.find_value(library_paths, fn lp -> lp.type == :mixed && lp.id end)
  end

  defp resolve_library_by_type(type, library_paths)
       when type in ["tv", "series", "tv_show", "shows"] do
    Enum.find_value(library_paths, fn lp -> lp.default_for_series && lp.id end) ||
      Enum.find_value(library_paths, fn lp -> lp.type == :series && lp.id end) ||
      Enum.find_value(library_paths, fn lp -> lp.type == :mixed && lp.id end)
  end

  defp resolve_library_by_type(_type, _library_paths), do: nil

  # Scanning and review work on one library path at a time. On mount the
  # page-level tabs default to the first importable path; after that,
  # select_library/2 changes the shared page context.
  defp default_library_path_id([%{id: id} | _rest]), do: id
  defp default_library_path_id([]), do: nil

  # Switches the library shared by scan controls and review. Every piece of
  # review state is library-scoped, and run subscriptions must move with the
  # same selection so another library's progress never takes over this tab.
  defp switch_library(socket, id) do
    previous_id = socket.assigns.selected_library_path_id
    previous_run = socket.assigns.active_run
    active_run = Library.active_import_run(id)
    outcome_run = if active_run, do: nil, else: persistent_outcome(Library.last_import_run(id))
    selected_library_path = Enum.find(socket.assigns.importable_library_paths, &(&1.id == id))

    if connected?(socket) and previous_id != id do
      if previous_id, do: Phoenix.PubSub.unsubscribe(Mydia.PubSub, "import_groups:#{previous_id}")

      if previous_run,
        do: Phoenix.PubSub.unsubscribe(Mydia.PubSub, ImportRunJob.progress_topic(previous_run.id))

      Phoenix.PubSub.subscribe(Mydia.PubSub, "import_groups:#{id}")

      if active_run,
        do: Phoenix.PubSub.subscribe(Mydia.PubSub, ImportRunJob.progress_topic(active_run.id))
    end

    socket
    |> assign(:selected_library_path_id, id)
    |> assign(:selected_library_path, selected_library_path)
    |> assign(:active_run, active_run)
    |> update(:active_runs_by_library, fn runs ->
      if active_run, do: Map.put(runs, id, active_run), else: Map.delete(runs, id)
    end)
    |> assign(:outcome_run, outcome_run)
    |> assign(:scan_complete_run_id, nil)
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
    matching_count =
      library_path_id
      |> SelectionScope.new(status)
      |> SelectionScope.select_all_matching(filter)
      |> SelectionScope.count()

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
    |> assign(:page_group_ids, Enum.map(groups, & &1.id))
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

  defp maybe_refresh_group_row(socket, nil), do: socket
  defp maybe_refresh_group_row(socket, id), do: refresh_group_row(socket, id)

  # Fires (or re-fires) the group match search asynchronously -- the page
  # this replaced ran two synchronous relay calls inline in a keystroke
  # handler and froze while they were in flight, which is exactly what
  # `start_async/3` exists to avoid. `phx-debounce="300"` on the modal's
  # input (see Components.match_search_modal/1) keeps every keystroke from
  # spawning its own request; the token here is what keeps a slow response
  # from an earlier one from clobbering a newer one that already landed.
  #
  # A blank query (the group's own display title, `PathAnchor`'s
  # "Loose files" fallback, or an emptied search box) is refused before
  # spawning a task at all: `Metadata.search/3`'s relay adapter treats an
  # empty query as invalid, so there is nothing useful to send.
  defp run_match_search(socket, query) do
    if String.trim(query) == "" do
      assign(socket, :match_search, %{socket.assigns.match_search | results: [], searching: false})
    else
      token = socket.assigns.match_search_token + 1
      group_id = socket.assigns.match_search.group_id
      media_type_hint = socket.assigns.match_search.media_type

      library_path =
        Enum.find(
          socket.assigns.library_paths,
          &(&1.id == socket.assigns.selected_library_path_id)
        )

      media_type = search_media_type(library_path, media_type_hint)
      provider = library_path && library_path.tv_metadata_source
      config = Metadata.default_relay_config()

      socket
      |> assign(:match_search_token, token)
      |> start_async(:group_match_search, fn ->
        opts =
          if media_type == :tv_show do
            [media_type: media_type, provider: provider]
          else
            [media_type: media_type]
          end

        {token, group_id, Metadata.search(config, query, opts)}
      end)
    end
  end

  # Scopes the search to the library's own media type where one is knowable,
  # per the design note this feature shipped against: a series library
  # should never offer movie results. A `:mixed` library has no single type
  # to scope by, so this falls back to the group's own `media_type` (already
  # known from its rollup) when the group has one, and otherwise leaves the
  # search unscoped -- `Metadata.search/3` defaults an unscoped query to a
  # movie search.
  defp search_media_type(%{type: :movies}, _hint), do: :movie
  defp search_media_type(%{type: :series}, _hint), do: :tv_show
  defp search_media_type(%{type: :mixed}, "tv_show"), do: :tv_show
  defp search_media_type(%{type: :mixed}, "movie"), do: :movie
  defp search_media_type(_library_path, _hint), do: nil

  defp stale_match_search?(socket, token, group_id) do
    case socket.assigns.match_search do
      nil -> true
      %{group_id: ^group_id} -> socket.assigns.match_search_token != token
      _different_group -> true
    end
  end

  defp apply_search_result(state, {:ok, results}) do
    %{state | results: results, searching: false, error: nil}
  end

  defp apply_search_result(state, {:error, reason}) do
    Logger.warning("Group match search failed", reason: inspect(reason))
    %{state | results: [], searching: false, error: "Search failed. Try again."}
  end

  defp apply_selected_match(socket, group_id, result) do
    case ImportGroups.change_match(group_id, match_from_result(result)) do
      {:ok, _group} ->
        {:noreply,
         socket
         |> assign(:match_search, nil)
         |> put_flash(:info, "Updated the match for this group.")
         |> load_groups()
         |> refresh_counts()}

      {:error, :not_pending} ->
        {:noreply,
         socket
         |> assign(:match_search, nil)
         |> put_flash(:error, "That group has already been decided.")
         |> load_groups()
         |> refresh_counts()}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(:match_search, nil)
         |> put_flash(:error, "That group is no longer available.")
         |> load_groups()
         |> refresh_counts()}
    end
  end

  # `result.provider` is the search result's own provider tag -- `:tvdb` for
  # a TVDB result, `:metadata_relay` for a TMDB one (the relay's TMDB search
  # stamps every result that way; see `SearchResult.from_api_response/2`) --
  # so this mirrors `MetadataMatcher`'s own `if result.provider == :tvdb, do:
  # :tvdb, else: :tmdb` convention rather than trusting the tag's literal
  # value. This, not a hardcoded `"tmdb"`, is what closes the bug the design
  # flagged in the code this replaced: a TVDB library's corrected match must
  # not get mis-stamped as TMDB.
  defp match_from_result(result) do
    %{
      provider_id: result.provider_id,
      provider_type: if(result.provider == :tvdb, do: :tvdb, else: :tmdb),
      title: result.title,
      year: result.year,
      media_type: result.media_type
    }
  end
end
