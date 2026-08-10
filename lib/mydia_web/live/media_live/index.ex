defmodule MydiaWeb.MediaLive.Index do
  use MydiaWeb, :live_view
  alias Mydia.Media
  alias Mydia.Media.AvailabilityStatus
  alias Mydia.Metadata.Structs.MediaMetadata
  alias Mydia.Settings
  alias Mydia.Collections
  alias Mydia.Search
  alias MydiaWeb.Live.Authorization

  require Logger

  @items_per_page 50
  @items_per_scroll 25
  @auto_search_confirm_threshold 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mydia.PubSub, "downloads")
      Phoenix.PubSub.subscribe(Mydia.PubSub, "library_scanner")
    end

    {:ok,
     socket
     |> assign(:view_mode, :grid)
     |> assign(:search_query, "")
     |> assign(:filter_progress, nil)
     |> assign(:filter_monitored, nil)
     |> assign(:filter_quality, nil)
     |> assign(:sort_by, "title_asc")
     |> assign(:page, 0)
     |> assign(:has_more, true)
     |> assign(:selection_mode, false)
     |> assign(:selected_ids, MapSet.new())
     |> assign(:show_delete_modal, false)
     |> assign(:delete_files, false)
     |> assign(:show_batch_edit_modal, false)
     |> assign(:show_auto_search_confirm_modal, false)
     |> assign(:quality_profiles, [])
     |> assign(:batch_edit_form, to_form(%{}, as: :batch_edit))
     |> assign(:scanning, false)
     |> assign(:scan_result, nil)
     |> assign(:scan_progress, nil)
     |> assign(:filter_library_type, nil)
     |> assign(:specialized_library_type, nil)
     |> assign(:show_add_to_collection_modal, false)
     |> assign(:user_collections, [])
     |> assign(:all_visible_ids, MapSet.new())
     |> stream(:media_items, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :movies, _params) do
    socket
    |> assign(:page_title, "Movies")
    |> assign(:filter_type, "movie")
    |> assign(:filter_library_type, nil)
    |> assign(:specialized_library_type, nil)
    |> load_media_items(reset: true)
  end

  defp apply_action(socket, :tv_shows, _params) do
    socket
    |> assign(:page_title, "TV Shows")
    |> assign(:filter_type, "tv_show")
    |> assign(:filter_library_type, nil)
    |> assign(:specialized_library_type, nil)
    |> load_media_items(reset: true)
  end

  defp apply_action(socket, :adult, _params) do
    socket
    |> assign(:page_title, "Adult")
    |> assign(:filter_type, nil)
    |> assign(:filter_library_type, :adult)
    |> assign(:specialized_library_type, nil)
    |> load_media_items(reset: true)
  end

  @impl true
  def handle_event("toggle_view", %{"mode" => mode}, socket) do
    view_mode = String.to_existing_atom(mode)

    {:noreply,
     socket
     |> assign(:view_mode, view_mode)
     |> assign(:page, 0)
     |> load_media_items(reset: true)}
  end

  def handle_event("search", params, socket) do
    Logger.debug("Search params: #{inspect(params)}")

    query = params["search"] || params["value"] || ""

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:page, 0)
     |> assign(:selected_ids, MapSet.new())
     |> load_media_items(reset: true)}
  end

  def handle_event("filter", params, socket) do
    Logger.debug("Filter params: #{inspect(params)}")

    progress =
      case params["progress"] do
        "missing" -> :missing
        "partial" -> :partial
        "downloaded" -> :downloaded
        _ -> nil
      end

    monitored =
      case params["monitored"] do
        "all" -> nil
        "true" -> true
        "false" -> false
        _ -> nil
      end

    quality =
      case params["quality"] do
        "" -> nil
        q when q in ["720p", "1080p", "2160p"] -> q
        _ -> nil
      end

    sort_by = params["sort_by"] || socket.assigns.sort_by
    Logger.debug("Sort by: #{inspect(sort_by)}")

    {:noreply,
     socket
     |> assign(:filter_progress, progress)
     |> assign(:filter_monitored, monitored)
     |> assign(:filter_quality, quality)
     |> assign(:sort_by, sort_by)
     |> assign(:page, 0)
     |> assign(:selected_ids, MapSet.new())
     |> load_media_items(reset: true)}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more do
      {:noreply,
       socket
       |> update(:page, &(&1 + 1))
       |> load_media_items(reset: false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_select", %{"id" => id}, socket) do
    if socket.assigns.selection_mode do
      selected_ids = socket.assigns.selected_ids

      updated_ids =
        if MapSet.member?(selected_ids, id) do
          MapSet.delete(selected_ids, id)
        else
          MapSet.put(selected_ids, id)
        end

      {:noreply, assign(socket, :selected_ids, updated_ids)}
    else
      # Not in selection mode, navigate to the item
      {:noreply, push_navigate(socket, to: ~p"/media/#{id}")}
    end
  end

  def handle_event("select_all", _params, socket) do
    # Get all visible item IDs from the current stream
    # Note: We need to collect all currently loaded items
    query_opts = build_query_opts(socket.assigns)
    items = Media.list_media_items(query_opts)
    items = apply_search_filter(items, socket.assigns.search_query)
    items = apply_quality_filter(items, socket.assigns.filter_quality)
    items = apply_progress_filter(items, socket.assigns.filter_progress)

    all_ids = MapSet.new(items, & &1.id)

    {:noreply, assign(socket, :selected_ids, all_ids)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected_ids, MapSet.new())}
  end

  def handle_event("toggle_select_all", _params, socket) do
    # Toggle between selecting all visible items and clearing selection
    all_visible_ids = socket.assigns.all_visible_ids
    selected_ids = socket.assigns.selected_ids

    new_selected_ids =
      if MapSet.equal?(selected_ids, all_visible_ids) and MapSet.size(all_visible_ids) > 0 do
        # All are selected, so clear
        MapSet.new()
      else
        # Not all selected, so select all
        all_visible_ids
      end

    {:noreply, assign(socket, :selected_ids, new_selected_ids)}
  end

  def handle_event("toggle_selection_mode", _params, socket) do
    selection_mode = !socket.assigns.selection_mode

    socket =
      if selection_mode do
        socket
      else
        # Exiting selection mode - clear selection
        assign(socket, :selected_ids, MapSet.new())
      end

    {:noreply, assign(socket, :selection_mode, selection_mode)}
  end

  def handle_event("keydown", %{"key" => "Escape"}, socket) do
    {:noreply,
     socket
     |> assign(:selection_mode, false)
     |> assign(:selected_ids, MapSet.new())}
  end

  def handle_event("keydown", %{"key" => "a", "ctrlKey" => true}, socket) do
    # Ctrl+A - select all (note: UI sync happens via JS.dispatch from button, not from keyboard)
    query_opts = build_query_opts(socket.assigns)
    items = Media.list_media_items(query_opts)
    items = apply_search_filter(items, socket.assigns.search_query)
    items = apply_quality_filter(items, socket.assigns.filter_quality)
    items = apply_progress_filter(items, socket.assigns.filter_progress)

    all_ids = MapSet.new(items, & &1.id)

    {:noreply, assign(socket, :selected_ids, all_ids)}
  end

  def handle_event("keydown", _params, socket) do
    # Ignore other key events
    {:noreply, socket}
  end

  def handle_event("batch_monitor", _params, socket) do
    selected_ids = MapSet.to_list(socket.assigns.selected_ids)

    case Media.update_media_items_monitored(selected_ids, true) do
      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{count} #{pluralize_items(count)} set to monitored")
         |> assign(:selection_mode, false)
         |> assign(:selected_ids, MapSet.new())
         |> load_media_items(reset: true)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update items")}
    end
  end

  def handle_event("batch_unmonitor", _params, socket) do
    selected_ids = MapSet.to_list(socket.assigns.selected_ids)

    case Media.update_media_items_monitored(selected_ids, false) do
      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{count} #{pluralize_items(count)} set to unmonitored")
         |> assign(:selection_mode, false)
         |> assign(:selected_ids, MapSet.new())
         |> load_media_items(reset: true)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update items")}
    end
  end

  def handle_event("toggle_item_monitored", %{"id" => id}, socket) do
    media_item = Media.get_media_item!(id)
    new_monitored_status = !media_item.monitored

    case Media.update_media_item(media_item, %{monitored: new_monitored_status},
           reason: if(new_monitored_status, do: "Monitoring enabled", else: "Monitoring disabled")
         ) do
      {:ok, _updated_item} ->
        # Refetch with proper preloads to match the stream items (exclude trashed files)
        import Ecto.Query
        active_files_query = from(mf in Mydia.Library.MediaFile, where: is_nil(mf.trashed_at))

        updated_item_with_preloads =
          Media.get_media_item!(id,
            preload: [
              :downloads,
              media_files: active_files_query,
              episodes: [media_files: active_files_query, downloads: []]
            ]
          )

        {:noreply,
         socket
         |> stream_insert(:media_items, updated_item_with_preloads)
         |> put_flash(
           :info,
           "Monitoring #{if new_monitored_status, do: "enabled", else: "disabled"}"
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update monitoring status")}
    end
  end

  def handle_event("batch_auto_search", _params, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      if MapSet.size(socket.assigns.selected_ids) > @auto_search_confirm_threshold do
        {:noreply, assign(socket, :show_auto_search_confirm_modal, true)}
      else
        {:noreply, run_batch_auto_search(socket)}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("confirm_batch_auto_search", _params, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      {:noreply,
       socket
       |> assign(:show_auto_search_confirm_modal, false)
       |> run_batch_auto_search()}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("cancel_batch_auto_search", _params, socket) do
    {:noreply, assign(socket, :show_auto_search_confirm_modal, false)}
  end

  def handle_event("batch_reclassify", _params, socket) do
    selected_ids = MapSet.to_list(socket.assigns.selected_ids)

    {:ok, summary} = Media.reclassify_media_items(selected_ids)

    message =
      cond do
        summary.updated > 0 && summary.skipped > 0 ->
          "Reclassified #{summary.updated} #{pluralize_items(summary.updated)}, #{summary.skipped} skipped (category override)"

        summary.updated > 0 ->
          "Reclassified #{summary.updated} #{pluralize_items(summary.updated)}"

        summary.skipped > 0 ->
          "No changes - #{summary.skipped} #{pluralize_items(summary.skipped)} have category override"

        true ->
          "No category changes detected"
      end

    {:noreply,
     socket
     |> put_flash(:info, message)
     |> assign(:selection_mode, false)
     |> assign(:selected_ids, MapSet.new())
     |> load_media_items(reset: true)}
  end

  def handle_event("show_delete_confirmation", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_delete_modal, true)
     |> assign(:delete_files, true)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_delete_modal, false)
     |> assign(:delete_files, false)}
  end

  def handle_event("toggle_delete_files", %{"delete_files" => value}, socket) do
    delete_files = value == "true"

    Logger.info("toggle_delete_files", value: value, delete_files: delete_files)

    {:noreply, assign(socket, :delete_files, delete_files)}
  end

  def handle_event("batch_delete_confirmed", _params, socket) do
    selected_ids = MapSet.to_list(socket.assigns.selected_ids)
    delete_files = socket.assigns.delete_files

    case Media.delete_media_items(selected_ids, delete_files: delete_files) do
      {:ok, count, error_count} ->
        message =
          cond do
            error_count > 0 ->
              "#{count} #{pluralize_items(count)} deleted, but #{error_count} " <>
                "#{pluralize_files(error_count)} could not be removed from disk. " <>
                "Check permissions and remove them manually."

            delete_files ->
              "#{count} #{pluralize_items(count)} deleted successfully (including files)"

            true ->
              "#{count} #{pluralize_items(count)} removed from library (files preserved)"
          end

        flash_kind = if error_count > 0, do: :error, else: :info

        {:noreply,
         socket
         |> put_flash(flash_kind, message)
         |> assign(:selection_mode, false)
         |> assign(:selected_ids, MapSet.new())
         |> assign(:show_delete_modal, false)
         |> assign(:delete_files, false)
         |> load_media_items(reset: true)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete items")
         |> assign(:show_delete_modal, false)
         |> assign(:delete_files, false)}
    end
  end

  def handle_event("show_batch_edit", _params, socket) do
    quality_profiles = Settings.list_quality_profiles()

    {:noreply,
     socket
     |> assign(:quality_profiles, quality_profiles)
     |> assign(:show_batch_edit_modal, true)
     |> assign(:batch_edit_form, to_form(%{}, as: :batch_edit))}
  end

  def handle_event("cancel_batch_edit", _params, socket) do
    {:noreply, assign(socket, :show_batch_edit_modal, false)}
  end

  def handle_event("batch_edit_submit", %{"batch_edit" => params}, socket) do
    selected_ids = MapSet.to_list(socket.assigns.selected_ids)

    # Build attrs map with only non-empty values
    attrs =
      %{}
      |> maybe_add_attr(:quality_profile_id, params["quality_profile_id"])
      |> maybe_add_attr(:monitored, params["monitored"])

    case Media.update_media_items_batch(selected_ids, attrs) do
      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{count} #{pluralize_items(count)} updated successfully")
         |> assign(:selection_mode, false)
         |> assign(:selected_ids, MapSet.new())
         |> assign(:show_batch_edit_modal, false)
         |> load_media_items(reset: true)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to update items")
         |> assign(:show_batch_edit_modal, false)}
    end
  end

  def handle_event("show_add_to_collection", _params, socket) do
    user = socket.assigns.current_scope.user
    user_collections = Collections.list_collections(user, type: "manual", include_shared: false)

    # Add item counts for each collection
    user_collections_with_counts =
      Enum.map(user_collections, fn collection ->
        Map.put(collection, :item_count, Collections.item_count(collection))
      end)

    {:noreply,
     socket
     |> assign(:user_collections, user_collections_with_counts)
     |> assign(:show_add_to_collection_modal, true)}
  end

  def handle_event("cancel_add_to_collection", _params, socket) do
    {:noreply, assign(socket, :show_add_to_collection_modal, false)}
  end

  def handle_event("batch_add_to_collection", %{"collection-id" => collection_id}, socket) do
    user = socket.assigns.current_scope.user
    selected_ids = MapSet.to_list(socket.assigns.selected_ids)

    case Collections.get_collection(user, collection_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Collection not found")}

      collection ->
        case Collections.add_items(collection, selected_ids) do
          {:ok, count} ->
            {:noreply,
             socket
             |> put_flash(:info, "Added #{count} #{pluralize_items(count)} to #{collection.name}")
             |> assign(:selection_mode, false)
             |> assign(:selected_ids, MapSet.new())
             |> assign(:show_add_to_collection_modal, false)}

          {:error, :smart_collection} ->
            {:noreply,
             socket
             |> put_flash(:error, "Cannot add items to smart collections")
             |> assign(:show_add_to_collection_modal, false)}

          {:error, _reason} ->
            {:noreply,
             socket
             |> put_flash(:error, "Failed to add to collection")
             |> assign(:show_add_to_collection_modal, false)}
        end
    end
  end

  def handle_event("trigger_rescan", _params, socket) do
    alias Mydia.Library

    case Library.trigger_full_library_scan() do
      # The scan job is unique, so this insert can be deduped into a scan that is
      # already queued (the boot-time repair scan waits out a jitter delay before
      # it runs). Don't claim a scan started, and don't switch the UI into a
      # scanning state that no broadcast will ever clear.
      {:ok, %Oban.Job{conflict?: true}} ->
        {:noreply, put_flash(socket, :info, "A library scan is already queued")}

      {:ok, _job} ->
        {:noreply,
         socket
         |> assign(:scanning, true)
         |> assign(:scan_result, nil)
         |> assign(:scan_progress, nil)
         |> put_flash(:info, "Library scan started...")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start library scan")}
    end
  end

  @impl true
  def handle_info({:download_updated, _download_id}, socket) do
    # Just trigger a re-render to update the downloads counter in the sidebar
    # The counter will be recalculated when the layout renders
    {:noreply, socket}
  end

  def handle_info({:library_scan_started, %{type: scan_type}}, socket) do
    # Only show scanning status if the scan matches the current page filter
    should_show =
      case {socket.assigns.filter_type, scan_type} do
        {nil, _} -> true
        {"movie", :movies} -> true
        {"tv_show", :series} -> true
        _ -> false
      end

    socket =
      if should_show do
        socket
        |> assign(:scanning, true)
        |> assign(:scan_progress, nil)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(
        {:library_scan_completed,
         %{
           type: scan_type,
           new_files: new_files,
           modified_files: modified_files,
           deleted_files: deleted_files
         }},
        socket
      ) do
    # Only process if the scan matches the current page filter
    should_process =
      case {socket.assigns.filter_type, scan_type} do
        {nil, _} -> true
        {"movie", :movies} -> true
        {"tv_show", :series} -> true
        _ -> false
      end

    socket =
      if should_process do
        total_changes = new_files + modified_files + deleted_files

        message =
          if total_changes > 0 do
            parts = []
            parts = if new_files > 0, do: ["#{new_files} new" | parts], else: parts
            parts = if modified_files > 0, do: ["#{modified_files} modified" | parts], else: parts
            parts = if deleted_files > 0, do: ["#{deleted_files} removed" | parts], else: parts
            "Library scan completed: " <> Enum.join(parts, ", ")
          else
            "Library scan completed: No changes detected"
          end

        socket
        |> assign(:scanning, false)
        |> assign(:scan_progress, nil)
        |> assign(:scan_result, %{
          new_files: new_files,
          modified_files: modified_files,
          deleted_files: deleted_files
        })
        |> put_flash(:info, message)
        |> load_media_items(reset: true)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:library_scan_failed, %{error: error}}, socket) do
    {:noreply,
     socket
     |> assign(:scanning, false)
     |> assign(:scan_progress, nil)
     |> put_flash(:error, "Library scan failed: #{error}")}
  end

  def handle_info({:library_scan_progress, progress}, socket) do
    {:noreply, assign(socket, :scan_progress, progress)}
  end

  def handle_info(msg, socket) do
    # Catch-all for unhandled PubSub messages to prevent crashes

    Logger.warning("Unhandled message in MediaLive.Index: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp run_batch_auto_search(socket) do
    ids = MapSet.to_list(socket.assigns.selected_ids)
    {items, skipped} = Media.partition_for_auto_search(ids)

    case Search.queue_auto_searches(items) do
      {:ok, queued} ->
        socket
        |> put_flash(:info, auto_search_flash(queued, skipped))
        |> assign(:selection_mode, false)
        |> assign(:selected_ids, MapSet.new())

      {:error, reason} ->
        Logger.error("Failed to queue bulk auto search",
          media_item_ids: ids,
          reason: inspect(reason)
        )

        put_flash(socket, :error, "Failed to queue searches")
    end
  end

  defp load_media_items(socket, opts) do
    reset? = Keyword.get(opts, :reset, false)
    page = if reset?, do: 0, else: socket.assigns.page
    offset = if page == 0, do: 0, else: @items_per_page + (page - 1) * @items_per_scroll
    limit = if page == 0, do: @items_per_page, else: @items_per_scroll

    query_opts = build_query_opts(socket.assigns)
    all_items = Media.list_media_items(query_opts)

    Logger.debug("load_media_items: total items from DB=#{length(all_items)}")

    # Apply search filtering (client-side for now)
    items = apply_search_filter(all_items, socket.assigns.search_query)
    Logger.debug("load_media_items: after search filter=#{length(items)}")

    # Apply quality filtering (client-side for now)
    items = apply_quality_filter(items, socket.assigns.filter_quality)
    Logger.debug("load_media_items: after quality filter=#{length(items)}")

    # Apply progress filtering (client-side for now)
    items = apply_progress_filter(items, socket.assigns.filter_progress)
    Logger.debug("load_media_items: after progress filter=#{length(items)}")

    # Apply sorting. The added-* sorts need content arrival times, which are
    # one aggregate rather than a per-item lookup.
    items =
      apply_sorting(items, socket.assigns.sort_by, added_at_map(items, socket.assigns.sort_by))

    # Apply pagination
    paginated_items = items |> Enum.drop(offset) |> Enum.take(limit)
    has_more = length(items) > offset + limit

    Logger.debug(
      "load_media_items: paginated=#{length(paginated_items)}, reset=#{reset?}, titles=#{inspect(Enum.map(paginated_items, & &1.title))}, ids=#{inspect(Enum.map(paginated_items, & &1.id))}"
    )

    # Track all visible item IDs for "Select All" functionality
    all_visible_ids = MapSet.new(items, & &1.id)

    socket =
      socket
      |> assign(:has_more, has_more)
      |> assign(:media_items_empty?, reset? and items == [])
      |> assign(:all_visible_ids, all_visible_ids)

    # Use reset: true when filtering/searching to properly clear and repopulate the stream
    socket =
      if reset? do
        stream(socket, :media_items, paginated_items, reset: true)
      else
        stream(socket, :media_items, paginated_items)
      end

    Logger.debug("stream updated, reset=#{reset?}, count=#{length(paginated_items)}")
    socket
  end

  defp build_query_opts(assigns) do
    user_id = assigns.current_user.id

    # Build preload queries filtered by current user / active (non-trashed) files
    import Ecto.Query
    progress_query = from p in Mydia.Playback.Progress, where: p.user_id == ^user_id
    active_files_query = from(mf in Mydia.Library.MediaFile, where: is_nil(mf.trashed_at))

    []
    |> maybe_add_filter(:type, assigns.filter_type)
    |> maybe_add_filter(:monitored, assigns.filter_monitored)
    |> maybe_add_filter(:library_path_type, assigns[:filter_library_type])
    |> Keyword.put(:preload, [
      :downloads,
      media_files: active_files_query,
      playback_progress: progress_query,
      episodes: [media_files: active_files_query, downloads: []]
    ])
  end

  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, key, value), do: Keyword.put(opts, key, value)

  defp apply_search_filter(items, ""), do: items

  defp apply_search_filter(items, query) do
    query_lower = String.downcase(query)

    filtered =
      Enum.filter(items, fn item ->
        title_match?(item.title, query_lower) or
          title_match?(item.original_title, query_lower) or
          year_match?(item.year, query_lower) or
          match_metadata_overview?(item.metadata, query_lower)
      end)

    Logger.debug(
      "Search filter: query=#{inspect(query)}, input_count=#{length(items)}, output_count=#{length(filtered)}"
    )

    filtered
  end

  defp title_match?(nil, _query), do: false

  defp title_match?(title, query) do
    String.contains?(String.downcase(title), query)
  end

  defp year_match?(nil, _query), do: false

  defp year_match?(year, query) do
    String.contains?(to_string(year), query)
  end

  defp match_metadata_overview?(nil, _query), do: false

  defp match_metadata_overview?(metadata, query) do
    case metadata do
      %MediaMetadata{overview: overview} when is_binary(overview) ->
        String.contains?(String.downcase(overview), query)

      _ ->
        false
    end
  end

  defp apply_quality_filter(items, nil), do: items

  defp apply_quality_filter(items, quality) do
    Enum.filter(items, fn item ->
      item.media_files
      |> Enum.any?(fn file -> file.resolution == quality end)
    end)
  end

  defp apply_progress_filter(items, nil), do: items

  # Reuses `Media.get_media_status/1` — the same classifier that renders each item's
  # status badge — so the filter can never disagree with what the badge says. Monitoring
  # is a separate axis now, so unmonitored items match on their real availability; narrow
  # with the monitored select to get monitored-only results.
  defp apply_progress_filter(items, progress) do
    Enum.filter(items, fn item ->
      Media.get_media_status(item).state == progress
    end)
  end

  # Only the added-* sorts need it, and the aggregate is not free, so skip it
  # for every other sort.
  defp added_at_map(items, sort_by) when sort_by in ["added_asc", "added_desc"] do
    Mydia.Media.RecentlyAdded.added_at_map(ids: Enum.map(items, & &1.id))
  end

  defp added_at_map(_items, _sort_by), do: %{}

  defp apply_sorting(items, sort_by, added_at) do
    Logger.debug("Applying sort: #{inspect(sort_by)} to #{length(items)} items")

    case sort_by do
      "title_asc" ->
        Enum.sort_by(items, &String.downcase(&1.title || ""), :asc)

      "title_desc" ->
        Enum.sort_by(items, &String.downcase(&1.title || ""), :desc)

      "year_asc" ->
        Enum.sort_by(items, &(&1.year || 0), :asc)

      "year_desc" ->
        Enum.sort_by(items, &(&1.year || 0), :desc)

      "added_asc" ->
        Enum.sort_by(items, &effective_added_at(&1, added_at), {:asc, DateTime})

      "added_desc" ->
        Enum.sort_by(items, &effective_added_at(&1, added_at), {:desc, DateTime})

      "rating_asc" ->
        Enum.sort_by(items, &get_rating(&1), :asc)

      "rating_desc" ->
        Enum.sort_by(items, &get_rating(&1), :desc)

      "last_aired_asc" ->
        Enum.sort_by(items, &get_last_aired_date(&1), {:asc, Date})

      "last_aired_desc" ->
        Enum.sort_by(items, &get_last_aired_date(&1), {:desc, Date})

      "next_aired_asc" ->
        Enum.sort_by(items, &get_next_aired_date(&1), {:asc, Date})

      "next_aired_desc" ->
        Enum.sort_by(items, &get_next_aired_date(&1), {:desc, Date})

      "episode_count_asc" ->
        Enum.sort_by(items, &get_episode_count(&1), :asc)

      "episode_count_desc" ->
        Enum.sort_by(items, &get_episode_count(&1), :desc)

      _ ->
        # Default to title ascending
        Enum.sort_by(items, &String.downcase(&1.title || ""), :asc)
    end
  end

  # A wanted item with no files has no content arrival time. Its own
  # inserted_at is then the only meaningful answer for "when was this added",
  # and it keeps the sort total.
  defp effective_added_at(item, added_at) do
    Map.get(added_at, item.id) || item.inserted_at
  end

  defp get_rating(media_item) do
    case media_item.metadata do
      %MediaMetadata{vote_average: rating} when is_number(rating) -> rating
      _ -> 0
    end
  end

  # Episode `air_date` is a Date, so these sentinels and comparisons stay in Date
  # terms: sorting them as NaiveDateTime raises, since a Date has no time fields.
  @never_aired ~D[1970-01-01]
  @no_upcoming_airing ~D[2999-12-31]

  defp get_last_aired_date(media_item) do
    if media_item.type == "tv_show" && Ecto.assoc_loaded?(media_item.episodes) do
      media_item.episodes
      |> Enum.map(& &1.air_date)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort({:desc, Date})
      |> List.first()
      |> case do
        nil -> @never_aired
        date -> date
      end
    else
      @never_aired
    end
  end

  defp get_next_aired_date(media_item) do
    if media_item.type == "tv_show" && Ecto.assoc_loaded?(media_item.episodes) do
      today = Date.utc_today()

      media_item.episodes
      |> Enum.map(& &1.air_date)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(Date.compare(&1, today) == :gt))
      |> Enum.sort({:asc, Date})
      |> List.first()
      |> case do
        nil -> @no_upcoming_airing
        date -> date
      end
    else
      @no_upcoming_airing
    end
  end

  defp get_episode_count(media_item) do
    if media_item.type == "tv_show" && Ecto.assoc_loaded?(media_item.episodes) do
      length(media_item.episodes)
    else
      0
    end
  end

  defp get_poster_url(media_item) do
    case media_item.metadata do
      %MediaMetadata{poster_path: path} when is_binary(path) ->
        ImageUrl.poster_url(path)

      _ ->
        "/images/no-poster.svg"
    end
  end

  defp get_progress(media_item) do
    # Since playback_progress is has_many but filtered by user_id,
    # there should only be one (or zero) progress records
    if Ecto.assoc_loaded?(media_item.playback_progress) do
      case media_item.playback_progress do
        [progress | _] -> progress
        [] -> nil
        _ -> nil
      end
    else
      nil
    end
  end

  defp format_year(nil), do: "N/A"
  defp format_year(year), do: year

  defp get_quality_badge(media_item) do
    case media_item.media_files do
      [] ->
        nil

      files ->
        # Get the highest quality from available files
        files
        |> Enum.map(& &1.resolution)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort(:desc)
        |> List.first()
    end
  end

  defp format_file_size(nil), do: "N/A"

  defp format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776, 2)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp total_file_size(media_item) do
    media_item.media_files
    |> Enum.map(& &1.size)
    |> Enum.reject(&is_nil/1)
    |> Enum.sum()
  end

  defp pluralize_items(1), do: "item"
  defp pluralize_items(_), do: "items"

  defp pluralize_files(1), do: "file"
  defp pluralize_files(_), do: "files"

  defp auto_search_flash(0, 0), do: "Nothing to search"

  defp auto_search_flash(0, 1), do: "Nothing to search. The selected item does not need a search."

  defp auto_search_flash(0, skipped) do
    "Nothing to search. None of the #{skipped} selected items need a search."
  end

  defp auto_search_flash(queued, 0) do
    "Queued #{queued} #{pluralize_searches(queued)}"
  end

  defp auto_search_flash(queued, 1) do
    "Queued #{queued} #{pluralize_searches(queued)}, skipped 1 that does not need one"
  end

  defp auto_search_flash(queued, skipped) do
    "Queued #{queued} #{pluralize_searches(queued)}, skipped #{skipped} that do not need one"
  end

  defp pluralize_searches(1), do: "search"
  defp pluralize_searches(_), do: "searches"

  defp maybe_add_attr(attrs, _key, nil), do: attrs
  defp maybe_add_attr(attrs, _key, ""), do: attrs
  defp maybe_add_attr(attrs, _key, "no_change"), do: attrs

  defp maybe_add_attr(attrs, key, value) do
    Map.put(attrs, key, value)
  end

  # Media status helpers
  defp get_media_item_status(media_item) do
    Media.get_media_status(media_item)
  end

  defp media_status_color(status), do: AvailabilityStatus.color(status)

  defp media_status_icon(status), do: AvailabilityStatus.icon(status)

  defp media_status_label(status), do: AvailabilityStatus.label(status)

  defp format_episode_count(%AvailabilityStatus{downloaded: downloaded, total: total})
       when is_integer(downloaded) and is_integer(total),
       do: "#{downloaded}/#{total} episodes"

  defp format_episode_count(_), do: nil
end
