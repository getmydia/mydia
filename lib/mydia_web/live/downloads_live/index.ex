defmodule MydiaWeb.DownloadsLive.Index do
  use MydiaWeb, :live_view
  alias Mydia.Downloads
  alias Mydia.Downloads.AutoRejectCap
  alias Mydia.Downloads.Blacklists
  alias Mydia.Downloads.Download
  alias Mydia.Downloads.ExternalTorrents
  alias Mydia.Downloads.ImportCandidates
  alias Mydia.Downloads.StallDetector
  alias Mydia.Downloads.Structs.DownloadMetadata
  alias Mydia.Library.Structs.Quality
  alias Mydia.Library
  alias Mydia.Media
  alias Mydia.Settings
  alias Phoenix.PubSub
  alias MydiaWeb.Live.Authorization
  alias MydiaWeb.DownloadsLive.Components
  alias MydiaWeb.DownloadsLive.DetailDrawer
  alias MydiaWeb.DownloadsLive.Filters
  alias MydiaWeb.DownloadsLive.ListComponents
  alias MydiaWeb.DownloadsLive.ListView
  alias MydiaWeb.DownloadsLive.Sorting
  alias MydiaWeb.DownloadsLive.Summary
  alias MydiaWeb.DownloadsLive.Tab
  alias Mydia.Settings.DownloadClientConfig
  alias MydiaWeb.DownloadsLive.MatchDialog
  import MydiaWeb.DownloadsLive.Format
  import MydiaWeb.DownloadsLive.ListView, only: [get_metadata_value: 2]
  import MydiaWeb.Formatters

  require Logger

  @items_per_page 50

  @default_sort "added_desc"

  # While a download is in flight, its progress (debrid swarm %, local fetch %)
  # is synthesized live from the client/provider on each poll and is NOT
  # persisted to the DB. PubSub broadcasts only fire on DB row changes, so
  # without a periodic re-render the bar freezes at whatever it showed at page
  # load. This timer re-polls + re-renders the Downloads tab while work is active.
  @progress_refresh_interval_ms 3_000

  @allowed_sort_fields Sorting.allowed_fields()

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to download updates for real-time progress
    if connected?(socket) do
      PubSub.subscribe(Mydia.PubSub, "downloads")
      schedule_progress_refresh()
    end

    {:ok,
     socket
     |> assign(:page_title, "Downloads")
     |> assign(:active_tab, :downloads)
     |> assign(:view, :active)
     |> assign(:sort_by, @default_sort)
     |> assign(:selected_ids, MapSet.new())
     |> assign(:selection_mode, false)
     |> assign(:page, 0)
     |> assign(:has_more, true)
     # Clear-completed modal state
     |> assign(:show_clear_modal, false)
     |> assign(:delete_files, false)
     |> assign(:clearable_count, 0)
     # Issues tab state
     |> assign(:issues_counts, %{unmatched: 0, unresolved: 0, other: 0})
     # Match files modal state (manual matching of a failed import's file listing)
     |> assign(:match_files_modal, nil)
     |> assign(:match_files_error, nil)
     # Derived view of client torrents Mydia does not manage. Read from the
     # ExternalTorrents cache, never from the database.
     |> assign(:scan, ExternalTorrents.get())
     |> assign(:removed_client_groups, [])
     |> assign(:search_open_for, nil)
     |> assign(:library_search_value, "")
     |> assign(:library_search_results, [])
     # Match / re-match modal state (in-flight correction + post-import re-match)
     |> assign(:match_modal, nil)
     |> assign(:stall_grace_map, Settings.download_client_grace_map())
     |> assign(:stale_status, nil)
     |> assign(:loaded?, false)
     |> assign(:filters, %Filters{})
     |> assign(:summary, %Summary{})
     |> assign(:tab_counts, %{downloads: 0, issues: 0})
     |> assign(:tabs, [])
     |> assign(:client_options, [])
     |> assign(:client_urls, client_urls())
     |> assign(:drawer_id, nil)
     |> assign(:drawer_download, nil)
     |> assign(:rows_by_id, %{})
     |> assign(:downloads_empty?, true)
     # Initialize all streams
     |> stream(:downloads, [])
     |> stream(:needs_matching, [])
     |> stream(:external_torrents, [])
     |> stream(:unresolved_downloads, [])
     |> stream(:other_issues, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    params = ListView.normalize_legacy(params)
    tab = ListView.parse_tab(params["tab"])
    view = ListView.parse_view(params["view"])
    filters = ListView.parse_filters(params, {tab, view})
    scope_changed? = {tab, view} != {socket.assigns.active_tab, socket.assigns.view}

    list_changed? =
      not socket.assigns.loaded? or scope_changed? or filters != socket.assigns.filters

    socket =
      socket
      |> assign(:active_tab, tab)
      |> assign(:view, view)
      |> assign(:filters, filters)
      |> assign(:drawer_id, blank_to_nil(params["download"]))

    socket =
      if list_changed? do
        socket |> reset_list(scope_changed?) |> load_downloads()
      else
        assign_drawer(socket, nil)
      end

    {:noreply, socket}
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  # A new tab or view resets the sort: a view-specific sort (ratio on
  # Imported) is not an option in the next view.
  defp reset_list(socket, scope_changed?) do
    # Any list change clears the selection: a batch action must not reach rows
    # the new tab, view or filters hide.
    socket =
      socket
      |> assign(:page, 0)
      |> assign(:selected_ids, MapSet.new())
      |> assign(:selection_mode, false)

    if scope_changed?, do: assign(socket, :sort_by, @default_sort), else: socket
  end

  # Drops ?download=<id> from the URL; a no-op when no drawer is open.
  defp close_drawer(%{assigns: %{drawer_id: nil}} = socket), do: socket

  defp close_drawer(socket),
    do: push_patch(socket, to: downloads_path(socket, download: nil))

  # Builds /downloads?... from the current state with `overrides` applied.
  # Defaults (Downloads tab, Active view, nil values) are left out so links
  # stay short. Takes the socket or its assigns.
  defp downloads_path(%Phoenix.LiveView.Socket{assigns: assigns}, overrides),
    do: downloads_path(assigns, overrides)

  defp downloads_path(assigns, overrides) do
    %{active_tab: tab, view: view, drawer_id: drawer_id, filters: filters} = assigns

    values =
      Map.merge(
        %{
          tab: tab,
          view: view,
          q: filters.q,
          client: filters.client,
          status: filters.status,
          download: drawer_id
        },
        Map.new(overrides)
      )

    # Fixed key order, so the same state always produces the same URL.
    params =
      [:tab, :view, :q, :client, :status, :download]
      |> Enum.map(&{&1, values[&1]})
      |> Enum.reject(fn {key, value} ->
        is_nil(value) or {key, value} in [{:tab, :downloads}, {:view, :active}]
      end)
      |> Enum.map(fn {key, value} -> {key, to_string(value)} end)

    case params do
      [] -> ~p"/downloads"
      params -> ~p"/downloads?#{params}"
    end
  end

  defp assign_tabs(socket), do: assign(socket, :tabs, tabs(socket.assigns))

  # Tab links keep the search and client, and drop the view, the status and
  # the open drawer: none of them carries over to another tab.
  defp tabs(assigns) do
    href = &downloads_path(assigns, tab: &1, view: nil, status: nil, download: nil)

    [
      %Tab{
        key: :downloads,
        label: "Downloads",
        icon: "hero-arrow-down-tray",
        href: href.(:downloads),
        count: assigns.tab_counts.downloads,
        dot?: assigns.summary.stalled > 0
      },
      %Tab{
        key: :issues,
        label: "Issues",
        icon: "hero-exclamation-triangle",
        href: href.(:issues),
        count: assigns.tab_counts.issues,
        tone: :error
      },
      # Neutral on purpose: unmanaged torrents are not problems.
      %Tab{
        key: :external,
        label: "External",
        icon: "hero-inbox-stack",
        href: href.(:external),
        count: length(assigns.scan.external)
      }
    ]
  end

  defp client_urls do
    Settings.list_download_client_configs()
    |> Enum.flat_map(fn config ->
      case DownloadClientConfig.web_ui_url(config) do
        nil -> []
        url -> [{config.name, url}]
      end
    end)
    |> Map.new()
  end

  @impl true
  def handle_event("set_view", %{"view" => view}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         downloads_path(socket,
           view: ListView.parse_view(view),
           status: nil,
           download: nil
         )
     )}
  end

  def handle_event("filter", params, socket) do
    filters =
      ListView.parse_filters(params, {socket.assigns.active_tab, socket.assigns.view})

    {:noreply,
     push_patch(socket,
       to: downloads_path(socket, q: filters.q, client: filters.client, status: filters.status)
     )}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: downloads_path(socket, q: nil, client: nil, status: nil))}
  end

  def handle_event("remove_filter", %{"key" => key}, socket) when key in ~w(q client status) do
    {:noreply,
     push_patch(socket, to: downloads_path(socket, [{String.to_existing_atom(key), nil}]))}
  end

  def handle_event("open_details", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: downloads_path(socket, download: id))}
  end

  def handle_event("close_details", _params, socket) do
    {:noreply, close_drawer(socket)}
  end

  def handle_event("sort", %{"sort_by" => sort_by}, socket)
      when sort_by in @allowed_sort_fields do
    {:noreply,
     socket
     |> assign(:sort_by, sort_by)
     |> assign(:page, 0)
     |> load_downloads()}
  end

  # Unknown sort value: fall back to the current sort rather than raising.
  def handle_event("sort", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_select", %{"id" => id}, socket) do
    selected_ids =
      if MapSet.member?(socket.assigns.selected_ids, id) do
        MapSet.delete(socket.assigns.selected_ids, id)
      else
        MapSet.put(socket.assigns.selected_ids, id)
      end

    {:noreply,
     socket
     |> assign(:selected_ids, selected_ids)
     |> assign(:selection_mode, true)}
  end

  def handle_event("toggle_select_all", _params, socket) do
    if socket.assigns.selection_mode and MapSet.size(socket.assigns.selected_ids) > 0 do
      # Exit selection mode and clear selections
      {:noreply,
       socket
       |> assign(:selected_ids, MapSet.new())
       |> assign(:selection_mode, false)
       |> reload_stream()}
    else
      # Enter selection mode and select all visible downloads
      downloads = get_current_downloads(socket)
      selected_ids = downloads |> Enum.map(& &1.id) |> MapSet.new()

      {:noreply,
       socket
       |> assign(:selected_ids, selected_ids)
       |> assign(:selection_mode, true)
       |> reload_stream()}
    end
  end

  def handle_event("cancel_download", %{"id" => id}, socket) do
    start_removal(socket, id, fn _download -> {"cancel", [delete_files: false]} end)
  end

  def handle_event("pause_download", %{"id" => id}, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      with_download(socket, id, fn download ->
        case Downloads.pause_download(download) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Download paused")
             |> load_downloads()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to pause download: #{inspect(reason)}")}
        end
      end)
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("resume_download", %{"id" => id}, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      with_download(socket, id, fn download ->
        case Downloads.resume_download(download) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Download resumed")
             |> load_downloads()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to resume download: #{inspect(reason)}")}
        end
      end)
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("retry_download", %{"id" => id}, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      with_download(socket, id, [preload: [:media_item, :episode]], fn download ->
        # Clear error message if any
        case Downloads.update_download(download, %{error_message: nil}) do
          {:ok, updated} ->
            # Convert metadata to struct for type-safe access
            metadata = DownloadMetadata.from_map(updated.metadata)

            # Re-add to client using the original download URL
            search_result = %Mydia.Indexers.SearchResult{
              download_url: updated.download_url,
              title: updated.title,
              indexer: updated.indexer,
              size: metadata.size,
              seeders: metadata.seeders,
              leechers: metadata.leechers,
              quality: metadata.quality
            }

            opts =
              []
              |> maybe_add_opt(:media_item_id, updated.media_item_id)
              |> maybe_add_opt(:episode_id, updated.episode_id)
              |> maybe_add_opt(:client_name, updated.download_client)

            # Delete old download record and create new one
            Downloads.delete_download(updated)

            case Downloads.initiate_download(search_result, opts) do
              {:ok, _new_download} ->
                {:noreply,
                 socket
                 |> put_flash(:info, "Download re-initiated")
                 |> load_downloads()}

              {:error, reason} ->
                {:noreply,
                 put_flash(socket, :error, "Failed to retry download: #{inspect(reason)}")}
            end

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to update download")}
        end
      end)
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event(
        "apply_mapping_and_retry",
        %{"remote_prefix" => remote_prefix, "local_prefix" => local_prefix},
        socket
      ) do
    # Persisting a global mapping affects all future imports, so this requires
    # admin rights — matching the Path Mappings admin page — even though
    # single-download retries only need manage-downloads.
    with :ok <-
           Authorization.authorize(
             socket,
             &Mydia.Accounts.Authorization.is_admin?/1,
             "Admin access required to add a path mapping"
           ) do
      case Mydia.Settings.create_path_mapping_config(%{
             remote_prefix: remote_prefix,
             local_prefix: local_prefix
           }) do
        {:ok, mapping} ->
          count = retry_mismatches_under_prefix(mapping.remote_prefix)

          {:noreply,
           socket
           |> put_flash(
             :info,
             "Mapping added. Retrying #{count} affected download#{if count == 1, do: "", else: "s"}."
           )
           |> load_downloads()}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, put_flash(socket, :error, mapping_error_message(changeset))}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("retry_import", %{"id" => id}, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      with_download(socket, id, [preload: [:media_item, :episode]], fn download ->
        # Clear retry metadata and trigger immediate import
        case Downloads.update_download(download, %{
               import_retry_count: 0,
               import_last_error: nil,
               import_next_retry_at: nil,
               import_failed_at: nil
             }) do
          {:ok, updated} ->
            # Enqueue import job with immediate execution
            %{
              "download_id" => updated.id,
              "save_path" => nil,
              "cleanup_client" => true,
              "use_hardlinks" => true
            }
            |> Mydia.Jobs.MediaImport.new()
            |> Oban.insert()

            {:noreply,
             socket
             |> put_flash(:info, "Import retry initiated")
             |> load_downloads()}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to retry import")}
        end
      end)
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  # A "clear", not a "cancel": deleting has always removed the row even when the
  # download's client is disabled or gone, which a cancel no longer does.
  def handle_event("delete_download", %{"id" => id}, socket) do
    start_removal(socket, id, fn _download -> {"clear", [delete_files: true]} end)
  end

  def handle_event("retry_removal", %{"id" => id}, socket) do
    start_removal(socket, id, fn download ->
      {download.removal_kind || "cancel", [delete_files: download.removal_delete_files]}
    end)
  end

  def handle_event("batch_retry", _params, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      selected_ids = MapSet.to_list(socket.assigns.selected_ids)

      results =
        Enum.map(selected_ids, fn id ->
          try do
            case Downloads.get_download(id, preload: [:media_item, :episode]) do
              # Deleted while the selection sat open — nothing left to retry, so
              # it is not counted as a success (issue #281).
              nil ->
                {:error, :not_found}

              download ->
                batch_retry_one(download)
            end
          rescue
            _ -> {:error, :failed}
          end
        end)

      success_count = Enum.count(results, fn {status, _} -> status == :ok end)

      {:noreply,
       socket
       |> assign(:selected_ids, MapSet.new())
       |> assign(:selection_mode, false)
       |> put_flash(:info, "#{success_count} item(s) retried")
       |> load_downloads()}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("batch_delete", _params, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      selected_ids = MapSet.to_list(socket.assigns.selected_ids)

      results =
        Enum.map(selected_ids, fn id ->
          try do
            case Downloads.get_download(id) do
              # Already gone. The operator asked for it removed and it is
              # removed, so this counts toward the total rather than reading as
              # a failure they need to act on (issue #281).
              nil ->
                {:ok, :already_removed}

              # A "clear" for the same reason as delete_download: batch delete
              # is how orphans of a deleted client get cleaned up.
              download ->
                Downloads.request_removal(download, "clear", delete_files: true)
            end
          rescue
            _ -> {:error, :failed}
          end
        end)

      success_count = Enum.count(results, fn {status, _} -> status == :ok end)

      {:noreply,
       socket
       |> assign(:selected_ids, MapSet.new())
       |> assign(:selection_mode, false)
       |> put_flash(:info, "Removing #{success_count} download(s)")
       |> load_downloads()}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("open_clear_completed_modal", _params, socket) do
    # Opening the modal is non-destructive, so it is ungated (the button renders
    # for everyone, matching prior behavior). The destructive submit is gated.
    {:noreply,
     socket
     |> assign(:show_clear_modal, true)
     |> assign(:delete_files, false)
     |> assign(:clearable_count, Downloads.count_completed())}
  end

  def handle_event("close_clear_completed_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_clear_modal, false)
     |> assign(:delete_files, false)}
  end

  def handle_event("toggle_delete_files", params, socket) do
    {:noreply, assign(socket, :delete_files, delete_files?(params))}
  end

  def handle_event("clear_completed", params, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      # Phoenix checkboxes submit the string "true" (or omit the key); coerce to
      # a real boolean so the adapter's [delete_files: boolean()] contract holds.
      delete_files = delete_files?(params)
      {:ok, count} = Downloads.request_clear_all_completed(delete_files: delete_files)

      message =
        if delete_files do
          "Clearing #{count} completed download(s) and deleting their files from disk"
        else
          "Clearing #{count} completed download(s)"
        end

      {:noreply,
       socket
       |> assign(:show_clear_modal, false)
       |> assign(:delete_files, false)
       |> put_flash(:info, message)
       |> load_downloads()}
    else
      {:unauthorized, socket} -> {:noreply, assign(socket, :show_clear_modal, false)}
    end
  end

  def handle_event("clear_single_completed", %{"id" => id}, socket) do
    start_removal(socket, id, fn _download -> {"clear", [delete_files: false]} end)
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more do
      {:noreply,
       socket
       |> update(:page, &(&1 + 1))
       |> load_downloads()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:page, 0)
     |> assign(:client_urls, client_urls())
     |> load_downloads()}
  end

  # --- Issues Tab Event Handlers ---

  def handle_event("adopt_suggestion", params, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      %{"torrent_id" => torrent_id, "media_item_id" => media_item_id} = params
      adopt(socket, torrent_id, media_item_id, Map.get(params, "episode_id"))
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  # The inline library picker sends `download_id` (see LibrarySearchForm), which
  # here carries the derived torrent id rather than a database id.
  def handle_event("adopt_library_match", params, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      %{"download_id" => torrent_id, "media_item_id" => media_item_id} = params

      {:noreply, socket} = adopt(socket, torrent_id, media_item_id, nil)

      {:noreply,
       socket
       |> assign(:search_open_for, nil)
       |> assign(:library_search_value, "")
       |> assign(:library_search_results, [])}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("rescan_external", _params, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      ExternalTorrents.refresh()

      {:noreply,
       socket
       |> put_flash(:info, "Rescanned download clients")
       |> load_downloads()}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("toggle_search", %{"id" => download_id}, socket) do
    current = socket.assigns.search_open_for

    if current == download_id do
      {:noreply,
       socket
       |> assign(:search_open_for, nil)
       |> assign(:library_search_value, "")
       |> assign(:library_search_results, [])}
    else
      {:noreply,
       socket
       |> assign(:search_open_for, download_id)
       |> assign(:library_search_value, "")
       |> assign(:library_search_results, [])}
    end
  end

  def handle_event(
        "library_search",
        %{"library_search" => query, "download_id" => _download_id},
        socket
      ) do
    results =
      if String.length(query) >= 2 do
        socket.assigns.current_scope
        |> Media.list_media_items(search: query)
        |> Enum.take(10)
      else
        []
      end

    {:noreply,
     socket
     |> assign(:library_search_value, query)
     |> assign(:library_search_results, results)}
  end

  # --- Match / re-match modal (in-flight correction + post-import re-match) ---

  def handle_event("open_match_modal", %{"id" => id, "mode" => mode}, socket)
      when mode in ["inflight", "postimport"] do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      with_download(socket, id, [preload: [:media_item]], fn download ->
        dialog =
          socket.assigns.current_scope
          |> MatchDialog.open(download, mode_atom(mode))
          |> then(&MatchDialog.search(&1, &1.query))

        {:noreply, socket |> assign(:match_modal, dialog) |> close_drawer()}
      end)
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("close_match_modal", _params, socket) do
    {:noreply, assign(socket, :match_modal, nil)}
  end

  def handle_event("match_modal_search", %{"q" => query}, socket) do
    {:noreply, update(socket, :match_modal, &MatchDialog.search(&1, query))}
  end

  def handle_event("match_modal_set_type", %{"type" => type}, socket)
      when type in ["movie", "tv_show"] do
    {:noreply, update(socket, :match_modal, &MatchDialog.set_type(&1, media_type_atom(type)))}
  end

  def handle_event("match_modal_pick_item", %{"media_item_id" => media_item_id}, socket) do
    case MatchDialog.select(socket.assigns.match_modal, media_item_id) do
      {:submit, {item_id, episode_id}} -> submit_match(socket, item_id, episode_id)
      {:episodes, dialog} -> {:noreply, assign(socket, :match_modal, dialog)}
    end
  end

  def handle_event("match_modal_show_episodes", %{"media_item_id" => media_item_id}, socket) do
    {:noreply, update(socket, :match_modal, &MatchDialog.show_episodes(&1, media_item_id))}
  end

  def handle_event("match_modal_add_external", %{"provider_id" => provider_id}, socket) do
    with :ok <- Authorization.authorize_create_media(socket) do
      dialog = %{socket.assigns.match_modal | error: nil}

      case MatchDialog.add_external(dialog, provider_id) do
        {:added, item} ->
          case MatchDialog.select(dialog, item.id) do
            {:submit, {item_id, episode_id}} -> submit_match(socket, item_id, episode_id)
            {:episodes, updated} -> {:noreply, assign(socket, :match_modal, updated)}
          end

        {:error, updated} ->
          {:noreply, assign(socket, :match_modal, updated)}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("match_modal_pick_episode", %{"episode_id" => episode_id}, socket) do
    case MatchDialog.select_episode(socket.assigns.match_modal, episode_id) do
      {:submit, {item_id, ep_id}} -> submit_match(socket, item_id, ep_id)
      {:error, dialog} -> {:noreply, assign(socket, :match_modal, dialog)}
    end
  end

  # --- Match files modal (manual file matching on import failure) ---

  def handle_event("open_match_files", %{"id" => id}, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      with_download(socket, id, [preload: [:media_item, :library_path]], fn download ->
        case ImportCandidates.load(download) do
          {:ok, source, candidates} ->
            episodes =
              if download.media_item && download.media_item.type == "tv_show" do
                Media.list_episodes(socket.assigns.current_scope, download.media_item.id)
              else
                []
              end

            {:noreply,
             socket
             |> assign(:match_files_error, nil)
             |> assign(:match_files_modal, %{
               download: download,
               source: source,
               candidates: candidates,
               episodes: episodes
             })}

          {:error, :unavailable} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Mydia could not read this download's folder and has no recorded listing for it."
             )}
        end
      end)
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("close_match_files", _params, socket) do
    {:noreply,
     socket
     |> assign(:match_files_modal, nil)
     |> assign(:match_files_error, nil)}
  end

  def handle_event("match_files_import", params, socket) do
    %{download: modal_download, candidates: candidates} = socket.assigns.match_files_modal

    # Re-read the download at submit time rather than trusting the assign
    # captured when the modal opened. The modal has no way to notice a
    # re-bind: the separate match/re-match modal can rebind this download to
    # a different show while this one stays open, and process_targeted_import/3
    # must build destinations from the CURRENT media_item — trusting the
    # stale struct would link an episode from the OLD show onto files
    # imported under the NEW one.
    #
    # That same re-read is where the row can turn out to be gone entirely — the
    # modal can sit open across an import that deletes it (issue #281) — so the
    # `nil` branch below closes the modal instead of crashing the socket.
    with :ok <- Authorization.authorize_manage_downloads(socket),
         %Download{} = download <-
           Downloads.get_download(modal_download.id, preload: [:media_item]) do
      # Defense in depth: a disabled <select> only stops a normal browser. Never
      # trust a submitted path or target purely from client state — re-derive
      # what's actually allowed from the socket's own candidate list and the
      # download's authoritative (freshly reloaded) media type before building
      # mappings.
      #
      # - Submitted targets arrive keyed by candidate INDEX, with the path
      #   carried separately as a same-indexed hidden input value. Plug's form
      #   decoder splits a bracketed field NAME on "][", so a path like
      #   ".../[Bluray-1080p][Opus 2.0]/ep01.mkv" used as a form key would
      #   decode into nested garbage. Values are never split that way, so the
      #   path travels safely as one.
      # - `valid_paths` drops any path that was never a candidate for this
      #   download, or that is flagged "missing" (gone from disk since the
      #   modal opened): resolve_file_mappings/2 does no path validation of
      #   its own, and existence is only checked much later inside the Oban
      #   job.
      # - `movie?` rejects a "movie" target (episode_id: nil) unless the bound
      #   media item really is a movie, and every episode target is checked
      #   against the download's ACTUAL episode list. Without this, a crafted
      #   or stale submission could link an episode belonging to a different
      #   show onto this download's files — MediaImport.process_targeted_import/3
      #   trusts the submitted episode_id outright and never checks it belongs
      #   to the media item it builds the destination path from.
      valid_paths =
        candidates
        |> Enum.reject(& &1["missing"])
        |> MapSet.new(& &1["path"])

      movie? = download.media_item && download.media_item.type == "movie"

      episodes =
        case download.media_item do
          %{type: "tv_show", id: media_item_id} ->
            Media.list_episodes(socket.assigns.current_scope, media_item_id)

          _other ->
            []
        end

      valid_episode_ids = MapSet.new(episodes, & &1.id)

      path_by_index = Map.get(params, "target_path", %{})

      targets =
        params
        |> Map.get("target", %{})
        |> Enum.map(fn {index, target} -> {Map.get(path_by_index, index), target} end)
        |> Enum.reject(fn {_path, target} -> target in [nil, ""] end)
        |> Enum.filter(fn {path, _target} ->
          is_binary(path) and MapSet.member?(valid_paths, path)
        end)

      invalid_target? =
        Enum.any?(targets, fn {_path, target} ->
          if target == "movie" do
            not movie?
          else
            not MapSet.member?(valid_episode_ids, target)
          end
        end)

      cond do
        invalid_target? ->
          {:noreply,
           assign(
             socket,
             :match_files_error,
             "One or more selected targets are no longer valid for this download. Close and reopen Match files, then try again."
           )}

        targets == [] ->
          {:noreply, assign(socket, :match_files_error, "Select at least one file to import.")}

        true ->
          mappings =
            Enum.map(targets, fn {path, target} ->
              %{"path" => path, "episode_id" => if(target == "movie", do: nil, else: target)}
            end)

          case Downloads.resolve_file_mappings(download, mappings) do
            {:ok, _updated} ->
              {:noreply,
               socket
               |> assign(:match_files_modal, nil)
               |> assign(:match_files_error, nil)
               |> put_flash(:info, "Import queued for #{length(mappings)} file(s)")
               |> load_downloads()}

            {:error, _reason} ->
              {:noreply, assign(socket, :match_files_error, "Failed to queue the import.")}
          end
      end
    else
      {:unauthorized, socket} ->
        {:noreply, socket}

      nil ->
        {:noreply, download_vanished(socket)}
    end
  end

  def handle_event("reject_release", %{"id" => id}, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      with_download(socket, id, fn download ->
        case Downloads.request_reject(download) do
          {:ok, _pending} ->
            flash =
              case Blacklists.extract_key(download) do
                {:ok, _indexer, _guid} ->
                  "Release blacklisted. Mydia is removing it and will search again."

                {:error, _} ->
                  "Mydia is removing the download and will search again."
              end

            {:noreply,
             socket
             |> assign(:match_files_modal, nil)
             |> assign(:match_files_error, nil)
             |> put_flash(:info, flash)
             |> load_downloads()}

          {:error, :not_found} ->
            {:noreply, download_vanished(socket)}

          {:error, _reason} ->
            {:noreply, assign(socket, :match_files_error, "Failed to reject the release.")}
        end
      end)
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  # Snooze, not opt-out: clearing stalled_since and advancing last_progress_at
  # buys a full fresh grace-then-escalation window. If it stalls again the
  # operator gets warned again.
  def handle_event("keep_waiting", %{"id" => id}, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      with_download(socket, id, fn download ->
        case Downloads.update_download(download, %{
               stalled_since: nil,
               last_progress_at: DateTime.utc_now()
             }) do
          {:ok, _updated} ->
            {:noreply,
             socket
             |> put_flash(:info, "Stall timer reset. Mydia will keep waiting on this download.")
             |> load_downloads()}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not reset the stall timer")}
        end
      end)
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("dismiss_download", %{"id" => id}, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      with_download(socket, id, fn download ->
        case Downloads.dismiss_download(download) do
          {:ok, _} ->
            {:noreply, load_downloads(socket)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to dismiss download")}
        end
      end)
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("dismiss_all_cancelled", _params, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      {count, _} = Downloads.dismiss_all_cancelled()

      {:noreply,
       socket
       |> put_flash(:info, "#{count} download(s) dismissed")
       |> load_downloads()}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("clear_removed_client", %{"client" => client_name}, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      {count, _} = Downloads.clear_downloads_for_removed_client(client_name)

      {:noreply,
       socket
       # Neutral wording: the group covers a deleted client and a disabled one
       # alike, and the banner it came from says so too.
       |> put_flash(:info, "Cleared #{count} download(s) referencing '#{client_name}'")
       |> load_downloads()}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  # Event params are strings from the browser. Matched explicitly rather than
  # converted, so a forged value cannot reach String.to_atom/1.
  defp mode_atom("inflight"), do: :inflight
  defp mode_atom("postimport"), do: :postimport

  defp media_type_atom("movie"), do: :movie
  defp media_type_atom("tv_show"), do: :tv_show

  @impl true
  def handle_info({:download_updated, _download_id}, socket) do
    # Reload downloads when we receive an update
    # In a real implementation, we might want to just update the specific download
    {:noreply, socket |> maybe_refresh_clearable_count() |> load_downloads()}
  end

  def handle_info({:search_completed, _media_item_id, _stats}, socket) do
    {:noreply, socket |> maybe_refresh_clearable_count() |> load_downloads()}
  end

  # A fresh client scan landed. Only the two scan-backed tabs need a full
  # reload; the others just need the External tab count, which is an ETS read
  # rather than the client polling a reload would trigger.
  def handle_info(:external_scan_updated, socket) do
    if socket.assigns.active_tab in [:issues, :external] do
      {:noreply, load_downloads(socket)}
    else
      {:noreply, socket |> assign(:scan, ExternalTorrents.get()) |> assign_tabs()}
    end
  end

  # Periodic live-progress refresh. Reschedules unconditionally so it resumes
  # when the operator switches back to the Downloads tab or a new download starts, but
  # only re-polls clients when the Downloads tab actually has active work — idle
  # tabs cost nothing.
  def handle_info(:refresh_progress, socket) do
    schedule_progress_refresh()

    socket =
      if socket.assigns.active_tab == :downloads and socket.assigns.view != :imported and
           socket.assigns.summary.active > 0 and not socket.assigns.selection_mode do
        load_downloads(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  # Grab outcomes are broadcast on the "downloads" topic and handled by
  # MediaLive.Show, which owns the manual-search UI. Ignore them quietly here
  # so the catch-all below keeps meaning "genuinely unexpected message".
  def handle_info({:grab_completed, _payload}, socket), do: {:noreply, socket}
  def handle_info({:grab_failed, _payload}, socket), do: {:noreply, socket}
  def handle_info({:grab_duplicate, _payload}, socket), do: {:noreply, socket}

  def handle_info(msg, socket) do
    # Catch-all for unhandled messages to prevent crashes
    Logger.warning("Unhandled message in DownloadsLive.Index: #{inspect(msg)}")
    {:noreply, socket}
  end

  # Private functions

  defp schedule_progress_refresh do
    Process.send_after(self(), :refresh_progress, @progress_refresh_interval_ms)
  end

  # Keeps the Clear Completed modal's blast-radius count fresh if a background
  # update lands while the (destructive) modal is open. The submit flash always
  # reports the authoritative recomputed count regardless.
  defp maybe_refresh_clearable_count(%{assigns: %{show_clear_modal: true}} = socket) do
    assign(socket, :clearable_count, Downloads.count_completed())
  end

  defp maybe_refresh_clearable_count(socket), do: socket

  # A torrent id goes stale when the torrent leaves the client between render
  # and click. Report it rather than raising: the row is about to vanish from
  # the list anyway.
  defp adopt(socket, torrent_id, media_item_id, episode_id) do
    case ExternalTorrents.find(torrent_id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "That torrent is no longer in the client")
         |> load_downloads()}

      torrent ->
        case Downloads.adopt_external_torrent(torrent, media_item_id, episode_id) do
          {:ok, _download} ->
            {:noreply,
             socket
             |> put_flash(:info, "Download matched and import queued")
             |> load_downloads()}

          {:error, :already_tracked} ->
            {:noreply,
             socket
             |> put_flash(:info, "That torrent is already tracked")
             |> load_downloads()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to match download")}
        end
    end
  end

  defp reload_stream(socket) do
    socket = assign(socket, :scan, ExternalTorrents.get())

    case socket.assigns.active_tab do
      :issues ->
        load_issues_downloads(socket, Downloads.list_downloads_with_status(bounded: true))

      :external ->
        load_external(socket)

      _ ->
        downloads = get_current_downloads(socket)

        socket
        |> assign(:stale_status, stale_status(downloads))
        |> stream(:downloads, downloads, reset: true)
    end
  end

  # Retries one selected row: an import failure re-runs the import, a download
  # failure re-grabs the release. Returns the `{status, _}` shape the batch
  # tally counts.
  defp batch_retry_one(download) do
    if download.import_last_error do
      # Import failure - retry import
      case Downloads.update_download(download, %{
             import_retry_count: 0,
             import_last_error: nil,
             import_next_retry_at: nil,
             import_failed_at: nil
           }) do
        {:ok, updated} ->
          %{
            "download_id" => updated.id,
            "save_path" => nil,
            "cleanup_client" => true,
            "use_hardlinks" => true
          }
          |> Mydia.Jobs.MediaImport.new()
          |> Oban.insert()

        error ->
          error
      end
    else
      # Download failure - retry download
      metadata = DownloadMetadata.from_map(download.metadata)

      search_result = %Mydia.Indexers.SearchResult{
        download_url: download.download_url,
        title: download.title,
        indexer: download.indexer,
        size: metadata.size,
        seeders: metadata.seeders,
        leechers: metadata.leechers,
        quality: metadata.quality
      }

      opts =
        []
        |> maybe_add_opt(:media_item_id, download.media_item_id)
        |> maybe_add_opt(:episode_id, download.episode_id)
        |> maybe_add_opt(:client_name, download.download_client)

      Downloads.delete_download(download)
      Downloads.initiate_download(search_result, opts)
    end
  end

  # Loads the download an event names and hands it to `fun`.
  #
  # The id came from the rendered page, so it can name a row that is already
  # gone by the time the click lands: another tab, another operator, an import
  # that completed, or DownloadMonitor's own reject path deletes rows while a
  # Downloads view sits open. `get_download!/2` turned that ordinary race into a
  # crashed LiveView; tell the operator and re-render instead (issue #281).
  defp with_download(socket, id, opts \\ [], fun) do
    case Downloads.get_download(id, opts) do
      nil ->
        {:noreply, download_vanished(socket)}

      download ->
        fun.(download)
    end
  end

  # Any modal still open is about the row that just turned out to be gone, so
  # close it rather than leaving the operator acting on a stale struct.
  defp download_vanished(socket) do
    socket
    |> assign(:match_files_modal, nil)
    |> assign(:match_files_error, nil)
    |> assign(:match_modal, nil)
    |> put_flash(:info, "That download no longer exists.")
    |> load_downloads()
  end

  # Every per-row removal goes through here. The client call runs in
  # Mydia.Jobs.RemoveDownload, so the click returns at once and the row
  # re-renders as removing. `intent` maps the loaded download to the removal
  # kind and options.
  defp start_removal(socket, id, intent) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      with_download(socket, id, fn download ->
        {kind, opts} = intent.(download)

        case Downloads.request_removal(download, kind, opts) do
          {:ok, _pending} ->
            {:noreply, socket |> removal_flash(kind, download) |> load_downloads()}

          {:error, :not_found} ->
            {:noreply, download_vanished(socket)}

          {:error, :removal_in_progress} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               "The last removal attempt is still finishing. Try again shortly."
             )
             |> load_downloads()}

          {:error, _reason} ->
            {:noreply,
             socket
             |> put_flash(:error, "Could not start removing that download")
             |> load_downloads()}
        end
      end)
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  # A cancel on a stalled download also blacklists the release (see
  # Mydia.Downloads.Queue.cancel_bans_release?/1), so the operator is told.
  defp removal_flash(socket, "cancel", download) do
    if Downloads.cancel_bans_release?(download) do
      put_flash(
        socket,
        :info,
        "Cancelling. This release was stalled, so Mydia won't grab it again for " <>
          "#{Blacklists.default_ttl_days()} days."
      )
    else
      socket
    end
  end

  defp removal_flash(socket, _kind, _download), do: socket

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # Phoenix checkboxes submit "true" when checked and omit the key when not.
  defp delete_files?(params), do: Map.get(params, "delete_files") == "true"

  defp load_downloads(socket) do
    # The External tab count is shown from every tab, so refresh the cached scan
    # on every load. This is an ETS read, not I/O.
    socket = socket |> assign(:scan, ExternalTorrents.get()) |> assign(:loaded?, true)

    case socket.assigns.active_tab do
      # External reads only the scan cache and never polls the clients, so it
      # keeps the last counts and summary rather than paying for a poll.
      :external ->
        socket |> load_external() |> assign(:drawer_download, nil) |> assign_tabs()

      tab ->
        # Every row and every client in one bounded poll; the tabs, counts and
        # stats are all partitions of it.
        all = Downloads.list_downloads_with_status(bounded: true)

        socket
        |> assign(:rows_by_id, Map.new(all, &{&1.id, &1}))
        |> assign_overview(all)
        |> load_tab(tab, all)
        |> assign_drawer(all)
        |> assign_tabs()
    end
  end

  defp assign_overview(socket, all) do
    active = Downloads.filter_downloads(all, :active)
    issues = issue_lists(all)

    socket
    |> assign(:summary, ListView.summarize(active))
    |> assign(:client_options, ListView.clients(all))
    |> assign(:tab_counts, %{
      downloads: length(active),
      issues:
        length(socket.assigns.scan.needs_matching) + length(issues.unresolved) +
          length(issues.other)
    })
  end

  defp load_tab(socket, :issues, all), do: load_issues_downloads(socket, all)

  defp load_tab(socket, :downloads, all) do
    all_downloads =
      all
      |> ListView.rows_for_view(socket.assigns.view)
      |> ListView.filter(socket.assigns.filters)
      |> Sorting.sort(socket.assigns.sort_by)

    # Apply pagination
    page = socket.assigns.page
    offset = page * @items_per_page

    paginated_downloads =
      all_downloads
      |> Enum.drop(offset)
      |> Enum.take(@items_per_page)
      |> annotate_rematch_eligibility()
      |> annotate_auto_reject_cap()

    has_more = length(all_downloads) > offset + @items_per_page

    # Determine if we need to append or reset stream
    reset? = page == 0

    socket
    |> assign(:stale_status, stale_status(all_downloads))
    |> assign(:has_more, has_more)
    |> assign(:downloads_empty?, reset? and paginated_downloads == [])
    |> stream(:downloads, paginated_downloads, reset: reset?)
  end

  # Split out of load_issues_downloads/2 so the Issues count is available from
  # every tab. The path-mapping enrichment is a query and only the Issues tab
  # renders it, so it stays in load_issues_downloads/2.
  defp issue_lists(all) do
    %{
      unresolved: Enum.filter(all, &(&1.match_status == "unresolved_files")),
      other:
        Enum.filter(all, fn d ->
          (d.status in ["failed", "missing"] || not is_nil(d.import_failed_at) ||
             not is_nil(d.removal_error)) and d.match_status != "unresolved_files"
        end)
    }
  end

  # Finds the open drawer's download in `all` (fetching it when nil). A
  # download that has gone (cleared, deleted, stale link) closes the drawer
  # once, with a flash; drawer_id is cleared so a refresh tick does not repeat it.
  defp assign_drawer(%{assigns: %{drawer_id: nil}} = socket, _all),
    do: assign(socket, :drawer_download, nil)

  defp assign_drawer(%{assigns: %{active_tab: :external}} = socket, _all),
    do: assign(socket, :drawer_download, nil)

  # A drawer-only patch reuses the rows the last load polled, so opening the
  # drawer never polls the clients again. Only an id that load did not see (a
  # link to a download added since) pays for a fetch.
  defp assign_drawer(socket, nil) do
    case Map.fetch(socket.assigns.rows_by_id, socket.assigns.drawer_id) do
      {:ok, download} -> assign_drawer(socket, [download])
      :error -> assign_drawer(socket, Downloads.list_downloads_with_status(bounded: true))
    end
  end

  defp assign_drawer(socket, all) do
    case Enum.find(all, &(&1.id == socket.assigns.drawer_id)) do
      nil ->
        socket
        |> assign(drawer_id: nil, drawer_download: nil)
        |> put_flash(:info, "That download is no longer in this list")

      download ->
        [download] =
          [download]
          |> annotate_rematch_eligibility()
          |> annotate_auto_reject_cap()

        assign(socket, :drawer_download, download)
    end
  end

  defp load_issues_downloads(socket, all_downloads) do
    # Needs Matching is derived from the clients, not from the database: these
    # torrents have no download row and never will unless the user matches one.
    # `:scan` was refreshed by the caller (load_downloads/1 or reload_stream/1).
    scan = socket.assigns.scan
    filters = socket.assigns.filters
    %{unresolved: unresolved, other: other} = issue_lists(all_downloads)
    needs_matching = ListView.filter_scan(scan.needs_matching, filters)
    unresolved = ListView.filter(unresolved, filters)
    other = other |> ListView.filter(filters) |> enrich_path_mapping_suggestions()

    counts = %{
      unmatched: length(needs_matching),
      unresolved: length(unresolved),
      other: length(other)
    }

    all_empty = counts.unmatched == 0 and counts.unresolved == 0 and counts.other == 0

    socket
    |> assign(:stale_status, stale_status(all_downloads))
    |> assign(:has_more, false)
    |> assign(:downloads_empty?, all_empty)
    |> assign(:issues_counts, counts)
    |> assign(:scan, scan)
    |> assign(:removed_client_groups, removed_client_groups())
    |> stream(:needs_matching, needs_matching, reset: true)
    |> stream(:unresolved_downloads, unresolved, reset: true)
    |> stream(:other_issues, other, reset: true)
  end

  defp load_external(socket) do
    scan = socket.assigns.scan
    external = ListView.filter_scan(scan.external, socket.assigns.filters)

    socket
    |> assign(:stale_status, nil)
    |> assign(:has_more, false)
    |> assign(:downloads_empty?, external == [])
    |> assign(:scan, scan)
    |> stream(:external_torrents, external, reset: true)
  end

  # Orphan groups annotated with a DOM-safe slug. Client names come from
  # operator-supplied config (env vars), so unlike most other ids in this
  # LiveView they aren't guaranteed to already be DOM-id-safe — a name with
  # spaces or punctuation would otherwise produce an invalid id/CSS selector.
  # The raw name is preserved in `download_client` for display and for the
  # `phx-value-client` sent back to `clear_removed_client/2`.
  defp removed_client_groups do
    Downloads.removed_client_groups()
    |> Enum.map_reduce(MapSet.new(), fn group, taken ->
      {slug, taken} = unique_slug(ListView.slugify(group.download_client), taken)
      {Map.put(group, :slug, slug), taken}
    end)
    |> elem(0)
  end

  # Distinct client names can slugify to the same string ("Qbit Old" and
  # "qbit-old"), and anything with no alphanumerics collapses to "client".
  # Duplicate DOM ids are invalid HTML and make LiveView's id-keyed patching
  # apply an update to the wrong banner, so the first claimant keeps the bare
  # slug and later ones get a numeric suffix. `removed_client_groups/0` orders
  # by client name, so which one is "first" is stable across renders.
  defp unique_slug(base, taken) do
    if MapSet.member?(taken, base) do
      next_free_slug(base, 2, taken)
    else
      {base, MapSet.put(taken, base)}
    end
  end

  # Skips past a suffix a real client name already claimed, so a group named
  # "qbit-old-2" cannot be stolen from underneath by a disambiguated sibling.
  defp next_free_slug(base, n, taken) do
    candidate = "#{base}-#{n}"

    if MapSet.member?(taken, candidate) do
      next_free_slug(base, n + 1, taken)
    else
      {candidate, MapSet.put(taken, candidate)}
    end
  end

  # Re-enqueue every failed mismatch download whose reported path is under the
  # applied prefix, clearing its import-failure fields. Oban uniqueness keyed on
  # download_id skips any import already in flight. Returns the count.
  defp retry_mismatches_under_prefix(remote_prefix) do
    downloads = Downloads.list_path_mapping_mismatches_under_prefix(remote_prefix)

    Enum.each(downloads, fn download ->
      case Downloads.update_download(download, %{
             import_retry_count: 0,
             import_last_error: nil,
             import_failure_reason: nil,
             import_reported_path: nil,
             import_next_retry_at: nil,
             import_failed_at: nil
           }) do
        {:ok, updated} ->
          %{
            "download_id" => updated.id,
            "save_path" => nil,
            "cleanup_client" => true,
            "use_hardlinks" => true
          }
          # MediaImport declares worker-level uniqueness keyed on download_id,
          # so an import already queued/running for this download is not
          # double-enqueued.
          |> Mydia.Jobs.MediaImport.new()
          |> Oban.insert()

        {:error, _changeset} ->
          :ok
      end
    end)

    length(downloads)
  end

  defp mapping_error_message(changeset) do
    case changeset.errors[:remote_prefix] do
      {_msg, [{:constraint, :unique} | _]} ->
        "A mapping for this path already exists. Edit it on the Path Mappings page."

      _ ->
        "Couldn't add the mapping: " <>
          (Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
           |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end))
    end
  end

  # For downloads classified as a path-mapping mismatch, compute a suggested
  # remote→local mapping (from the persisted reported path) and the number of
  # downloads a one-click apply would re-run. Mount roots are detected once for
  # the whole batch.
  defp enrich_path_mapping_suggestions(downloads) do
    if Enum.any?(downloads, &(&1.import_failure_reason == "path_mapping_mismatch")) do
      roots = Mydia.Library.MountRoots.detect()

      {enriched, _affected_cache} =
        Enum.map_reduce(downloads, %{}, fn d, affected_cache ->
          if d.import_failure_reason == "path_mapping_mismatch" and
               is_binary(d.import_reported_path) do
            suggestion =
              case Mydia.Library.PathMapping.suggest(d.import_reported_path, roots) do
                {:ok, mapping} -> mapping
                :none -> nil
              end

            {affected, affected_cache} =
              if suggestion do
                Map.get_and_update(affected_cache, suggestion.remote_prefix, fn
                  nil ->
                    count =
                      length(
                        Downloads.list_path_mapping_mismatches_under_prefix(
                          suggestion.remote_prefix
                        )
                      )

                    {count, count}

                  count ->
                    {count, count}
                end)
              else
                {nil, affected_cache}
              end

            {%{d | path_mapping_suggestion: suggestion, path_mapping_affected_count: affected},
             affected_cache}
          else
            {d, affected_cache}
          end
        end)

      enriched
    else
      downloads
    end
  end

  defp submit_match(socket, media_item_id, episode_id) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      modal = socket.assigns.match_modal

      # The match modal can sit open across a delete (issue #281), so close it
      # and say so rather than crashing the socket on submit.
      with_download(socket, modal.download_id, fn download ->
        {flash_kind, message} =
          case modal.mode do
            :inflight ->
              case Downloads.manually_match_download(download, media_item_id, episode_id) do
                {:ok, _} -> {:info, "Match updated — the import will use the corrected match."}
                {:error, _} -> {:error, "Failed to update the match."}
              end

            :postimport ->
              case Downloads.rematch_imported_download(download, media_item_id, episode_id) do
                {:ok, :enqueued} ->
                  {:info, "Re-match queued — the file will be moved and relinked."}

                {:ok, :unchanged} ->
                  {:info, "Already matched to that title."}

                {:error, reason} ->
                  {:error, friendly_rematch_error(reason)}
              end
          end

        {:noreply,
         socket
         |> assign(:match_modal, nil)
         |> put_flash(flash_kind, message)
         |> load_downloads()}
      end)
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  defp friendly_rematch_error(:not_imported), do: "This download hasn't imported yet."

  defp friendly_rematch_error(reason) when reason in [:not_single_target, :multiple_files],
    do: "This download has multiple files; per-file re-match isn't supported yet."

  defp friendly_rematch_error(:no_imported_file),
    do: "Couldn't find the imported file for this download."

  defp friendly_rematch_error(:no_library_path),
    do: "No matching library is configured for that title's type."

  defp friendly_rematch_error(:library_type_mismatch),
    do: "That title's type doesn't match an available library."

  defp friendly_rematch_error(_), do: "Re-match failed."

  defp get_current_downloads(socket) do
    Downloads.list_downloads_with_status(bounded: true)
    |> ListView.rows_for_view(socket.assigns.view)
    |> ListView.filter(socket.assigns.filters)
    |> Sorting.sort(socket.assigns.sort_by)
    |> annotate_rematch_eligibility()
    |> annotate_auto_reject_cap()
  end

  # Stamps `rematch_eligible?` on imported rows: a row is eligible only when it
  # resolves to exactly one non-trashed imported file. Packs resolve to several
  # files and can't be re-matched as a unit, so the action stays hidden for them
  # even though their `match_status` is nil. In-flight rows don't offer the
  # action, so they are left nil and cost no query.
  defp annotate_rematch_eligibility(downloads) do
    imported_ids = for %{imported_at: at, id: id} <- downloads, not is_nil(at), do: id

    counts =
      if imported_ids == [],
        do: %{},
        else: Library.count_imported_files_by_download(imported_ids)

    Enum.map(downloads, fn
      %{imported_at: nil} = download -> download
      download -> %{download | rematch_eligible?: Map.get(counts, download.id, 0) == 1}
    end)
  end

  # Stamps `auto_reject_capped?` so a stalled row whose title has used up its
  # automatic rejections says so, instead of counting down to a removal that
  # DownloadMonitor will not make. One query for the whole page.
  defp annotate_auto_reject_cap(downloads) do
    capped =
      downloads
      |> Enum.map(& &1.media_item_id)
      |> AutoRejectCap.exhausted_ids()

    Enum.map(downloads, fn download ->
      %{download | auto_reject_capped?: MapSet.member?(capped, download.media_item_id)}
    end)
  end

  # View helpers

  defp is_selected?(assigns, id) do
    MapSet.member?(assigns.selected_ids, id)
  end

  # A percentage is only meaningful when the client is reporting a real
  # byte-for-byte transfer. Provider-side waits — debrid magnet conversion,
  # queueing for a download slot ("queued"), or remote packaging
  # ("checking") — have no measurable percentage. Rendering a 0%-filled bar
  # there reads as "stuck"; these phases get an indeterminate (animated) bar
  # plus the phase label instead of a frozen "0%".
  defp progress_indeterminate?(download), do: ListView.progress_indeterminate?(download)

  # Color modifier for the DaisyUI `status` dot shown at the start of each row.
  defp status_dot_class(status) do
    case status do
      s when s in ["downloading", "seeding", "completed", "imported"] -> "status-success"
      s when s in ["failed", "missing"] -> "status-error"
      s when s in ["cancelled", "stalled", "paused"] -> "status-warning"
      s when s in ["checking", "queued"] -> "status-info"
      _ -> "status-neutral"
    end
  end

  # Status dot color for a row, letting an import problem override the (otherwise
  # green) client status.
  defp row_status_dot_class(_download, :failed), do: "status-error"
  defp row_status_dot_class(_download, :retrying), do: "status-warning"

  defp row_status_dot_class(download, nil) do
    # A soft-stall keeps import_failed_at nil (so import_issue is nil), but the
    # row should still read as a warning rather than a healthy green.
    if soft_stalled?(download) do
      "status-warning"
    else
      status_dot_class(download.status)
    end
  end

  defp import_issue_label(:failed), do: "Import failed"
  defp import_issue_label(:retrying), do: "Import retrying"

  # Kept on Index because existing tests call them as Index.import_issue/1 and
  # Index.status_badge/1.
  defdelegate import_issue(download), to: ListView
  defdelegate status_badge(download), to: ListView

  # A removal is in flight for this row. Mydia.Jobs.RemoveDownload deletes the
  # row when it finishes, so until then the row only has to say so.
  defp removing?(download), do: not is_nil(download.removal_requested_at)

  defp soft_stalled?(download), do: ListView.soft_stalled?(download)
  defp stall_elapsed_seconds(download), do: ListView.stall_elapsed_seconds(download)

  # Seconds left before DownloadMonitor gives up on this download. Derived from
  # the same StallDetector rule the monitor applies, so the number the operator
  # reads is the number that will actually fire.
  defp stall_remaining_seconds(download, grace_map) do
    grace = Map.get(grace_map, download.download_client, Settings.default_grace_minutes())

    deadline =
      DateTime.add(download.stalled_since, StallDetector.escalation_minutes(grace) * 60, :second)

    max(DateTime.diff(deadline, DateTime.utc_now(), :second), 0)
  end

  # The oldest last-known status among the rows about to render, when a client
  # was too busy to answer the page's bounded poll. nil when every row is live.
  defp stale_status(downloads) do
    downloads
    |> Enum.filter(& &1.status_as_of)
    |> Enum.min_by(& &1.status_as_of, DateTime, fn -> nil end)
    |> case do
      nil -> nil
      row -> %{client: row.download_client, as_of: row.status_as_of}
    end
  end

  defp status_age(%DateTime{} = as_of) do
    seconds = max(DateTime.diff(DateTime.utc_now(), as_of, :second), 0)

    if seconds < 60, do: "#{seconds}s ago", else: format_relative_time(as_of)
  end

  # Whether Mydia adopted this download from a client rather than grabbing it
  # itself. Written by `UntrackedMatcher.create_download_record/3` (automatic)
  # and `Queue.adopt_external_torrent/3` (manual); "Added outside Mydia" is
  # accurate for both.
  #
  # `metadata` is a `Mydia.Settings.JsonMapType`, whose `cast/1` passes a map
  # through unchanged. A struct built in memory therefore carries atom keys
  # while the same row loaded from the database carries string keys after JSON
  # decoding. Reading only one form works right after adoption and silently
  # stops after the next page load.
  defp adopted_from_client?(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "matched_from_client") == true or
      Map.get(metadata, :matched_from_client) == true
  end

  defp adopted_from_client?(_download), do: false

  defp get_display_title(download), do: ListView.display_title(download)

  defp get_episode_details(download) do
    cond do
      # Download has a specific episode association
      is_map(download.episode) ->
        episode_id = format_episode_identifier(download.episode)
        episode_title = download.episode.title

        if episode_title do
          "#{episode_id} - #{episode_title}"
        else
          episode_id
        end

      # Download is for a TV show but no episode (likely season pack or series)
      is_map(download.media_item) && download.media_item.type == "tv_show" ->
        extract_season_info_from_title(download.title)

      true ->
        nil
    end
  end

  defp extract_season_info_from_title(title) do
    cond do
      # Match S01, S02, etc. (most common format)
      Regex.match?(~r/\.S(\d{1,2})(?:\.|E|$)/i, title) ->
        [_, season] = Regex.run(~r/\.S(\d{1,2})(?:\.|E|$)/i, title)
        "Season #{String.to_integer(season)}"

      # Match "Season 1", "Season 01", etc.
      Regex.match?(~r/Season[\s\.]+(\d{1,2})/i, title) ->
        [_, season] = Regex.run(~r/Season[\s\.]+(\d{1,2})/i, title)
        "Season #{String.to_integer(season)}"

      # If title has "Complete" or "Series" - likely full series pack
      Regex.match?(~r/(Complete|Series|Collection)/i, title) ->
        "Complete Series"

      # Fallback
      true ->
        nil
    end
  end

  defp format_episode_identifier(episode) do
    season = String.pad_leading("#{episode.season_number}", 2, "0")
    episode_num = String.pad_leading("#{episode.episode_number}", 2, "0")
    "S#{season}E#{episode_num}"
  end

  defp get_media_type(download) do
    cond do
      # If there's an episode, it's a TV show
      is_map(download.episode) ->
        "tv_show"

      # Otherwise check media_item type
      is_map(download.media_item) && download.media_item.type ->
        download.media_item.type

      # Unknown/fallback
      true ->
        nil
    end
  end

  defp media_type_badge(download) do
    case get_media_type(download) do
      "movie" -> {"🎬", "Movie", "badge-accent"}
      "tv_show" -> {"📺", "TV Show", "badge-info"}
      _ -> nil
    end
  end
end
