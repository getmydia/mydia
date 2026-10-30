defmodule MydiaWeb.MediaLive.Index do
  use MydiaWeb, :live_view
  alias Mydia.Accounts
  alias Mydia.Accounts.PosterFields
  alias Mydia.Media
  alias Mydia.Media.AvailabilityStatus
  alias Mydia.Media.DiskRemoval
  alias Mydia.Media.LibraryListing
  alias Mydia.Media.LibraryRow
  alias Mydia.Media.ShowStatus
  alias Mydia.Settings
  alias Mydia.Collections
  alias Mydia.Collections.Collection
  alias Mydia.Collections.SmartRules
  alias Mydia.Downloads.DownloadService
  alias Mydia.Search
  alias Mydia.Settings.LibraryPath
  alias MydiaWeb.Live.Authorization
  alias MydiaWeb.Live.Helpers.GridDensity
  alias MydiaWeb.Live.Helpers.PosterFields, as: PosterFieldsPref
  alias MydiaWeb.MediaLive.DiskRemovalFlash
  alias MydiaWeb.MediaLive.Index.LibraryActions
  alias MydiaWeb.MediaLive.Index.ListingParams
  alias MydiaWeb.MediaLive.Index.Messages
  alias MydiaWeb.MediaLive.Index.ReclassifyFlash
  alias MydiaWeb.MediaLive.Index.RememberedListing
  alias MydiaWeb.MediaLive.Index.Window

  import MydiaWeb.Formatters, only: [format_file_size: 1]

  import MydiaWeb.MediaLive.Index.Window,
    only: [load_media_items: 1, load_media_items_when_connected: 3]

  import MydiaWeb.MediaLive.Index.Messages,
    only: [batch_monitored_message: 2, auto_search_flash: 2, format_episode_count: 1]

  import MydiaWeb.GridDensityComponents
  import MydiaWeb.MediaLive.Index.AlphaJumpComponents
  import MydiaWeb.MediaLive.Index.SectionComponents
  import MydiaWeb.MediaLive.Index.SelectionComponents

  require Logger

  @auto_search_confirm_threshold 50

  # Ten is enough anime to be a nuisance in a mixed list and few enough that a
  # library with a handful of stray titles is left alone.
  @anime_nudge_threshold 10

  # Library path types that can hold each page's media, from LibraryPath's own
  # movie/series type lists so a third type never has to be kept in sync here.
  @library_types %{
    movies: LibraryPath.movie_library_types(),
    tv_shows: LibraryPath.series_library_types()
  }

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mydia.PubSub, "downloads")
      Phoenix.PubSub.subscribe(Mydia.PubSub, "library_scanner")
    end

    {:ok,
     socket
     |> assign(:view_mode, :grid)
     |> GridDensity.assign_current(session)
     |> PosterFieldsPref.assign_current()
     |> assign_listing_params(%ListingParams{})
     |> assign(:page_key, nil)
     |> assign(:remembered_listing, %{})
     |> assign(:library_options, [])
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
     |> assign(:description_match_start_id, nil)
     |> Window.reset()}
  end

  @impl true
  # /movies, /tv and /sections/:id share this process across live navigation.
  # The page itself (title, library options, section rules) is only set up
  # when the route changes; a patch that only changes the URL's listing state,
  # including load_more's own `shown` patch, goes straight to the listing.
  def handle_params(params, url, socket) do
    page_key = {socket.assigns.live_action, params["id"]}
    # The page's own path (/movies, /tv, /sections/:id), for listing patches.
    socket = assign(socket, :listing_base_path, URI.parse(url).path)

    socket =
      if page_key == socket.assigns.page_key do
        apply_listing_params(socket, params, false)
      else
        socket =
          socket
          |> assign(:page_key, page_key)
          |> apply_action(socket.assigns.live_action, params)

        {socket, params, restored_path} =
          RememberedListing.restore(socket, params, library_choices(socket))

        socket
        |> apply_listing_params(params, true)
        |> RememberedListing.patch_restored(restored_path)
      end

    {:noreply, socket}
  end

  defp apply_action(socket, :movies, _params) do
    socket
    |> assign(:page_title, gettext("Movies"))
    |> assign(:filter_type, "movie")
    |> assign(:show_anime_nudge, anime_nudge?(socket))
    |> assign_library_options(:movies)
  end

  defp apply_action(socket, :tv_shows, _params) do
    socket
    |> assign(:page_title, gettext("TV Shows"))
    |> assign(:filter_type, "tv_show")
    |> assign(:show_anime_nudge, anime_nudge?(socket))
    |> assign_library_options(:tv_shows)
  end

  defp apply_action(socket, :section, %{"id" => id}) do
    case Collections.get_collection(socket.assigns.current_user, id) do
      %Collection{type: "smart"} = collection ->
        socket
        |> assign(:page_title, collection.name)
        # mount/3 does not assign :filter_type; only :movies and :tv_shows do.
        # The library scan handlers read it unguarded, and their existing
        # {nil, _} clause is the right behaviour for a section. Likewise
        # :library_options, which sections do not have.
        |> assign(:filter_type, nil)
        |> assign(:library_options, [])
        |> assign(:section, collection)
        |> assign(:section_owned?, collection.user_id == socket.assigns.current_user.id)
        |> load_section(collection)

      _not_found_or_not_smart ->
        socket
        |> put_flash(:error, gettext("That section is no longer available."))
        |> push_navigate(to: ~p"/")
    end
  end

  defp load_section(socket, collection) do
    case SmartRules.query(collection.smart_rules || "{}") do
      {:ok, query} ->
        socket
        |> assign(:section_query, query)
        |> assign(:section_error, false)

      {:error, reason} ->
        Logger.warning("Section #{collection.id} has unusable rules: #{inspect(reason)}")

        socket
        |> assign(:section_query, nil)
        |> assign(:section_error, true)
        |> assign(:loading?, false)
        |> assign(:media_items_empty?, true)
        |> assign(:all_visible_ids, MapSet.new())
        |> assign(:total_size, 0)
        |> assign(:description_match_start_id, nil)
        |> Window.reset()
    end
  end

  defp anime_nudge?(socket) do
    user = socket.assigns.current_user
    anime = Enum.map(Mydia.Media.MediaCategory.anime_categories(), &Atom.to_string/1)
    pinned = Collections.pinned_categories(socket.assigns[:sections] || [])

    cond do
      Accounts.anime_nudge_dismissed?(user) ->
        false

      Enum.any?(anime, &(&1 in pinned)) ->
        false

      true ->
        Media.count_media_items(socket.assigns.current_scope, category_in: anime) >=
          @anime_nudge_threshold
    end
  end

  # Runtime-config entries carry a "runtime::" id that never appears on a file,
  # and LibraryPathSync normally persists them as real rows anyway. A selection
  # that no longer fits (a disabled library, or the other page's type) resets,
  # and so does one on a page with fewer than two options, where the select is
  # hidden and the user could not clear it. The selection itself now comes from
  # the URL and is validated by library_choices/1.
  defp assign_library_options(socket, action) do
    types = Map.fetch!(@library_types, action)

    options =
      Enum.filter(
        Settings.list_library_paths(),
        &(&1.type in types and not Settings.runtime_config?(&1))
      )

    socket
    |> assign(:library_options, options)
    |> assign(:library_labels, LibraryPath.display_names(options))
  end

  @impl true
  def handle_event("toggle_view", %{"mode" => mode}, socket) do
    view_mode = String.to_existing_atom(mode)

    {:noreply,
     socket
     |> assign(:view_mode, view_mode)
     |> load_media_items()}
  end

  # The phone letter picker: the same patch the strip's links make, looked up
  # in the server's own paths so the client cannot choose the destination.
  def handle_event("jump_letter", %{"letter" => letter}, socket) do
    case socket.assigns.letter_paths do
      %{^letter => path} -> {:noreply, push_patch(socket, to: path, replace: true)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("set_grid_density", %{"density" => density}, socket) do
    {:noreply, GridDensity.put(socket, density)}
  end

  # A stream's already-rendered items are never re-diffed just because another
  # assign they read (here, @poster_fields) changed; `phx-update="stream"`
  # only reconciles items that are explicitly inserted or deleted in the
  # current diff (see toggle_item_monitored's own explicit stream_insert
  # below). Re-running the same load the "search"/"filter" events use is the
  # existing way this LiveView forces every visible card to re-render.
  def handle_event("set_poster_fields", params, socket) do
    fields = params |> Map.get("fields", []) |> List.wrap() |> Enum.reject(&(&1 == ""))

    {:noreply,
     socket
     |> PosterFieldsPref.put(fields)
     |> load_media_items()}
  end

  def handle_event("reset_poster_fields", _params, socket) do
    defaults = Enum.map(PosterFields.default_keys(), &Atom.to_string/1)

    {:noreply,
     socket
     |> PosterFieldsPref.put(defaults)
     |> load_media_items()}
  end

  def handle_event("search", params, socket) do
    query = params["search"] || params["value"] || ""
    {:noreply, patch_listing(socket, %{Window.listing_params(socket.assigns) | search: query})}
  end

  def handle_event("filter", params, socket) do
    current = Window.listing_params(socket.assigns)

    form = %{
      "q" => current.search,
      "library" => params["library"],
      "progress" => params["progress"],
      "monitored" => params["monitored"],
      "quality" => params["quality"],
      "sort" => params["sort_by"] || current.sort
    }

    {:noreply, patch_listing(socket, ListingParams.parse(form, library_choices(socket)))}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, patch_listing(socket, %ListingParams{}, true)}
  end

  # Replies so the LoadMoreSentinel hook knows the batch has landed.
  def handle_event("load_more", _params, socket) do
    socket =
      if socket.assigns.has_more,
        do: socket |> Window.load_next_batch() |> patch_window(),
        else: socket

    {:reply, %{}, socket}
  end

  # The top sentinel after a jump. The URL counts the rows loaded above the
  # letter, so Back and reloads put them back and the page does not shift.
  def handle_event("load_previous", _params, socket) do
    socket =
      if socket.assigns.has_previous,
        do: socket |> Window.load_previous_batch() |> patch_window(),
        else: socket

    {:reply, %{}, socket}
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
    with_media_permission(socket, :update, &batch_set_monitored(&1, true))
  end

  def handle_event("batch_unmonitor", _params, socket) do
    with_media_permission(socket, :update, &batch_set_monitored(&1, false))
  end

  def handle_event("toggle_item_monitored", %{"id" => id}, socket) do
    with_media_permission(socket, :update, &LibraryActions.toggle_monitored(&1, id))
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
    with_media_permission(socket, :update, &batch_reclassify/1)
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
    with_media_permission(socket, :delete, &batch_delete_selected/1)
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
    with_media_permission(socket, :update, &batch_edit_selected(&1, params))
  end

  def handle_event("show_add_to_collection", _params, socket) do
    scope = socket.assigns.current_scope
    user = scope.user
    user_collections = Collections.list_collections(user, type: "manual", include_shared: false)

    # Add item counts for each collection
    user_collections_with_counts =
      Enum.map(user_collections, fn collection ->
        %{collection | item_count: Collections.item_count(scope, collection)}
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
        {:noreply, put_flash(socket, :error, gettext("Collection not found"))}

      collection ->
        case Collections.add_items(collection, selected_ids) do
          {:ok, count} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               ngettext(
                 "Added %{count} item to %{name}",
                 "Added %{count} items to %{name}",
                 count,
                 name: collection.name
               )
             )
             |> assign(:selection_mode, false)
             |> assign(:selected_ids, MapSet.new())
             |> assign(:show_add_to_collection_modal, false)}

          {:error, :smart_collection} ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("Cannot add items to smart collections"))
             |> assign(:show_add_to_collection_modal, false)}

          {:error, _reason} ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("Failed to add to collection"))
             |> assign(:show_add_to_collection_modal, false)}
        end
    end
  end

  def handle_event("trigger_rescan", _params, socket) do
    with_media_permission(socket, :update, &LibraryActions.start_scan/1)
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
           |> put_flash(:info, gettext("Section updated"))}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Could not update the section"))}
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
           |> put_flash(:info, gettext("Section removed from the sidebar"))
           |> push_navigate(to: ~p"/tv")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Could not remove the section"))}
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
        {:noreply, put_flash(socket, :error, gettext("Could not create the Anime section"))}
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
          Messages.scan_completed_message(%{
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
        |> load_media_items()
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
     |> put_flash(:error, gettext("Library scan failed: %{error}", error: error))}
  end

  def handle_info({:library_scan_progress, progress}, socket) do
    {:noreply, assign(socket, :scan_progress, progress)}
  end

  def handle_info(msg, socket) do
    # Catch-all for unhandled PubSub messages to prevent crashes

    Logger.warning("Unhandled message in MediaLive.Index: #{inspect(msg)}")
    {:noreply, socket}
  end

  # Library write events arrive over the socket from any authenticated role,
  # including guests and readonly users, so each one checks the role itself.
  defp with_media_permission(socket, permission, fun) do
    with :ok <- authorize_media(permission, socket) do
      fun.(socket)
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  defp authorize_media(:update, socket), do: Authorization.authorize_update_media(socket)
  defp authorize_media(:delete, socket), do: Authorization.authorize_delete_media(socket)

  defp batch_set_monitored(socket, monitored) do
    selected_ids = MapSet.to_list(socket.assigns.selected_ids)

    case Media.update_media_items_monitored(socket.assigns.current_scope, selected_ids, monitored) do
      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(:info, batch_monitored_message(count, monitored))
         |> assign(:selection_mode, false)
         |> assign(:selected_ids, MapSet.new())
         |> load_media_items()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update items"))}
    end
  end

  defp batch_reclassify(socket) do
    selected_ids = MapSet.to_list(socket.assigns.selected_ids)

    visible_ids =
      socket.assigns.current_scope
      |> Media.list_media_items(ids: selected_ids)
      |> Enum.map(& &1.id)

    {:ok, summary} = Media.reclassify_media_items(visible_ids)

    {:noreply,
     socket
     |> put_flash(:info, ReclassifyFlash.message(summary))
     |> assign(:selection_mode, false)
     |> assign(:selected_ids, MapSet.new())
     |> load_media_items()}
  end

  defp batch_delete_selected(socket) do
    selected_ids = MapSet.to_list(socket.assigns.selected_ids)
    delete_files = socket.assigns.delete_files

    case Media.delete_media_items(socket.assigns.current_scope, selected_ids,
           delete_files: delete_files
         ) do
      {:ok, count, %DiskRemoval{} = removal} ->
        {kind, message} = DiskRemovalFlash.for_items(count, delete_files, removal)

        {:noreply,
         socket
         |> put_flash(kind, message)
         |> assign(:selection_mode, false)
         |> assign(:selected_ids, MapSet.new())
         |> assign(:show_delete_modal, false)
         |> assign(:delete_files, false)
         |> load_media_items()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Failed to delete items"))
         |> assign(:show_delete_modal, false)
         |> assign(:delete_files, false)}
    end
  end

  defp batch_edit_selected(socket, params) do
    selected_ids = MapSet.to_list(socket.assigns.selected_ids)

    # Build attrs map with only non-empty values
    attrs =
      %{}
      |> maybe_add_attr(:quality_profile_id, params["quality_profile_id"])
      |> maybe_add_attr(:monitored, params["monitored"])

    case Media.update_media_items_batch(socket.assigns.current_scope, selected_ids, attrs) do
      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           ngettext(
             "%{count} item updated successfully",
             "%{count} items updated successfully",
             count
           )
         )
         |> assign(:selection_mode, false)
         |> assign(:selected_ids, MapSet.new())
         |> assign(:show_batch_edit_modal, false)
         |> load_media_items()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Failed to update items"))
         |> assign(:show_batch_edit_modal, false)}
    end
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

        put_flash(socket, :error, gettext("Failed to queue searches"))
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

  # Selects everything the current filters match, including rows not rendered.
  defp select_all_visible(socket),
    do: assign(socket, :selected_ids, socket.assigns.all_visible_ids)

  defp apply_listing_params(%{redirected: redirected} = socket, _params, _force?)
       when not is_nil(redirected),
       do: socket

  defp apply_listing_params(socket, params, force?) do
    parsed = ListingParams.parse(params, library_choices(socket))
    current = Window.listing_params(socket.assigns)

    if force? or not ListingParams.same_listing?(parsed, current) do
      socket
      # Only an in-page jump scrolls; a mount or reconnect keeps the user's place.
      |> maybe_scroll_to_letter(
        not force? and parsed.letter != socket.assigns.letter and parsed.letter
      )
      # A letter jump moves through the same items, so a selection survives it.
      |> maybe_clear_selection(
        force? or
          not ListingParams.same_listing?(%{parsed | letter: nil}, %{current | letter: nil})
      )
      |> assign_listing_params(parsed)
      |> load_media_items_when_connected(parsed.shown, parsed.above)
    else
      socket
    end
  end

  defp maybe_clear_selection(socket, true), do: assign(socket, :selected_ids, MapSet.new())
  defp maybe_clear_selection(socket, false), do: socket

  defp maybe_scroll_to_letter(socket, nil_or_false) when nil_or_false in [nil, false], do: socket

  defp maybe_scroll_to_letter(socket, _letter),
    do: push_event(socket, "alpha_jump:scroll_top", %{})

  # The select is hidden below two options, where a chosen library could not
  # be cleared, so it is only honoured from two up.
  defp library_choices(%{assigns: %{library_options: [_, _ | _] = options}}),
    do: Enum.map(options, & &1.id)

  defp library_choices(_socket), do: []

  defp assign_listing_params(socket, %ListingParams{} = params) do
    socket
    |> assign(:search_query, params.search)
    |> assign(:filter_library, params.library)
    |> assign(:filter_progress, params.progress)
    |> assign(:filter_monitored, params.monitored)
    |> assign(:filter_quality, params.quality)
    |> assign(:sort_by, params.sort)
    |> assign(:letter, params.letter)
    |> assign(:filtered?, ListingParams.filtered?(params))
  end

  # Filter, search and sort changes replace the history entry rather than
  # adding one, so Back from a title lands on the list in its latest state.
  # They also drop the A-Z jump letter, so the new listing starts at the top.
  # They also save the page's sort and filters for the next visit.
  defp patch_listing(socket, %ListingParams{} = params, forget? \\ false) do
    params = %{params | shown: ListingParams.first_page(), above: 0, letter: nil}

    socket
    |> RememberedListing.remember(params, forget?)
    |> push_patch(
      to: ListingParams.path(socket.assigns.listing_base_path, params),
      replace: true
    )
  end

  # Records how much of the listing is loaded, in place, so Back and reloads
  # rebuild the same window. same_listing?/2 ignores the change, so the patch
  # does not reload anything.
  defp patch_window(socket) do
    push_patch(socket,
      to:
        ListingParams.path(
          socket.assigns.listing_base_path,
          Window.listing_params(socket.assigns)
        ),
      replace: true
    )
  end

  defp get_poster_url(media_item),
    do: MydiaWeb.Live.Helpers.MediaImages.poster_url(media_item)

  defp get_progress(%LibraryRow{progress: progress}), do: progress

  defp format_year(nil), do: gettext("N/A")
  defp format_year(year), do: year

  # Ranked by parsed height rather than lexically: comparing the raw strings
  # puts "720p" ahead of "2160p", and a show's episodes routinely mix
  # resolutions.
  defp get_quality_badge(%LibraryRow{resolutions: resolutions}) do
    Enum.max_by(resolutions, &DownloadService.parse_resolution_height/1, fn -> nil end)
  end

  defp total_file_size(%LibraryRow{total_size: total_size}), do: total_size

  defp maybe_add_attr(attrs, _key, nil), do: attrs
  defp maybe_add_attr(attrs, _key, ""), do: attrs
  defp maybe_add_attr(attrs, _key, "no_change"), do: attrs

  defp maybe_add_attr(attrs, key, value) do
    Map.put(attrs, key, value)
  end

  # Gates the grid card's whole :meta slot. Checked against the catalog keys
  # that render inside it (playback and quality live in poster_badges, in the
  # figure overlay, not here) so an all-off preference drops the wrapper
  # entirely instead of leaving `poster_card_body/1` with an empty div.
  @poster_meta_keys [:status, :category, :year, :episodes, :content_rating, :show_status]

  defp any_poster_meta_field?(poster_fields) do
    Enum.any?(@poster_meta_keys, &PosterFields.show?(poster_fields, &1))
  end

  defp get_media_item_status(%LibraryRow{status: status}), do: status

  defp media_status_color(status), do: AvailabilityStatus.color(status)

  defp media_status_icon(status), do: AvailabilityStatus.icon(status)

  defp media_status_label(status), do: MydiaWeb.StatusLabels.availability(status)
end
