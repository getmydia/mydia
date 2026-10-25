defmodule MydiaWeb.ImportMediaLive.Index do
  @moduledoc """
  Import Media: start a run, watch it, stop it, then review what it found.

  The run itself lives in Oban, so the run-control section holds no import
  progress of its own beyond what it reads back. The review section below it
  is a streamed, keyset-paged table of `Mydia.Library.ImportCandidateGroup`
  rows (one row per anchor folder, not one per file), computed at query time
  by `Mydia.ImportCandidates.page/2` from `import_candidates` rows -- so
  opening this page never loads more than one page of groups regardless of
  how large the library is, and there is no separate rollup row to keep in
  sync with what a rescan or a review decision changes underneath it.
  """
  use MydiaWeb, :live_view

  alias Mydia.{Library, Settings}
  alias Mydia.ImportCandidates
  alias Mydia.Jobs.ImportRun, as: ImportRunJob
  alias Mydia.Library.{ImportCandidate, ImportCandidateGroup, ImportRun, SelectionScope}
  alias Mydia.Metadata.TvProvider
  alias MydiaWeb.Live.Authorization
  alias MydiaWeb.ImportMediaLive.{Components, MatchSearch, MatchSearchModal, RunControl}
  alias MydiaWeb.ImportMediaLive.Expansion
  import MydiaWeb.ImportMediaLive.LibraryResolver, only: [resolve_library_path_id: 2]
  import MydiaWeb.ImportMediaLive.Messages, only: [cleared_message: 1, queue_message: 2]

  # `phx-value-band` is client-controlled, so the atom it names is looked up
  # rather than converted. An unknown value is a silent no-op because there is
  # no form state to explain a rejection to.
  # `:ignored` and `:queued` are not confidence bands -- they are statuses --
  # but they ride the same chip row and the same client-controlled atom
  # lookup as the real bands, and load_groups/1 translates them into
  # ImportCandidates.page/2's `:status` option rather than its `:band` option
  # (which has no clause for either and would raise).
  @bands %{
    "all" => :all,
    "ready" => :ready,
    "needs_attention" => :needs_attention,
    "no_match" => :no_match,
    "queued" => :queued,
    "ignored" => :ignored
  }

  @empty_band_counts %{ready: 0, needs_attention: 0, no_match: 0, queued: 0, ignored: 0, total: 0}

  # How long an :import_candidates_changed burst is allowed to coalesce into
  # one refresh. The scanner and the match phase can each broadcast many of
  # these in quick succession during an active run -- every one otherwise
  # re-triggering refresh_counts/1's full band_counts/1 read (every pending
  # group row, once per importable library path) on every open page. Mirrors
  # Jobs.ImportRun's own @broadcast_ms_interval for progress updates, just
  # applied on the receiving end here instead of the sending end there, since
  # this broadcast has no single producer to throttle.
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
        Phoenix.PubSub.subscribe(Mydia.PubSub, "import_candidates:#{selected_library_path_id}")
      end
    end

    socket =
      socket
      |> assign(:page_title, gettext("Import Media"))
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
      # Guards the :import_candidates_changed debounce below: true while a
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
      # The bulk delete confirmation, nil when closed, otherwise
      # `%{scope:, files:, groups:}`: the selection as it was counted when the
      # operator clicked Delete files, which is the one `delete_selected` deletes.
      |> assign(:delete_confirm, nil)
      |> stream_configure(:groups,
        dom_id: fn group -> "group-#{ImportCandidateGroup.dom_id(group)}" end
      )
      |> stream_configure(:members, dom_id: fn candidate -> "candidate-#{candidate.id}" end)
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
          {:noreply,
           put_flash(socket, :error, gettext("That library is already being imported."))}
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
         {:ok, counts} <- ImportCandidates.clear_for_library(path_id) do
      {:noreply,
       socket
       |> put_flash(:info, cleared_message(counts))
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
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Stop this library's scan before clearing results.")
         )}
    end
  end

  def handle_event("import_all_results", _params, socket) do
    with :ok <- Authorization.authorize_import_media(socket),
         library_path_id when is_binary(library_path_id) <-
           socket.assigns.selected_library_path_id do
      {:noreply,
       socket
       |> queue_result(ImportCandidates.queue_accept_all_matched(library_path_id))}
    else
      {:unauthorized, socket} ->
        {:noreply, socket}

      nil ->
        {:noreply,
         put_flash(socket, :error, gettext("Select a library before importing results."))}
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
        {status, _band} = status_for_band(band)

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
    {status, _band} = status_for_band(socket.assigns.band)

    {:noreply,
     socket
     |> assign(:search, q)
     |> assign(:cursor, nil)
     |> assign(:cursor_stack, [])
     # A selection made under one search must not survive into another: in
     # :filter mode select_all_matching/1 captures the current :q, and both
     # SelectionScope.selected?/2 (checkbox state) and to_query/1 (what
     # accept_selected/dismiss_selected act on) would otherwise disagree with
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

  def handle_event("toggle_group", %{"id" => anchor_key}, socket) do
    socket =
      assign(socket, :selection, SelectionScope.toggle(socket.assigns.selection, anchor_key))

    {:noreply, refresh_group_row(socket, anchor_key)}
  end

  def handle_event("select_current_page", _params, socket) do
    {status, _band} = status_for_band(socket.assigns.band)

    selection =
      socket.assigns.selected_library_path_id
      |> SelectionScope.new(status)
      |> SelectionScope.select_page(socket.assigns.page_group_ids)

    {:noreply, socket |> assign(:selection, selection) |> load_groups()}
  end

  def handle_event("select_all_matching", _params, socket) do
    {status, page_band} = status_for_band(socket.assigns.band)
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
      {:noreply, queue_result(socket, ImportCandidates.queue_accept(socket.assigns.selection))}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("dismiss_selected", _params, socket) do
    run_bulk_action(socket, &ImportCandidates.dismiss/1, fn {:ok, count} ->
      ngettext("Dismissed %{count} group.", "Dismissed %{count} groups.", count)
    end)
  end

  def handle_event("restore_selected", _params, socket) do
    run_bulk_action(socket, &ImportCandidates.restore/1, fn {:ok, count} ->
      ngettext(
        "Restored %{count} group to pending.",
        "Restored %{count} groups to pending.",
        count
      )
    end)
  end

  def handle_event("rematch_selected", _params, socket) do
    run_bulk_action(socket, &ImportCandidates.queue_rematch/1, fn {:ok, %{queued: queued}} ->
      ngettext(
        "Queued %{count} group for re-matching.",
        "Queued %{count} groups for re-matching.",
        queued
      )
    end)
  end

  def handle_event("cancel_queued_selected", _params, socket) do
    run_bulk_action(socket, &ImportCandidates.cancel_queued/1, fn {:ok, %{returned: returned}} ->
      ngettext(
        "Returned %{count} group to review.",
        "Returned %{count} groups to review.",
        returned
      )
    end)
  end

  # One file straight from its member row. The button's `data-confirm` is the
  # confirmation; the unlink runs in `Jobs.DeleteImportCandidates`, so this only
  # stamps the marker and the row reads "Deleting…" straight away. Deleting
  # bytes is gated on the delete permission, not the import one the rest of
  # this page uses.
  def handle_event("delete_member", %{"candidate_id" => id}, socket) do
    with :ok <- Authorization.authorize_delete_media(socket) do
      case ImportCandidates.queue_delete_candidate(id) do
        {:ok, candidate} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             gettext("Deleting %{filename}.", filename: Path.basename(candidate.relative_path))
           )
           |> refresh_expanded_members()
           |> refresh_counts()}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :info, gettext("That file is no longer pending."))}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Could not queue the delete: %{reason}", reason: inspect(reason))
           )}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  # Opens the confirmation with the exact file count, counted on click rather
  # than in `load_groups/1`: it is one aggregate the page only needs when
  # someone is about to delete.
  def handle_event("confirm_delete_selected", _params, socket) do
    with :ok <- Authorization.authorize_delete_media(socket) do
      {:noreply, open_delete_confirm(socket, socket.assigns.selection)}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("cancel_delete_selected", _params, socket) do
    {:noreply, assign(socket, :delete_confirm, nil)}
  end

  # Only ever acts on an open confirmation. An event sent without one (a stale
  # tab, a crafted message) queues nothing, because the count the operator saw
  # is what makes this delete safe to run.
  def handle_event("delete_selected", _params, socket) do
    with %{} = confirm <- socket.assigns.delete_confirm,
         :ok <- Authorization.authorize_delete_media(socket) do
      {:noreply, queue_confirmed_delete(socket, confirm)}
    else
      nil -> {:noreply, socket}
      {:unauthorized, socket} -> {:noreply, assign(socket, :delete_confirm, nil)}
    end
  end

  # `expanded_ids` tracks which groups are visually open (the chevron).
  # Expanding a group populates `@streams.members` with its candidates and
  # collapses any previously open group so that only the active group shows
  # as expanded and the member list matches the open chevron.
  def handle_event("expand_group", %{"id" => anchor_key}, socket) do
    library_path_id = socket.assigns.selected_library_path_id

    if socket.assigns.expanded_group_id == anchor_key do
      # Collapsing the currently open group
      socket =
        socket
        |> assign(:expanded_ids, MapSet.delete(socket.assigns.expanded_ids, anchor_key))
        |> assign(:expanded_group_id, nil)
        |> stream(:members, [], reset: true)
        |> refresh_group_row(anchor_key)

      {:noreply, socket}
    else
      # Expanding a new group: collapse any previously expanded group so
      # state stays in sync and only the active group shows open.
      old_expanded_ids = socket.assigns.expanded_ids

      socket =
        socket
        |> assign(:expanded_ids, MapSet.new([anchor_key]))
        |> assign(:expanded_group_id, anchor_key)
        |> stream(:members, ImportCandidates.members(library_path_id, anchor_key), reset: true)
        |> refresh_group_row(anchor_key)

      # Redraw any rows that were previously expanded so their chevrons close
      socket =
        Enum.reduce(old_expanded_ids, socket, fn old_id, acc ->
          if old_id != anchor_key, do: refresh_group_row(acc, old_id), else: acc
        end)

      {:noreply, socket}
    end
  end

  def handle_event("update_member_episode", %{"candidate_id" => id} = params, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      season = Map.get(params, "season")
      episode = Map.get(params, "episode")

      case ImportCandidates.update_member_episode(id, season, episode) do
        {:ok, %ImportCandidate{}} ->
          {:noreply, refresh_expanded_members(socket)}

        {:error, _reason} ->
          {:noreply, socket}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  # The escape hatch for a group no provider carries: build the show straight
  # from its folder name instead of waiting on a match that will never come.
  # `total` is read before the call, not after: on success `create_local_show/2`
  # stamps every leftover candidate with a synthetic `provider_type: "local"`
  # identity so a second call is refused, and the difference between the
  # before/after member counts is the only trace of how many files it linked.
  # A file with no parsed episode number stays unlinked rather than guessed
  # at, and the flash says so rather than reporting a clean success for a
  # partially-done action -- the failure mode this project has already
  # corrected twice.
  def handle_event("create_local_show", %{"id" => anchor_key}, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      library_path_id = socket.assigns.selected_library_path_id
      total = ImportCandidates.member_count(library_path_id, anchor_key)

      case ImportCandidates.create_local_show(library_path_id, anchor_key) do
        {:ok, item} ->
          remaining = ImportCandidates.member_count(library_path_id, anchor_key)
          linked = total - remaining

          message =
            if remaining > 0 do
              ngettext(
                "Created %{title} and linked %{linked} of %{count} file. %{remaining} had no episode number.",
                "Created %{title} and linked %{linked} of %{count} files. %{remaining} had no episode number.",
                total,
                title: item.title,
                linked: linked,
                remaining: remaining
              )
            else
              gettext("Created %{title} from the folder name.", title: item.title)
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
          {:noreply,
           put_flash(socket, :info, gettext("That show was already created from this folder."))}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Could not create the show: %{reason}", reason: inspect(reason))
           )}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  # Dismiss used to be a one-way door: a rescan can never bring a group back
  # (`ImportCandidates.upsert/1` preserves `dismissed_at` on purpose), and
  # until now there was no UI that could even see a dismissed group to
  # reconsider it. This is the way back -- only reachable from the Ignored
  # view's own row, which is the only place `restore_group` is rendered, but
  # a stale click after another tab already restored the same group is a
  # normal, silent `{:ok, 0}`.
  def handle_event("restore_group", %{"id" => anchor_key}, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      scope =
        socket.assigns.selected_library_path_id
        |> SelectionScope.new("ignored")
        |> SelectionScope.select_page([anchor_key])

      case ImportCandidates.restore(scope) do
        {:ok, count} when count > 0 ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Restored to pending."))
           |> load_groups()
           |> refresh_counts()}

        {:ok, 0} ->
          {:noreply, put_flash(socket, :info, gettext("That group is no longer ignored."))}
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
  def handle_event("open_match_search", %{"id" => anchor_key}, socket) do
    case ImportCandidates.get_group(socket.assigns.selected_library_path_id, anchor_key) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("That group is no longer available."))}

      group ->
        {:noreply, MatchSearch.open(socket, group)}
    end
  end

  def handle_event("match_search_query", %{"q" => query}, socket),
    do: {:noreply, MatchSearch.change_query(socket, query)}

  def handle_event("match_search_provider", %{"provider" => provider}, socket),
    do: {:noreply, MatchSearch.change_provider(socket, provider)}

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
           put_flash(
             socket,
             :error,
             gettext("That result is no longer available. Search again.")
           )}

        {%{anchor_key: anchor_key}, result} ->
          apply_selected_match(socket, anchor_key, result)
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:group_match_search, {:ok, payload}, socket),
    do: {:noreply, MatchSearch.apply_result(socket, payload)}

  def handle_async(:group_match_search, {:exit, reason}, socket),
    do: {:noreply, MatchSearch.crashed(socket, reason)}

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

  def handle_info({:import_candidates_changed, _library_path_id}, socket) do
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
     |> load_groups(preserve_expansion: true)
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
         put_flash(socket, :error, gettext("Select that library before starting its scan."))}

      Enum.any?(socket.assigns.importable_library_paths, &(&1.id == path_id)) ->
        :ok

      true ->
        {:unsupported_type,
         put_flash(
           socket,
           :error,
           gettext("Only movie, TV and mixed libraries can be imported.")
         )}
    end
  end

  defp queue_result(socket, {:ok, %{queued: queued, skipped: skipped}}) do
    socket
    |> put_flash(:info, queue_message(queued, skipped))
    |> assign(:selection, SelectionScope.clear(socket.assigns.selection))
    |> load_groups()
    |> refresh_counts()
  end

  # The shape every bulk button shares: authorize, run the context call on the
  # selection, flash, clear the selection, reload. `message` pattern-matches the
  # result, so an unexpected return still crashes rather than flashing nonsense.
  defp run_bulk_action(socket, action, message) do
    with :ok <- Authorization.authorize_import_media(socket) do
      result = action.(socket.assigns.selection)

      {:noreply,
       socket
       |> put_flash(:info, message.(result))
       |> assign(:selection, SelectionScope.clear(socket.assigns.selection))
       |> load_groups()
       |> refresh_counts()}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
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
      if previous_id,
        do: Phoenix.PubSub.unsubscribe(Mydia.PubSub, "import_candidates:#{previous_id}")

      if previous_run,
        do: Phoenix.PubSub.unsubscribe(Mydia.PubSub, ImportRunJob.progress_topic(previous_run.id))

      Phoenix.PubSub.subscribe(Mydia.PubSub, "import_candidates:#{id}")

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
  # exist in each band or in any other library -- only accepting, dismissing,
  # switching libraries, or another session's own accept/dismiss (over
  # PubSub) do. So this reloads only the current page of groups; callers
  # that know the counts actually changed also call refresh_counts/1.
  # `preserve_expansion: true` is the PubSub refresh's; see Expansion.apply_page/3.
  defp load_groups(socket, opts \\ []) do
    library_path_id = socket.assigns.selected_library_path_id
    band = socket.assigns.band
    {status, page_band} = status_for_band(band)
    filter = %{band: page_band, q: socket.assigns.search}

    {groups, next_cursor} =
      ImportCandidates.page(library_path_id,
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

    # Reads the outgoing `@page_group_ids`, so it runs before they're replaced.
    socket
    |> Expansion.apply_page(groups, Keyword.get(opts, :preserve_expansion, false))
    |> stream(:groups, groups, reset: true)
    |> assign(:page_group_ids, Enum.map(groups, & &1.id))
    |> assign(:next_cursor, next_cursor)
    |> assign(:matching_count, matching_count)
  end

  # `:queued` and `:ignored` are statuses, not confidence bands. Neither is a
  # clause of ImportCandidates.page/2's `:band` option, which would raise, so
  # both go through `:status` with the band itself left at `:all` (a queued or
  # dismissed group's own confidence band plays no part in those views).
  defp status_for_band(:ignored), do: {"ignored", :all}
  defp status_for_band(:queued), do: {"queued", :all}
  defp status_for_band(band), do: {"pending", band}

  # Recomputes the counts that only change when a group's status changes,
  # not on every page move or search keystroke: the current library's band
  # breakdown for the filter chips, the Ignored chip's own count, and every
  # importable library's pending total for the picker. band_counts/1 loads
  # every pending group row for each library path it is asked about, so this
  # is deliberately called only from mount/1, switch_library/2,
  # accept/dismiss/restore, and the PubSub handler -- never from
  # load_groups/1, which paging and search both go through.
  defp refresh_counts(socket) do
    library_path_id = socket.assigns.selected_library_path_id

    active_runs_by_library =
      Library.list_active_import_runs()
      |> Map.new(&{&1.library_path_id, &1})

    band_counts =
      library_path_id
      |> ImportCandidates.band_counts()
      |> Map.put(:ignored, ImportCandidates.count_by_status(library_path_id, "ignored"))
      |> Map.put(:queued, ImportCandidates.count_by_status(library_path_id, "queued"))

    socket
    |> assign(:band_counts, band_counts)
    |> assign(:active_runs_by_library, active_runs_by_library)
    |> assign(
      :library_group_counts,
      Map.new(socket.assigns.importable_library_paths, fn path ->
        {path.id, ImportCandidates.band_counts(path.id).total}
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
  # this re-reads the one row by anchor key rather than searching the
  # in-memory stream. A group that has vanished between render and click
  # (accepted or dismissed from another session) is a silent no-op: the row
  # will drop out on the next full `load_groups/1` regardless.
  defp refresh_group_row(socket, anchor_key) do
    library_path_id = socket.assigns.selected_library_path_id
    {status, _band} = status_for_band(socket.assigns.band)

    case ImportCandidates.get_group(library_path_id, anchor_key, status: status) do
      nil -> socket
      group -> stream_insert(socket, :groups, group)
    end
  end

  # Reloads the currently-expanded group's members wholesale, same as
  # `expand_group`'s own initial population, and also re-inserts the parent
  # group row. Confirmed by hand: resetting the `:members` stream alone is
  # not enough. `Components.group_row/1`'s `members` prop is computed as
  # `if @expanded_group_id == group.id, do: @streams.members, else: []`
  # inside the `:groups` `:for` in index.html.heex, so the `<ul
  # phx-update="stream">` reading it only exists inside that group's own
  # already-rendered output. A `:members`-only change does not, by itself,
  # cause LiveView to revisit that specific `:groups` iteration and re-invoke
  # the component with the fresh prop; `refresh_group_row/2`'s own
  # `stream_insert/3` on `:groups` is what forces that row to re-render, the
  # same way toggling a group already relies on it for the chevron.
  defp refresh_expanded_members(socket) do
    case socket.assigns.expanded_group_id do
      nil ->
        socket

      anchor_key ->
        library_path_id = socket.assigns.selected_library_path_id

        socket
        |> stream(:members, ImportCandidates.members(library_path_id, anchor_key), reset: true)
        |> refresh_group_row(anchor_key)
    end
  end

  # The confirmation keeps the selection it counted, not just the numbers, and
  # `delete_selected` deletes that scope: a selection changed behind the dialog
  # is never what gets deleted.
  defp open_delete_confirm(socket, scope) do
    case ImportCandidates.count_files(scope) do
      0 ->
        socket
        |> assign(:delete_confirm, nil)
        |> put_flash(:info, gettext("Nothing in the selection can be deleted."))

      files ->
        assign(socket, :delete_confirm, %{
          scope: scope,
          files: files,
          groups: SelectionScope.count(scope)
        })
    end
  end

  # `expected_files` makes the delete all-or-nothing against the count the
  # operator confirmed. When files joined or left the selection behind the
  # dialog, nothing is queued and the dialog reopens with the new count.
  defp queue_confirmed_delete(socket, %{scope: scope, files: files}) do
    case ImportCandidates.queue_delete(scope, expected_files: files) do
      {:ok, %{files: queued}} ->
        socket
        |> assign(:delete_confirm, nil)
        |> put_flash(
          :info,
          ngettext(
            "Deleting %{count} file in the background.",
            "Deleting %{count} files in the background.",
            queued
          )
        )
        |> assign(:selection, SelectionScope.clear(socket.assigns.selection))
        |> load_groups()
        |> refresh_counts()

      {:error, {:count_changed, _current}} ->
        socket
        |> put_flash(
          :error,
          gettext(
            "The selection changed since you confirmed. Check the new count before deleting."
          )
        )
        |> open_delete_confirm(scope)

      {:error, reason} ->
        socket
        |> assign(:delete_confirm, nil)
        |> put_flash(
          :error,
          gettext("Could not queue the delete: %{reason}", reason: inspect(reason))
        )
    end
  end

  defp apply_selected_match(socket, anchor_key, result) do
    library_path_id = socket.assigns.selected_library_path_id

    match = MatchSearch.match_from_result(result)

    case ImportCandidates.change_match(library_path_id, anchor_key, match) do
      {:ok, _count} ->
        {:noreply,
         socket
         |> assign(:match_search, nil)
         |> put_flash(:info, gettext("Updated the match for this group."))
         |> load_groups()
         |> refresh_counts()}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(:match_search, nil)
         |> put_flash(:error, gettext("That group is no longer available."))
         |> load_groups()
         |> refresh_counts()}
    end
  end
end
