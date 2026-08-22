defmodule MydiaWeb.DownloadsLive.Index do
  use MydiaWeb, :live_view
  alias Mydia.Downloads
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
  import MydiaWeb.Formatters

  require Logger

  @items_per_page 50

  @default_sort "added_desc"

  # While a download is in flight, its progress (debrid swarm %, local fetch %)
  # is synthesized live from the client/provider on each poll and is NOT
  # persisted to the DB. PubSub broadcasts only fire on DB row changes, so
  # without a periodic re-render the bar freezes at whatever it showed at page
  # load. This timer re-polls + re-renders the Queue while work is active.
  @progress_refresh_interval_ms 3_000

  # Sort options offered per tab. Real-time keys (progress, speeds, ETA, ratio)
  # only exist after client-status enrichment, so sorting runs in the LiveView
  # over the enriched list (see apply_sorting/2), not in the DB query.
  @shared_sort_options [
    {"added_desc", "Newest first"},
    {"added_asc", "Oldest first"},
    {"name_asc", "Name (A-Z)"},
    {"name_desc", "Name (Z-A)"},
    {"status_asc", "Status"},
    {"size_desc", "Size (largest)"},
    {"size_asc", "Size (smallest)"}
  ]

  @queue_sort_options [
    {"progress_desc", "Progress (most)"},
    {"progress_asc", "Progress (least)"},
    {"dlspeed_desc", "Download speed"},
    {"eta_asc", "ETA (soonest)"}
  ]

  @completed_sort_options [
    {"ratio_desc", "Ratio (highest)"},
    {"ratio_asc", "Ratio (lowest)"},
    {"ulspeed_desc", "Upload speed"},
    {"imported_desc", "Imported (newest)"},
    {"imported_asc", "Imported (oldest)"}
  ]

  @allowed_sort_fields (@shared_sort_options ++ @queue_sort_options ++ @completed_sort_options)
                       |> Enum.map(&elem(&1, 0))

  # Rank for status sorting so states group sensibly (active work first) rather
  # than sorting alphabetically. Unknown statuses fall to the end.
  @status_rank %{
    "downloading" => 0,
    "checking" => 1,
    "queued" => 2,
    "paused" => 3,
    "stalled" => 4,
    "seeding" => 5,
    "completed" => 6,
    "imported" => 7,
    "cancelled" => 8,
    "failed" => 9,
    "missing" => 10,
    "unknown" => 11
  }

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to download updates for real-time progress
    if connected?(socket) do
      PubSub.subscribe(Mydia.PubSub, "downloads")
      schedule_progress_refresh()
    end

    {:ok,
     socket
     |> assign(:page_title, "Activity")
     |> assign(:active_tab, :queue)
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
     # Initialize all streams
     |> stream(:downloads, [])
     |> stream(:needs_matching, [])
     |> stream(:external_torrents, [])
     |> stream(:unresolved_downloads, [])
     |> stream(:other_issues, [])
     |> load_downloads()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  @allowed_tabs ~w(queue completed issues external)

  def handle_event("switch_tab", %{"tab" => tab}, socket) when tab in @allowed_tabs do
    tab_atom = String.to_existing_atom(tab)

    {:noreply,
     socket
     |> assign(:active_tab, tab_atom)
     # Reset to the default sort: a tab-specific sort (e.g. ratio on completed)
     # is not a valid option on the new tab.
     |> assign(:sort_by, @default_sort)
     |> assign(:selected_ids, MapSet.new())
     |> assign(:selection_mode, false)
     |> assign(:page, 0)
     |> load_downloads()}
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
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      with_download(socket, id, fn download ->
        case Downloads.cancel_download(download, delete_files: false) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Download cancelled and removed from client")
             |> load_downloads()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to cancel download: #{inspect(reason)}")}
        end
      end)
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
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
              "use_hardlinks" => true,
              "move_files" => false
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

  def handle_event("delete_download", %{"id" => id}, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      with_download(socket, id, fn download ->
        # First try to remove from client (ignore errors if already removed)
        _ = Downloads.cancel_download(download, delete_files: true)

        # Then delete from database
        case Downloads.delete_download(download) do
          {:ok, _deleted} ->
            {:noreply,
             socket
             |> put_flash(:info, "Download removed")
             |> load_downloads()}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to delete download")}
        end
      end)
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
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

              download ->
                # Try to remove from client (ignore errors)
                _ = Downloads.cancel_download(download, delete_files: true)
                # Delete from database
                Downloads.delete_download(download)
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
       |> put_flash(:info, "#{success_count} download(s) removed")
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
      {:ok, count} = Downloads.clear_all_completed(delete_files: delete_files)

      message =
        if delete_files do
          "#{count} completed download(s) cleared and files deleted from disk"
        else
          "#{count} completed download(s) cleared"
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
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      with_download(socket, id, fn download ->
        case Downloads.clear_completed(download) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Download cleared from history")
             |> load_downloads()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to clear download: #{inspect(reason)}")}
        end
      end)
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
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
        Media.list_media_items(search: query) |> Enum.take(10)
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
      {:noreply,
       assign(socket, :match_modal, %{
         download_id: id,
         mode: String.to_existing_atom(mode),
         query: "",
         results: [],
         selected: nil,
         episodes: []
       })}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("close_match_modal", _params, socket) do
    {:noreply, assign(socket, :match_modal, nil)}
  end

  def handle_event("match_modal_search", %{"q" => query}, socket) do
    results =
      if String.length(query) >= 2 do
        Media.list_media_items(search: query) |> Enum.take(10)
      else
        []
      end

    {:noreply,
     update(socket, :match_modal, fn modal ->
       %{modal | query: query, results: results}
     end)}
  end

  def handle_event(
        "match_modal_pick_item",
        %{"media_item_id" => media_item_id, "type" => type, "title" => title},
        socket
      ) do
    if type == "tv_show" do
      # TV: choose the specific episode in a second step.
      episodes = Media.list_episodes(media_item_id)

      {:noreply,
       update(socket, :match_modal, fn modal ->
         %{modal | selected: %{id: media_item_id, title: title}, episodes: episodes}
       end)}
    else
      # Movie: submit immediately.
      submit_match(socket, media_item_id, nil)
    end
  end

  def handle_event("match_modal_pick_episode", %{"episode_id" => episode_id}, socket) do
    %{selected: %{id: media_item_id}} = socket.assigns.match_modal
    submit_match(socket, media_item_id, episode_id)
  end

  # --- Match files modal (manual file matching on import failure) ---

  def handle_event("open_match_files", %{"id" => id}, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      with_download(socket, id, [preload: [:media_item, :library_path]], fn download ->
        case ImportCandidates.load(download) do
          {:ok, source, candidates} ->
            episodes =
              if download.media_item && download.media_item.type == "tv_show" do
                Media.list_episodes(download.media_item.id)
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

      valid_episode_ids =
        case download.media_item do
          %{type: "tv_show", id: media_item_id} ->
            media_item_id |> Media.list_episodes() |> MapSet.new(& &1.id)

          _other ->
            MapSet.new()
        end

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
        case Downloads.reject_release(download) do
          {:ok, :rejected} ->
            flash =
              case Blacklists.extract_key(download) do
                {:ok, _indexer, _guid} ->
                  "Release blacklisted and a new search was queued"

                {:error, _} ->
                  "Download removed and a new search was queued"
              end

            {:noreply,
             socket
             |> assign(:match_files_modal, nil)
             |> assign(:match_files_error, nil)
             |> put_flash(:info, flash)
             |> load_downloads()}

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
      {:noreply, assign(socket, :scan, ExternalTorrents.get())}
    end
  end

  # Periodic live-progress refresh. Reschedules unconditionally so it resumes
  # when the operator switches back to the Queue or a new download starts, but
  # only re-polls clients when the Queue tab actually has active work — idle
  # tabs cost nothing.
  def handle_info(:refresh_progress, socket) do
    schedule_progress_refresh()

    socket =
      if socket.assigns.active_tab == :queue and not socket.assigns.downloads_empty? and
           not socket.assigns.selection_mode do
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
        load_issues_downloads(socket)

      :external ->
        load_external(socket)

      _ ->
        downloads = get_current_downloads(socket)
        stream(socket, :downloads, downloads, reset: true)
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
            "use_hardlinks" => true,
            "move_files" => false
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

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # Phoenix checkboxes submit "true" when checked and omit the key when not.
  defp delete_files?(params), do: Map.get(params, "delete_files") == "true"

  defp load_downloads(socket) do
    # The External tab count is shown from every tab, so refresh the cached scan
    # on every load. This is an ETS read, not I/O.
    socket = assign(socket, :scan, ExternalTorrents.get())

    case socket.assigns.active_tab do
      :issues ->
        load_issues_downloads(socket)

      :external ->
        load_external(socket)

      tab ->
        filter =
          case tab do
            :queue -> :active
            :completed -> :imported
          end

        # Get all matching downloads for the current tab with real-time status from clients
        all_downloads =
          Downloads.list_downloads_with_status(filter: filter)
          |> apply_sorting(socket.assigns.sort_by)

        # Apply pagination
        page = socket.assigns.page
        offset = page * @items_per_page

        paginated_downloads =
          all_downloads
          |> Enum.drop(offset)
          |> Enum.take(@items_per_page)
          |> annotate_rematch_eligibility(tab)

        has_more = length(all_downloads) > offset + @items_per_page

        # Determine if we need to append or reset stream
        reset? = page == 0

        socket
        |> assign(:has_more, has_more)
        |> assign(:downloads_empty?, reset? and paginated_downloads == [])
        |> stream(:downloads, paginated_downloads, reset: reset?)
    end
  end

  defp load_issues_downloads(socket) do
    all_downloads = Downloads.list_downloads_with_status()

    # Needs Matching is derived from the clients, not from the database: these
    # torrents have no download row and never will unless the user matches one.
    # `:scan` was refreshed by the caller (load_downloads/1 or reload_stream/1).
    scan = socket.assigns.scan
    needs_matching = scan.needs_matching

    unresolved = Enum.filter(all_downloads, fn d -> d.match_status == "unresolved_files" end)

    other =
      all_downloads
      |> Enum.filter(fn d ->
        (d.status in ["failed", "missing"] || not is_nil(d.import_failed_at)) and
          d.match_status != "unresolved_files"
      end)
      |> enrich_path_mapping_suggestions()

    counts = %{
      unmatched: length(needs_matching),
      unresolved: length(unresolved),
      other: length(other)
    }

    all_empty = counts.unmatched == 0 and counts.unresolved == 0 and counts.other == 0

    socket
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

    socket
    |> assign(:has_more, false)
    |> assign(:downloads_empty?, scan.external == [])
    |> assign(:scan, scan)
    |> stream(:external_torrents, scan.external, reset: true)
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
      {slug, taken} = unique_slug(slugify(group.download_client), taken)
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

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "client"
      slug -> slug
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
            "use_hardlinks" => true,
            "move_files" => false
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
    filter =
      case socket.assigns.active_tab do
        :queue -> :active
        :completed -> :imported
        :issues -> :all
      end

    Downloads.list_downloads_with_status(filter: filter)
    |> apply_sorting(socket.assigns.sort_by)
    |> annotate_rematch_eligibility(socket.assigns.active_tab)
  end

  # Stamps `rematch_eligible?` on completed-tab rows: a row is eligible only when
  # it resolves to exactly one non-trashed imported file. Packs resolve to several
  # files and can't be re-matched as a unit, so the Completed-tab action must stay
  # hidden for them even though their `match_status` is nil. Other tabs don't offer
  # the action, so the flag is left nil to avoid a needless query.
  defp annotate_rematch_eligibility(downloads, :completed) do
    counts =
      downloads
      |> Enum.map(& &1.id)
      |> Library.count_imported_files_by_download()

    Enum.map(downloads, fn download ->
      %{download | rematch_eligible?: Map.get(counts, download.id, 0) == 1}
    end)
  end

  defp annotate_rematch_eligibility(downloads, _tab), do: downloads

  # Sorts the enriched download list by the active `sort_by` selection. Runs in
  # the LiveView (not the DB) because real-time keys (progress, speeds, ETA,
  # ratio) only exist after client-status enrichment. Missing values are guarded
  # so they group deterministically rather than scatter or raise.
  defp apply_sorting(downloads, sort_by) do
    case sort_by do
      "added_desc" -> Enum.sort_by(downloads, & &1.inserted_at, {:desc, DateTime})
      "added_asc" -> Enum.sort_by(downloads, & &1.inserted_at, {:asc, DateTime})
      "name_asc" -> Enum.sort_by(downloads, &sort_name/1, :asc)
      "name_desc" -> Enum.sort_by(downloads, &sort_name/1, :desc)
      "status_asc" -> Enum.sort_by(downloads, &status_rank/1, :asc)
      "size_desc" -> Enum.sort_by(downloads, &(&1.size || 0), :desc)
      "size_asc" -> Enum.sort_by(downloads, &(&1.size || 0), :asc)
      "progress_desc" -> Enum.sort_by(downloads, &(&1.progress || 0.0), :desc)
      "progress_asc" -> Enum.sort_by(downloads, &(&1.progress || 0.0), :asc)
      "dlspeed_desc" -> Enum.sort_by(downloads, &(&1.download_speed || 0), :desc)
      "ulspeed_desc" -> Enum.sort_by(downloads, &(&1.upload_speed || 0), :desc)
      "ratio_desc" -> Enum.sort_by(downloads, &(&1.ratio || 0.0), :desc)
      "ratio_asc" -> Enum.sort_by(downloads, &(&1.ratio || 0.0), :asc)
      "eta_asc" -> Enum.sort_by(downloads, &eta_sort_key/1, :asc)
      "imported_desc" -> Enum.sort_by(downloads, &imported_sort_key/1, {:desc, DateTime})
      "imported_asc" -> Enum.sort_by(downloads, &imported_sort_key/1, {:asc, DateTime})
      _ -> Enum.sort_by(downloads, & &1.inserted_at, {:desc, DateTime})
    end
  end

  defp sort_name(download), do: String.downcase(get_display_title(download) || "")

  defp status_rank(download) do
    # Stall state overrides the client status for sorting: a soft-stall groups
    # with warnings.
    if soft_stalled?(download) do
      Map.fetch!(@status_rank, "stalled")
    else
      Map.get(@status_rank, download.status, 99)
    end
  end

  # ETA may be nil, an integer (seconds remaining), or a DateTime. Normalize to
  # an integer so a single comparator works; nil sorts last (soonest first).
  defp eta_sort_key(download) do
    case download.eta do
      nil -> 9_999_999_999
      %DateTime{} = dt -> DateTime.diff(dt, DateTime.utc_now(), :second)
      seconds when is_integer(seconds) -> seconds
      _ -> 9_999_999_999
    end
  end

  # imported_at is always present on the completed tab, but guard nil so the
  # comparator never raises if called on a mixed list.
  defp imported_sort_key(download), do: download.imported_at || download.inserted_at

  # Sort options available for the given tab. Shared keys apply to every tab;
  # queue- and completed-specific keys are only meaningful there.
  defp sort_options(:completed), do: @shared_sort_options ++ @completed_sort_options
  defp sort_options(_tab), do: @shared_sort_options ++ @queue_sort_options

  # View helpers

  defp is_selected?(assigns, id) do
    MapSet.member?(assigns.selected_ids, id)
  end

  defp format_speed(nil), do: "—"

  defp format_speed(bytes_per_second) when is_number(bytes_per_second) do
    cond do
      bytes_per_second >= 1_048_576 ->
        "#{Float.round(bytes_per_second / 1_048_576, 2)} MB/s"

      bytes_per_second >= 1024 ->
        "#{Float.round(bytes_per_second / 1024, 2)} KB/s"

      true ->
        "#{bytes_per_second} B/s"
    end
  end

  defp format_eta(nil), do: "—"

  defp format_eta(%DateTime{} = dt) do
    now = DateTime.utc_now()
    diff = DateTime.diff(dt, now, :second)

    cond do
      diff < 0 -> "Now"
      diff < 60 -> "#{diff}s"
      diff < 3600 -> "#{div(diff, 60)}m"
      diff < 86400 -> "#{div(diff, 3600)}h"
      true -> "#{div(diff, 86400)}d"
    end
  end

  defp format_eta(seconds) when is_integer(seconds) do
    cond do
      seconds < 0 -> "Now"
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86400 -> "#{div(seconds, 3600)}h"
      true -> "#{div(seconds, 86400)}d"
    end
  end

  # A percentage is only meaningful when the client is reporting a real
  # byte-for-byte transfer. Provider-side waits — debrid magnet conversion,
  # queueing for a download slot ("queued"), or remote packaging
  # ("checking") — have no measurable percentage. Rendering a 0%-filled bar
  # there reads as "stuck"; these phases get an indeterminate (animated) bar
  # plus the phase label instead of a frozen "0%".
  defp progress_indeterminate?(download), do: download.status in ["queued", "checking"]

  defp get_metadata_value(download, key) do
    metadata_map = download.metadata || %{}

    case key do
      # Keys modeled in DownloadMetadata struct
      k when k in ~w(size seeders leechers quality season_pack season_number download_protocol) ->
        metadata = DownloadMetadata.from_map(metadata_map)
        if metadata, do: Map.get(metadata, String.to_existing_atom(k)), else: nil

      # Raw metadata keys (parsed_info, match_suggestions, unresolved_files, etc.)
      _ ->
        Map.get(metadata_map, key)
    end
  end

  defp status_badge_class(status) do
    case status do
      "completed" -> "badge-success"
      "seeding" -> "badge-success"
      "imported" -> "badge-success"
      "failed" -> "badge-error"
      "missing" -> "badge-error"
      "cancelled" -> "badge-warning"
      "downloading" -> "badge-primary"
      "checking" -> "badge-info"
      "queued" -> "badge-info"
      "paused" -> "badge-warning"
      "stalled" -> "badge-warning"
      _ -> "badge-ghost"
    end
  end

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

  # An import problem that should be surfaced on the row even though the torrent
  # client still reports the download as completed/seeding. The torrent finishing
  # is only half the job — if the post-download import keeps failing (e.g. a
  # filesystem permission error) the user otherwise sees a healthy "seeding" row
  # with no hint that nothing landed in the library. Returns:
  #
  #   * `:failed`   — import failed terminally (no further automatic retries)
  #   * `:retrying` — import failed but a retry is scheduled
  #   * `nil`       — no import problem (not yet attempted, or already imported)
  def import_issue(download) do
    cond do
      not is_nil(download.imported_at) -> nil
      is_nil(download.import_failed_at) and is_nil(download.import_last_error) -> nil
      not is_nil(download.import_next_retry_at) -> :retrying
      true -> :failed
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

  @doc false
  # Returns `{class, label}` for the download's status badge. A soft-stall is a
  # recoverable warning: progress has stopped but the download still occupies
  # its episode and may auto-clear. There is no terminal stall badge — an
  # escalated stall is rejected outright and the row no longer exists.
  def status_badge(download) do
    if soft_stalled?(download) do
      {status_badge_class("stalled"), "Stalled"}
    else
      {status_badge_class(download.status), String.capitalize(download.status)}
    end
  end

  # A recoverable soft-stall: `stalled_since` set but not yet escalated to a
  # terminal `import_failed_at` failure. Gated on the live "downloading" status
  # so a download that pauses, completes, or goes client-unreachable after a
  # soft-stall does not keep rendering a stale warning — `stalled_since` is only
  # cleared while the download is observed downloading, so it can linger on a row
  # that has since moved on.
  defp soft_stalled?(download) do
    download.status == "downloading" and
      not is_nil(download.stalled_since) and is_nil(download.import_failed_at)
  end

  # Seconds since this download last moved a byte. Falls back to stalled_since
  # for a row whose last_progress_at predates stall tracking.
  defp stall_elapsed_seconds(download) do
    reference = download.last_progress_at || download.stalled_since
    DateTime.diff(DateTime.utc_now(), reference, :second)
  end

  # Seconds left before DownloadMonitor gives up on this download. Derived from
  # the same StallDetector rule the monitor applies, so the number the operator
  # reads is the number that will actually fire.
  defp stall_remaining_seconds(download, grace_map) do
    grace = Map.get(grace_map, download.download_client, Settings.default_grace_minutes())

    deadline =
      DateTime.add(download.stalled_since, StallDetector.escalation_minutes(grace) * 60, :second)

    max(DateTime.diff(deadline, DateTime.utc_now(), :second), 0)
  end

  defp format_ratio(nil), do: "0.00"
  defp format_ratio(ratio) when is_float(ratio), do: Float.round(ratio, 2) |> to_string()
  defp format_ratio(ratio) when is_integer(ratio), do: "#{ratio}.00"

  defp format_relative_time(nil), do: "—"

  defp format_relative_time(%DateTime{} = dt) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86400)}d ago"
      true -> Calendar.strftime(dt, "%b %d")
    end
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

  defp get_display_title(download) do
    cond do
      # Episode download - show parent show title
      is_map(download.episode) ->
        if is_map(download.episode.media_item) do
          download.episode.media_item.title
        else
          # Fallback to direct media_item if episode.media_item is not loaded
          if is_map(download.media_item), do: download.media_item.title, else: "Unknown Show"
        end

      # Movie or show-level download
      is_map(download.media_item) && download.media_item.title ->
        download.media_item.title

      # Fallback to torrent title
      true ->
        download.title
    end
  end

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

  defp format_protocol(:nzb), do: "Usenet"
  defp format_protocol(:torrent), do: "Torrent"
  defp format_protocol("nzb"), do: "Usenet"
  defp format_protocol("torrent"), do: "Torrent"
  defp format_protocol(_), do: nil

  defp format_next_retry(nil), do: "—"

  defp format_next_retry(%DateTime{} = dt) do
    now = DateTime.utc_now()
    diff = DateTime.diff(dt, now, :second)

    cond do
      diff < 0 -> "Retrying soon..."
      diff < 60 -> "in #{diff}s"
      diff < 3600 -> "in #{div(diff, 60)}m"
      diff < 86400 -> "in #{div(diff, 3600)}h"
      true -> "in #{div(diff, 86400)}d"
    end
  end
end
