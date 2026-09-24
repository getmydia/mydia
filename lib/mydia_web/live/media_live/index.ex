defmodule MydiaWeb.MediaLive.Index do
  use MydiaWeb, :live_view
  alias Mydia.Accounts
  alias Mydia.Media
  alias Mydia.Media.AvailabilityStatus
  alias Mydia.Media.DiskRemoval
  alias Mydia.Media.LibraryListing
  alias Mydia.Media.LibraryRow
  alias Mydia.Settings
  alias Mydia.Collections
  alias Mydia.Collections.Collection
  alias Mydia.Collections.SmartRules
  alias Mydia.Downloads.DownloadService
  alias Mydia.Search
  alias MydiaWeb.Live.Authorization
  alias MydiaWeb.Live.Helpers.GridDensity
  alias MydiaWeb.MediaLive.DiskRemovalFlash

  import MydiaWeb.Formatters, only: [format_file_size: 1]
  import MydiaWeb.GridDensityComponents
  import MydiaWeb.MediaLive.Index.SectionComponents
  import MydiaWeb.MediaLive.Index.SelectionComponents

  require Logger

  @items_per_page 50
  @items_per_scroll 25
  @auto_search_confirm_threshold 50

  # Ten is enough anime to be a nuisance in a mixed list and few enough that a
  # library with a handful of stray titles is left alone.
  @anime_nudge_threshold 10

  # Library path types that can hold each page's media. :mixed serves both.
  @library_types %{movies: [:movies, :mixed], tv_shows: [:series, :mixed]}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mydia.PubSub, "downloads")
      Phoenix.PubSub.subscribe(Mydia.PubSub, "library_scanner")
    end

    {:ok,
     socket
     |> assign(:view_mode, :grid)
     |> GridDensity.assign_current()
     |> assign(:search_query, "")
     |> assign(:filter_progress, nil)
     |> assign(:filter_monitored, nil)
     |> assign(:filter_quality, nil)
     |> assign(:filter_library, nil)
     |> assign(:library_options, [])
     |> assign(:sort_by, "title_asc")
     |> assign(:page, 0)
     |> assign(:has_more, false)
     |> assign(:loading?, true)
     |> assign(:media_items_empty?, false)
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
     |> assign(:section, nil)
     |> assign(:section_owned?, false)
     |> assign(:section_query, nil)
     |> assign(:section_error, false)
     |> assign(:show_section_settings, false)
     |> assign(:section_form, nil)
     |> assign(:section_exclusive_eligible, false)
     |> assign(:show_anime_nudge, false)
     |> assign(:show_add_to_collection_modal, false)
     |> assign(:user_collections, [])
     |> assign(:all_visible_ids, MapSet.new())
     |> assign(:total_size, 0)
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
    |> assign(:show_anime_nudge, anime_nudge?(socket))
    |> assign_library_options(:movies)
    |> load_media_items_when_connected()
  end

  defp apply_action(socket, :tv_shows, _params) do
    socket
    |> assign(:page_title, "TV Shows")
    |> assign(:filter_type, "tv_show")
    |> assign(:show_anime_nudge, anime_nudge?(socket))
    |> assign_library_options(:tv_shows)
    |> load_media_items_when_connected()
  end

  defp apply_action(socket, :section, %{"id" => id}) do
    case Collections.get_collection(socket.assigns.current_user, id) do
      %Collection{type: "smart"} = collection ->
        socket
        |> assign(:page_title, collection.name)
        # mount/3 does not assign :filter_type; only :movies and :tv_shows do.
        # The library scan handlers read it unguarded, and their existing
        # {nil, _} clause is the right behaviour for a section. Likewise
        # :filter_library/:library_options: /movies, /tv and /sections/:id
        # share this module and live_session, so navigating between them
        # patches the existing process instead of remounting it, and a
        # library chosen on /movies would otherwise leak into a section.
        |> assign(:filter_type, nil)
        |> assign(:filter_library, nil)
        |> assign(:library_options, [])
        |> assign(:section, collection)
        |> assign(:section_owned?, collection.user_id == socket.assigns.current_user.id)
        |> load_section(collection)

      _not_found_or_not_smart ->
        socket
        |> put_flash(:error, "That section is no longer available.")
        |> push_navigate(to: ~p"/")
    end
  end

  defp load_section(socket, collection) do
    case SmartRules.query(collection.smart_rules || "{}") do
      {:ok, query} ->
        socket
        |> assign(:section_query, query)
        |> assign(:section_error, false)
        |> load_media_items_when_connected()

      {:error, reason} ->
        Logger.warning("Section #{collection.id} has unusable rules: #{inspect(reason)}")

        socket
        |> assign(:section_query, nil)
        |> assign(:section_error, true)
        |> assign(:loading?, false)
        |> assign(:media_items_empty?, true)
        |> assign(:all_visible_ids, MapSet.new())
        |> assign(:total_size, 0)
        |> assign(:has_more, false)
        |> stream(:media_items, [], reset: true)
    end
  end

  defp anime_nudge?(socket) do
    user = socket.assigns.current_user
    anime = Enum.map(Mydia.Media.MediaCategory.anime_categories(), &Atom.to_string/1)
    pinned = Collections.pinned_categories(socket.assigns[:sections] || [])

    cond do
      Accounts.anime_nudge_dismissed?(user) -> false
      Enum.any?(anime, &(&1 in pinned)) -> false
      true -> Media.count_media_items(category_in: anime) >= @anime_nudge_threshold
    end
  end

  # Runtime-config entries carry a "runtime::" id that never appears on a file,
  # and LibraryPathSync normally persists them as real rows anyway. A selection
  # that no longer fits (a disabled library, or the other page's type) resets.
  defp assign_library_options(socket, action) do
    types = Map.fetch!(@library_types, action)

    options =
      Enum.filter(
        Settings.list_library_paths(),
        &(&1.type in types and not Settings.runtime_config?(&1))
      )

    selected = socket.assigns.filter_library

    socket
    |> assign(:library_options, options)
    |> assign(:filter_library, if(Enum.any?(options, &(&1.id == selected)), do: selected))
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

  def handle_event("set_grid_density", %{"density" => density}, socket) do
    {:noreply, GridDensity.put(socket, density)}
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

    library =
      Enum.find_value(socket.assigns.library_options, fn lp ->
        if lp.id == params["library"], do: lp.id
      end)

    sort_by = params["sort_by"] || socket.assigns.sort_by
    Logger.debug("Sort by: #{inspect(sort_by)}")

    {:noreply,
     socket
     |> assign(:filter_progress, progress)
     |> assign(:filter_monitored, monitored)
     |> assign(:filter_quality, quality)
     |> assign(:filter_library, library)
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

  # Sent by a card's hover checkbox. Unknown or filtered-out ids are accepted
  # exactly as toggle_select accepts them; MapSet.put makes a repeated click
  # harmless.
  def handle_event("start_selection", params, socket) do
    case selection_id(params["id"]) do
      {:ok, id} ->
        {:noreply,
         socket
         |> assign(:selection_mode, true)
         |> assign(:selected_ids, MapSet.put(socket.assigns.selected_ids, id))}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_select", %{"id" => id}, socket) do
    if socket.assigns.selection_mode do
      {:noreply, toggle_selected_id(socket, selection_id(id))}
    else
      # Not in selection mode, navigate to the item
      {:noreply, push_navigate(socket, to: ~p"/media/#{id}")}
    end
  end

  def handle_event("select_all", _params, socket) do
    {:noreply, select_all_visible(socket)}
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
    {:noreply, select_all_visible(socket)}
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
        socket =
          case LibraryListing.row(id, socket.assigns.current_user.id) do
            nil -> socket
            row -> stream_insert(socket, :media_items, row)
          end

        {:noreply,
         put_flash(
           socket,
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
      {:ok, count, %DiskRemoval{} = removal} ->
        {kind, message} = DiskRemovalFlash.for_items(count, delete_files, removal)

        {:noreply,
         socket
         |> put_flash(kind, message)
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
        %{collection | item_count: Collections.item_count(collection)}
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

  def handle_event("open_section_settings", _params, socket) do
    with_section(socket, fn section ->
      {:noreply,
       socket
       |> assign(:show_section_settings, true)
       |> assign(:section_exclusive_eligible, Collections.exclusive_eligible?(section))
       |> assign(
         :section_form,
         to_form(
           %{
             "name" => section.name,
             "sidebar_icon" => section.sidebar_icon,
             "exclusive" => section.exclusive
           },
           as: :section
         )
       )}
    end)
  end

  def handle_event("close_section_settings", _params, socket) do
    {:noreply, assign(socket, :show_section_settings, false)}
  end

  def handle_event("save_section", %{"section" => params}, socket) do
    with_section(socket, fn section ->
      user = socket.assigns.current_user

      attrs = %{
        name: params["name"],
        sidebar_icon: params["sidebar_icon"],
        exclusive: params["exclusive"] == "true" and Collections.exclusive_eligible?(section)
      }

      case Collections.update_collection(user, section, attrs) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> assign(:section, updated)
           |> assign(:page_title, updated.name)
           |> assign(:show_section_settings, false)
           |> assign(:excluded_categories, Collections.claimed_categories(user))
           |> put_flash(:info, "Section updated")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Could not update the section")}
      end
    end)
  end

  def handle_event("unpin_section", _params, socket) do
    with_section(socket, fn section ->
      user = socket.assigns.current_user

      case Collections.unpin_section(user, section) do
        {:ok, _collection} ->
          {:noreply,
           socket
           |> put_flash(:info, "Section removed from the sidebar")
           |> push_navigate(to: ~p"/tv")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Could not remove the section")}
      end
    end)
  end

  def handle_event("dismiss_anime_nudge", _params, socket) do
    Accounts.dismiss_anime_nudge(socket.assigns.current_user)
    {:noreply, assign(socket, :show_anime_nudge, false)}
  end

  def handle_event("accept_anime_nudge", _params, socket) do
    user = socket.assigns.current_user
    preset = Mydia.Collections.SectionPresets.get("anime")

    with {:ok, collection} <-
           Collections.create_collection(user, %{
             name: preset.name,
             type: "smart",
             visibility: "private",
             smart_rules: Jason.encode!(preset.rules)
           }),
         {:ok, pinned} <-
           Collections.pin_section(user, collection,
             sidebar_icon: preset.icon,
             exclusive: preset.exclusive
           ) do
      Accounts.dismiss_anime_nudge(user)
      {:noreply, push_navigate(socket, to: ~p"/sections/#{pinned.id}")}
    else
      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not create the Anime section")}
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
           deleted_files: deleted_files,
           auto_linked: auto_linked
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
        message =
          scan_completed_message(%{
            new_files: new_files,
            modified_files: modified_files,
            deleted_files: deleted_files,
            auto_linked: auto_linked
          })

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

  # Guards event handlers that only make sense on a section page. A
  # hand-crafted client event fired from /movies or /tv, where @section is
  # nil, would otherwise crash the socket instead of being a no-op.
  defp with_section(socket, fun) do
    case socket.assigns.section do
      nil -> {:noreply, socket}
      section -> fun.(section)
    end
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

  # Selected ids end up in batch queries on a :binary_id key, where PostgreSQL
  # raises Ecto.Query.CastError for anything that is not a UUID.
  defp selection_id(id) when is_binary(id), do: Ecto.UUID.cast(id)
  defp selection_id(_id), do: :error

  defp toggle_selected_id(socket, {:ok, id}) do
    update(socket, :selected_ids, fn selected_ids ->
      if MapSet.member?(selected_ids, id),
        do: MapSet.delete(selected_ids, id),
        else: MapSet.put(selected_ids, id)
    end)
  end

  defp toggle_selected_id(socket, :error), do: socket

  # The HTTP render paints a skeleton and loads nothing. The connected mount
  # runs handle_params again moments later, so loading here doubled the cost
  # of every full page load.
  defp load_media_items_when_connected(socket) do
    if connected?(socket), do: load_media_items(socket, reset: true), else: socket
  end

  defp load_media_items(socket, opts) do
    reset? = Keyword.get(opts, :reset, false)
    page = if reset?, do: 0, else: socket.assigns.page
    offset = if page == 0, do: 0, else: @items_per_page + (page - 1) * @items_per_scroll
    limit = if page == 0, do: @items_per_page, else: @items_per_scroll

    listing = LibraryListing.page(listing_opts(socket.assigns, offset: offset, limit: limit))

    socket
    |> assign(:has_more, listing.has_more?)
    |> assign(:loading?, false)
    |> assign(:media_items_empty?, reset? and listing.empty?)
    # Every matching id, not only the page, for "Select All".
    |> assign(:all_visible_ids, listing.visible_ids)
    |> assign(:total_size, listing.total_size)
    |> stream(:media_items, listing.rows, reset: reset?)
  end

  # Selects everything the current filters match, including items past the
  # rendered page. limit: 0 skips loading progress for rows nobody renders.
  defp select_all_visible(socket) do
    %{visible_ids: ids} = LibraryListing.page(listing_opts(socket.assigns, offset: 0, limit: 0))

    assign(socket, :selected_ids, ids)
  end

  defp listing_opts(assigns, page_opts) do
    []
    |> maybe_add_filter(:base_query, assigns[:section_query])
    # A section's own base_query already selects its claimed categories, so
    # excluding those same categories here would contradict it and empty the
    # section out. The exclusion only makes sense off of section pages, where
    # it is what removes claimed items from the built-in Movies/TV listings.
    |> maybe_add_filter(
      :exclude_categories,
      if(is_nil(assigns[:section]), do: assigns[:excluded_categories], else: [])
    )
    |> maybe_add_filter(:type, assigns.filter_type)
    |> maybe_add_filter(:monitored, assigns.filter_monitored)
    |> maybe_add_filter(:library_path_id, assigns[:filter_library])
    |> Keyword.merge(
      user_id: assigns.current_user.id,
      search: assigns.search_query,
      quality: assigns.filter_quality,
      progress: assigns.filter_progress,
      sort_by: assigns.sort_by
    )
    |> Keyword.merge(page_opts)
  end

  defp maybe_add_filter(opts, _key, []), do: opts
  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, key, value), do: Keyword.put(opts, key, value)

  defp get_poster_url(media_item),
    do: MydiaWeb.Live.Helpers.MediaImages.poster_url(media_item)

  defp get_progress(%LibraryRow{progress: progress}), do: progress

  defp format_year(nil), do: "N/A"
  defp format_year(year), do: year

  # Ranked by parsed height rather than lexically: comparing the raw strings
  # puts "720p" ahead of "2160p", and a show's episodes routinely mix
  # resolutions.
  defp get_quality_badge(%LibraryRow{resolutions: resolutions}) do
    Enum.max_by(resolutions, &DownloadService.parse_resolution_height/1, fn -> nil end)
  end

  defp total_file_size(%LibraryRow{total_size: total_size}), do: total_size

  defp pluralize_items(1), do: "item"
  defp pluralize_items(_), do: "items"

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

  defp get_media_item_status(%LibraryRow{status: status}), do: status

  defp media_status_color(status), do: AvailabilityStatus.color(status)

  defp media_status_icon(status), do: AvailabilityStatus.icon(status)

  defp media_status_label(status), do: AvailabilityStatus.label(status)

  defp format_episode_count(%AvailabilityStatus{downloaded: downloaded, total: total})
       when is_integer(downloaded) and is_integer(total),
       do: "#{downloaded}/#{total} episodes"

  defp format_episode_count(_), do: nil

  @doc false
  # Public so the copy can be unit-tested without mounting the LiveView.
  #
  # `auto_linked` is a subset of the files a scan touched, so it is appended as
  # detail and kept out of the change total. It is also counted on its own,
  # because the orphan branch links existing files: a scan can auto-import
  # without any on-disk change at all, and reporting "No changes detected"
  # there would hide the exact work the flag was turned on for.
  @spec scan_completed_message(map()) :: String.t()
  def scan_completed_message(%{
        new_files: new_files,
        modified_files: modified_files,
        deleted_files: deleted_files,
        auto_linked: auto_linked
      }) do
    parts = []
    parts = if new_files > 0, do: ["#{new_files} new" | parts], else: parts
    parts = if modified_files > 0, do: ["#{modified_files} modified" | parts], else: parts
    parts = if deleted_files > 0, do: ["#{deleted_files} removed" | parts], else: parts

    parts =
      if auto_linked > 0, do: parts ++ ["#{auto_linked} imported automatically"], else: parts

    if parts == [] do
      "Library scan completed: No changes detected"
    else
      "Library scan completed: " <> Enum.join(parts, ", ")
    end
  end
end
