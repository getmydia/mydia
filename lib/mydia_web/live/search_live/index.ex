defmodule MydiaWeb.SearchLive.Index do
  use MydiaWeb, :live_view
  alias Mydia.Indexers
  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.CategoryMapping
  alias Mydia.Metadata
  alias Mydia.Media.RemoteFilter
  alias Mydia.Media
  alias Mydia.Downloads
  alias Mydia.Settings
  alias Mydia.Media.AddDefaults
  alias MydiaWeb.Live.{Helpers.MediaAddHelpers, SearchResultRef}
  alias MydiaWeb.OperationErrors
  alias MydiaWeb.SearchLive.{ReleaseAdd, ResultType}

  import MydiaWeb.IndexerComponents
  import MydiaWeb.AddMediaComponents, only: [add_config_fields: 1]

  import MydiaWeb.SearchLive.QualityBadges, only: [get_quality_badges: 1]

  alias Mydia.Indexers.Structs.IndexerProgress

  require Logger

  # Library type options for the filter
  defp library_type_options do
    [
      {:all, gettext("All Types")},
      {:movies, gettext("Movies")},
      {:series, gettext("TV Series")}
    ]
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mydia.PubSub, "downloads")
    end

    # Load available indexers (both traditional and Cardigann)
    traditional_indexers =
      Settings.list_indexer_configs()
      |> Enum.filter(& &1.enabled)
      |> Enum.map(fn indexer ->
        %{id: indexer.id, name: indexer.name, type: indexer.type, source: :traditional}
      end)

    cardigann_indexers =
      if Indexers.CardigannFeatureFlags.enabled?() do
        Indexers.list_cardigann_definitions(enabled: true)
        |> Enum.map(fn def ->
          %{id: def.id, name: def.name, type: :cardigann, source: :cardigann}
        end)
      else
        []
      end

    available_indexers = traditional_indexers ++ cardigann_indexers

    # By default, select all enabled indexers
    selected_indexer_ids =
      available_indexers
      |> Enum.map(& &1.id)
      |> MapSet.new()

    {:ok,
     socket
     |> assign(:page_title, gettext("Search Media"))
     |> assign(:search_query, "")
     |> assign(:searching, false)
     |> assign(:min_seeders, 0)
     |> assign(:max_size_gb, nil)
     |> assign(:min_size_gb, nil)
     |> assign(:quality_filter, nil)
     |> assign(:library_type_filter, :all)
     |> assign(:sort_by, :quality)
     |> assign(:results_empty?, false)
     |> assign(:indexer_errors, [])
     |> assign(indexer_progress: %{}, cardigann_summary: nil)
     |> assign(:search_id, 0)
     |> assign(:show_disambiguation_modal, false)
     |> assign(:metadata_matches, [])
     |> assign(:metadata_media_type, nil)
     |> assign(:pending_parsed, nil)
     |> assign(:pending_release_title, nil)
     |> assign(:pending_search_result, nil)
     |> assign(:pending_media_type, nil)
     |> assign(:pending_add_defaults, nil)
     |> assign(:should_download_after_add, false)
     |> assign(:show_manual_search_modal, false)
     |> assign(:manual_search_query, "")
     |> assign(:failed_release_title, nil)
     |> assign(:selecting_match_id, nil)
     |> assign(:show_retry_modal, false)
     |> assign(:retry_error_message, nil)
     |> assign(:search_results_map, %{})
     |> assign(:raw_search_results_map, %{})
     |> assign(:result_types, %{})
     |> assign(:show_detail_modal, false)
     |> assign(:selected_result, nil)
     |> assign(:download_config, nil)
     |> assign(:quality_profiles, Settings.list_quality_profiles())
     |> assign(:downloading_urls, MapSet.new())
     |> assign(:available_indexers, available_indexers)
     |> assign(:selected_indexer_ids, selected_indexer_ids)
     |> stream_configure(:search_results, dom_id: &generate_result_id/1)
     |> stream(:search_results, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      case params do
        %{"q" => query} when is_binary(query) and query != "" ->
          start_search(socket, query)

        _ ->
          socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"search" => query}, socket) do
    query = String.trim(query)

    if query == "" do
      {:noreply,
       socket
       |> assign(:search_query, query)
       |> assign(:results_empty?, false)
       |> stream(:search_results, [], reset: true)}
    else
      {:noreply, push_patch(socket, to: ~p"/search?#{[q: query]}")}
    end
  end

  def handle_event("filter", params, socket) do
    # Parse filter params
    min_seeders =
      case params["min_seeders"] do
        "" -> 0
        val when is_binary(val) -> String.to_integer(val)
        _ -> 0
      end

    quality_filter =
      case params["quality"] do
        "" -> nil
        q when q in ["720p", "1080p", "2160p", "4k"] -> q
        _ -> nil
      end

    library_type_filter =
      case params["library_type"] do
        "" ->
          :all

        "all" ->
          :all

        type when type in ["movies", "series"] ->
          String.to_existing_atom(type)

        _ ->
          socket.assigns.library_type_filter
      end

    min_size_gb =
      case params["min_size"] do
        "" -> nil
        val when is_binary(val) -> parse_float(val)
        _ -> nil
      end

    max_size_gb =
      case params["max_size"] do
        "" -> nil
        val when is_binary(val) -> parse_float(val)
        _ -> nil
      end

    {:noreply,
     socket
     |> assign(:min_seeders, min_seeders)
     |> assign(:quality_filter, quality_filter)
     |> assign(:library_type_filter, library_type_filter)
     |> assign(:min_size_gb, min_size_gb)
     |> assign(:max_size_gb, max_size_gb)
     |> apply_filters()}
  end

  def handle_event("sort", %{"sort_by" => sort_by}, socket) do
    sort_by = String.to_existing_atom(sort_by)

    {:noreply,
     socket
     |> assign(:sort_by, sort_by)
     |> apply_sort()}
  end

  def handle_event("toggle_indexer", %{"id" => indexer_id}, socket) do
    selected_ids = socket.assigns.selected_indexer_ids

    selected_ids =
      if MapSet.member?(selected_ids, indexer_id) do
        MapSet.delete(selected_ids, indexer_id)
      else
        MapSet.put(selected_ids, indexer_id)
      end

    {:noreply, assign(socket, :selected_indexer_ids, selected_ids)}
  end

  def handle_event("select_all_indexers", _params, socket) do
    all_ids =
      socket.assigns.available_indexers
      |> Enum.map(& &1.id)
      |> MapSet.new()

    {:noreply, assign(socket, :selected_indexer_ids, all_ids)}
  end

  def handle_event("deselect_all_indexers", _params, socket) do
    {:noreply, assign(socket, :selected_indexer_ids, MapSet.new())}
  end

  def handle_event("select_metadata_match", %{"match_id" => match_id}, socket) do
    with_create_access(socket, fn ->
      # Find the selected match
      selected_match =
        Enum.find(socket.assigns.metadata_matches, fn m ->
          to_string(m.provider_id) == match_id
        end)

      if selected_match do
        # Fetch full metadata and create media item
        media_type = socket.assigns.metadata_media_type
        parsed = socket.assigns.pending_parsed
        defaults = socket.assigns.pending_add_defaults
        scope = socket.assigns.current_scope

        {:noreply,
         socket
         # Keep modal open but show loading state on selected match
         |> assign(:selecting_match_id, match_id)
         |> start_async(:finalize_add_to_library, fn ->
           config = Metadata.default_relay_config()

           case ReleaseAdd.fetch_full_metadata(config, selected_match, media_type) do
             {:ok, metadata} ->
               ReleaseAdd.create_media_item_from_metadata(scope, parsed, metadata,
                 defaults: defaults
               )

             error ->
               error
           end
         end)}
      else
        {:noreply, socket}
      end
    end)
  end

  def handle_event("close_disambiguation_modal", _params, socket) do
    {:noreply,
     socket
     |> cancel_async(:finalize_add_to_library)
     |> assign(:show_disambiguation_modal, false)
     |> assign(:metadata_matches, [])
     |> assign(:pending_parsed, nil)
     |> finish_pending()}
  end

  def handle_event("manual_search_submit", %{"search_query" => query}, socket) do
    with_create_access(socket, fn ->
      media_type = Map.get(socket.assigns, :manual_search_media_type, :movie)
      scope = socket.assigns.current_scope

      {:noreply,
       socket
       |> start_async(:manual_metadata_search, fn ->
         config = Metadata.default_relay_config()

         with {:ok, results} <- Metadata.search(config, query, media_type: media_type) do
           {:ok, RemoteFilter.filter(results, scope)}
         end
       end)}
    end)
  end

  def handle_event("close_manual_search_modal", _params, socket) do
    {:noreply,
     socket
     |> cancel_async(:finalize_manual_add)
     |> assign(:show_manual_search_modal, false)
     |> assign(:failed_release_title, nil)
     |> assign(:manual_search_query, "")
     |> finish_pending()}
  end

  def handle_event(
        "select_manual_match",
        %{"match_id" => match_id, "media_type" => media_type},
        socket
      ) do
    with_create_access(socket, fn ->
      # Find the selected match from manual search
      selected_match =
        Enum.find(socket.assigns.metadata_matches, fn m ->
          to_string(m.provider_id) == match_id
        end)

      if selected_match do
        media_type_atom = String.to_existing_atom(media_type)
        defaults = socket.assigns.pending_add_defaults
        scope = socket.assigns.current_scope

        {:noreply,
         socket
         # Keep modal open but show loading state on selected match
         |> assign(:selecting_match_id, match_id)
         |> start_async(:finalize_manual_add, fn ->
           config = Metadata.default_relay_config()

           case ReleaseAdd.fetch_full_metadata(config, selected_match, media_type_atom) do
             {:ok, metadata} ->
               # Create media item without parsed data (since parsing failed)
               # Episodes are automatically fetched for TV shows via create_media_item
               attr_opts = [user: scope.user] ++ if(defaults, do: [defaults: defaults], else: [])

               attrs =
                 Mydia.Media.AttrsFromMetadata.from_metadata(metadata, media_type_atom, attr_opts)

               case Media.create_media_item(scope, attrs) do
                 {:ok, item} -> {:ok, item, :created}
                 other -> other
               end

             error ->
               error
           end
         end)}
      else
        {:noreply, socket}
      end
    end)
  end

  def handle_event("retry_add_to_library", _params, socket) do
    with_create_access(socket, fn ->
      # Retry adding to library with the same parameters
      release_title = socket.assigns.pending_release_title
      media_type = socket.assigns.pending_media_type
      defaults = socket.assigns.pending_add_defaults

      if release_title && media_type do
        Logger.info("Retrying add to library for: #{release_title}")
        scope = socket.assigns.current_scope

        {:noreply,
         socket
         |> assign(:show_retry_modal, false)
         |> mark_downloading()
         |> start_async(:add_to_library, fn ->
           ReleaseAdd.add_release_to_library(scope, release_title, media_type, defaults)
         end)}
      else
        {:noreply,
         socket
         |> assign(:show_retry_modal, false)
         |> finish_pending()
         |> put_flash(:error, gettext("Cannot retry: missing release information"))}
      end
    end)
  end

  def handle_event("close_retry_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_retry_modal, false)
     |> assign(:retry_error_message, nil)
     |> finish_pending()}
  end

  # Always opens, even when the type is known: the destination library is a
  # choice the user makes here, and skipping the modal would make it for them
  # (#1104).
  def handle_event("show_download_modal", %{"ref" => ref}, socket) do
    case SearchResultRef.find(socket.assigns.search_results_map, ref) do
      nil ->
        {:noreply, socket}

      %SearchResult{} = result ->
        {kind, _source} = result_type(socket.assigns.result_types, result)

        {:noreply,
         socket
         |> assign(:show_detail_modal, false)
         |> assign(:selected_result, nil)
         |> assign(
           :download_config,
           build_download_config(socket, result, ResultType.media_type(kind))
         )}
    end
  end

  def handle_event("close_download_modal", _params, socket) do
    {:noreply, close_download_modal(socket)}
  end

  # A type switch resolves fresh defaults for the new type: the old type's
  # library id is not a candidate for the new one. Other field changes need no
  # server state; the form holds them until submit.
  def handle_event("download_config_change", params, socket) do
    with %{} = config <- socket.assigns.download_config,
         {:ok, media_type} <- parse_media_type(params["media_type"]),
         true <- media_type != config.media_type do
      {:noreply,
       assign(socket, :download_config, build_download_config(socket, config.result, media_type))}
    else
      _ -> {:noreply, socket}
    end
  end

  # The modal closes before the async add starts, so a follow-up modal
  # ("Multiple matches", manual search, retry) is never stacked under it
  # (#1104). The row spinner carries the in-flight state.
  def handle_event("confirm_download", params, socket) do
    user = socket.assigns.current_user

    with :ok <- MydiaWeb.Live.Authorization.authorize_create_media(socket),
         :ok <- ensure_no_add_pending(socket),
         %{result: %SearchResult{} = result} <- socket.assigns.download_config,
         {:ok, media_type} <- parse_media_type(params["media_type"]),
         {:ok, defaults} <-
           MediaAddHelpers.resolve_add_defaults(params["config"] || %{}, media_type, user) do
      defaults = %{defaults | search_on_add: false}
      scope = socket.assigns.current_scope

      {:noreply,
       socket
       |> close_download_modal()
       |> assign(:pending_release_title, result.title)
       |> assign(:pending_search_result, result)
       |> assign(:pending_media_type, media_type)
       |> assign(:pending_add_defaults, defaults)
       |> assign(:should_download_after_add, true)
       |> mark_downloading()
       |> start_async(:add_to_library, fn ->
         ReleaseAdd.add_release_to_library(scope, result.title, media_type, defaults)
       end)}
    else
      {:unauthorized, socket} ->
        {:noreply, socket}

      :add_pending ->
        {:noreply,
         socket
         |> close_download_modal()
         |> put_flash(
           :error,
           gettext("Another release is still being added. Try again when it finishes.")
         )}

      {:error, :unknown_library} ->
        {:noreply,
         socket
         |> close_download_modal()
         |> put_flash(:error, MediaAddHelpers.unknown_library_message())}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("show_detail", %{"ref" => ref}, socket) do
    # Rows send a SearchResultRef; the URL can carry a tracker passkey.
    selected_result = SearchResultRef.find(socket.assigns.search_results_map, ref)

    {:noreply,
     socket
     |> assign(:show_detail_modal, true)
     |> assign(:selected_result, selected_result)}
  end

  def handle_event("close_detail_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_detail_modal, false)
     |> assign(:selected_result, nil)}
  end

  def handle_event("retry_indexer", %{"id" => indexer_id}, socket),
    do: {:noreply, start_indexer_retry(socket, indexer_id, false)}

  # Retest asks Prowlarr to test the indexers it has paused for this config,
  # then re-runs this config's search through the same retry path, so newly
  # recovered indexers' results merge in exactly as a retry's do.
  # Authorized like the media page: it makes Mydia ask Prowlarr to test
  # indexers, which can escalate Prowlarr's backoff.
  def handle_event("retest_paused", %{"id" => indexer_id}, socket) do
    case MydiaWeb.Live.Authorization.authorize_manage_downloads(socket) do
      :ok -> {:noreply, start_indexer_retry(socket, indexer_id, true)}
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:download_updated, _download_id}, socket) do
    # Just trigger a re-render to update the downloads counter in the sidebar
    # The counter will be recalculated when the layout renders
    {:noreply, socket}
  end

  def handle_info({:trigger_download, search_result, title, opts}, socket) do
    # This will be called after adding to library if download was requested
    Logger.info("Initiating download for: #{title}")

    case Downloads.initiate_download(search_result, opts) do
      {:ok, download} ->
        Logger.info("Download initiated successfully: #{download.title}")

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("%{title} added to library and download started. View in Downloads queue.",
             title: title
           )
         )}

      {:error, :duplicate_download} ->
        Logger.info("Skipping download - already exists")

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("%{title} added to library. Download already in progress.", title: title)
         )}

      {:error, :already_have_files} ->
        Logger.info("Skipping download - media files already exist")

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("%{title} added to library. You already have these files.", title: title)
         )}

      {:error, :no_clients_configured} ->
        Logger.warning("Cannot initiate download - no download clients configured")

        {:noreply,
         socket
         |> put_flash(
           :warning,
           gettext(
             "%{title} added to library, but no download clients are configured. Please configure a download client in settings.",
             title: title
           )
         )}

      {:error, {:client_not_found, client_name}} ->
        Logger.error("Download client not found: #{client_name}")

        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("%{title} added to library, but download client '%{client}' not found.",
             title: title,
             client: client_name
           )
         )}

      {:error, {:client_error, error}} ->
        Logger.error("Download client error: #{inspect(error)}")

        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("%{title} added to library, but download failed: %{reason}",
             title: title,
             reason: format_client_error(error)
           )
         )}

      {:error, reason} ->
        Logger.error("Failed to initiate download: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("%{title} added to library, but download failed: %{reason}",
             title: title,
             reason: inspect(reason)
           )
         )}
    end
  end

  # Grab outcomes are broadcast on the "downloads" topic and handled by
  # MediaLive.Show, which owns the manual-search UI. Ignore them quietly here
  # so the catch-all below keeps meaning "genuinely unexpected message".
  def handle_info({:grab_completed, _payload}, socket), do: {:noreply, socket}
  def handle_info({:grab_failed, _payload}, socket), do: {:noreply, socket}
  def handle_info({:grab_duplicate, _payload}, socket), do: {:noreply, socket}

  def handle_info({:indexer_search_started, search_id, pending}, socket) do
    if search_id == socket.assigns.search_id do
      incoming = Map.new(pending, fn entry -> {entry.indexer_id, entry} end)

      # Merge rather than replace: a scoped retry's on_start message only
      # covers the indexer(s) actually being retried, so a full replace here
      # would wipe every OTHER indexer's chip (success counts, durations,
      # errors) out of indexer_progress, even though those indexers were
      # never re-searched and will never report in again this search. A
      # fresh search still resets indexer_progress to %{} before starting
      # (see start_search/2), so merge and replace are equivalent there;
      # this only changes behavior for the scoped-retry case.
      progress = Map.merge(socket.assigns.indexer_progress, incoming)
      {:noreply, assign(socket, :indexer_progress, progress)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:indexer_progress, search_id, %IndexerProgress{} = progress}, socket) do
    if search_id == socket.assigns.search_id do
      {:noreply, apply_indexer_progress(socket, progress)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:paused_retest, search_id, result}, socket) do
    if search_id == socket.assigns.search_id do
      {kind, message} = MydiaWeb.IndexerComponents.retest_flash(result)
      {:noreply, put_flash(socket, kind, message)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(msg, socket) do
    # Catch-all for unhandled messages to prevent crashes
    Logger.warning("Unhandled message in SearchLive.Index: #{inspect(msg)}")
    {:noreply, socket}
  end

  # Terminal handler for the full search. It deliberately does NOT touch the
  # displayed results.
  #
  # Every indexer's output already arrived through `on_indexer_result`:
  # Indexers.search_all/2 invokes it on the success branch, the error branch
  # and the exit/timeout branch alike, and start_async delivers this reply
  # from the same process that sent those progress messages, so all of them
  # have already been folded in by apply_indexer_progress/2 (which owns
  # search_results_map, raw_search_results_map, results_empty? and the
  # stream).
  #
  # `results` here is the aggregate of the FULL search only. Re-streaming it
  # with reset: true would silently delete anything a single-indexer retry
  # contributed, which is the ordinary case rather than an exotic race: the
  # Retry button appears as soon as one indexer errors, while slow indexers
  # are still pending, so a retry against a fast-failing host normally
  # settles before the slow ones finish.
  #
  # The zero-indexer case is why this clause still has to end the search:
  # search_all/2 returns early there, before `on_start`, so no progress
  # message ever arrives and nothing else can clear :searching.
  # results_empty? was set to true when the search started and nothing has
  # flipped it, so the "No Results Found" empty state renders correctly.
  @impl true
  def handle_async(:search, {:ok, {:ok, results, indexer_errors}}, socket) do
    Logger.info(
      "Search completed: query=\"#{socket.assigns.search_query}\", " <>
        "aggregate_results=#{length(results)}, " <>
        "displayed=#{map_size(socket.assigns.search_results_map)}, " <>
        "indexer_errors=#{length(indexer_errors)}"
    )

    {:noreply,
     socket
     |> assign(:searching, false)
     |> assign(:indexer_errors, indexer_errors)}
  end

  def handle_async(:search, {:ok, {:error, reason}}, socket) do
    Logger.error("Search failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:searching, false)
     |> put_flash(:error, gettext("Search failed: %{reason}", reason: inspect(reason)))}
  end

  def handle_async(:search, {:exit, reason}, socket) do
    Logger.error("Search task crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:searching, false)
     |> put_flash(:error, gettext("Search failed unexpectedly"))}
  end

  # Results already arrived through the :indexer_progress messages; the final
  # batched value carries only this one indexer and would clobber the rest, so
  # success is a no-op.
  def handle_async({:retry, _indexer_id}, {:ok, {:ok, _results, _indexer_errors}}, socket) do
    {:noreply, socket}
  end

  # Failure is NOT a no-op. handle_event("retry_indexer", ...) sets the chip to
  # :pending before starting the task; if that task dies or returns an error
  # before any progress message lands, nothing else ever clears :pending, so
  # the chip spins forever AND the Retry button disappears (it only renders for
  # :error/:timeout). Restoring an error state puts the indexer back into an
  # actionable state.
  def handle_async({:retry, indexer_id}, {:ok, {:error, reason}}, socket) do
    Logger.error("Indexer retry failed: #{inspect(reason)}")

    {:noreply,
     restore_retry_error(
       socket,
       indexer_id,
       gettext("Retry failed: %{reason}", reason: inspect(reason))
     )}
  end

  def handle_async({:retry, indexer_id}, {:exit, reason}, socket) do
    Logger.error("Indexer retry crashed: #{inspect(reason)}")
    {:noreply, restore_retry_error(socket, indexer_id, gettext("Retry failed unexpectedly"))}
  end

  def handle_async(
        :add_to_library,
        {:ok, {:ok, {:needs_disambiguation, parsed, matches, media_type}}},
        socket
      ) do
    Logger.info("Multiple metadata matches found, showing disambiguation modal")

    {:noreply,
     socket
     |> assign(:show_disambiguation_modal, true)
     |> assign(:metadata_matches, matches)
     |> assign(:metadata_media_type, media_type)
     |> assign(:pending_parsed, parsed)}
  end

  def handle_async(:add_to_library, {:ok, {:ok, media_item, status}}, socket) do
    Logger.info("Successfully added #{media_item.title} to library")

    # Stay on search page so user can download more items
    {:noreply, complete_add(socket, media_item, status)}
  end

  def handle_async(:add_to_library, {:ok, {:error, reason}}, socket) do
    Logger.error("Failed to add to library: #{inspect(reason)}")

    case reason do
      :parse_failed ->
        # Show manual search modal for parse failures
        release_title = socket.assigns.pending_release_title || gettext("Unknown")

        {:noreply,
         socket
         |> clear_spinner()
         |> assign(:show_manual_search_modal, true)
         |> assign(:manual_search_media_type, socket.assigns.pending_media_type || :movie)
         |> assign(:failed_release_title, release_title)
         |> assign(:manual_search_query, ReleaseAdd.extract_search_hint(release_title))}

      :no_metadata_match ->
        # Also show manual search modal for no matches
        release_title = socket.assigns.pending_release_title || gettext("Unknown")

        {:noreply,
         socket
         |> clear_spinner()
         |> assign(:show_manual_search_modal, true)
         |> assign(:manual_search_media_type, socket.assigns.pending_media_type || :movie)
         |> assign(:failed_release_title, release_title)
         |> assign(:manual_search_query, ReleaseAdd.extract_search_hint(release_title))
         |> put_flash(:error, gettext("Could not find matching media automatically"))}

      {:metadata_error, msg} ->
        # Show retry modal for metadata errors
        {:noreply,
         socket
         |> clear_spinner()
         |> assign(:show_retry_modal, true)
         |> assign(:retry_error_message, metadata_error_message(msg))}

      _ ->
        {:noreply,
         socket
         |> finish_pending()
         |> put_flash(:error, add_to_library_error_message(reason))}
    end
  end

  def handle_async(:add_to_library, {:exit, reason}, socket) do
    Logger.error("Add to library task crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> finish_pending()
     |> put_flash(:error, gettext("Failed to add to library unexpectedly"))}
  end

  def handle_async(:finalize_add_to_library, {:ok, {:ok, media_item, status}}, socket) do
    Logger.info("Successfully added #{media_item.title} to library after disambiguation")

    {:noreply,
     socket
     |> assign(:show_disambiguation_modal, false)
     |> assign(:selecting_match_id, nil)
     |> complete_add(media_item, status)}
  end

  def handle_async(:finalize_add_to_library, {:ok, {:error, reason}}, socket) do
    Logger.error("Failed to add to library after disambiguation: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:selecting_match_id, nil)
     |> clear_spinner()
     |> put_flash(:error, add_to_library_error_message(reason))}
  end

  # Closing the modal cancels the task; the pending state is already cleared.
  def handle_async(:finalize_add_to_library, {:exit, {:shutdown, :cancel}}, socket),
    do: {:noreply, socket}

  def handle_async(:finalize_add_to_library, {:exit, reason}, socket) do
    Logger.error("Finalize add to library task crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:selecting_match_id, nil)
     |> clear_spinner()
     |> put_flash(:error, gettext("Failed to add to library unexpectedly"))}
  end

  def handle_async(:manual_metadata_search, {:ok, {:ok, results}}, socket) do
    Logger.info("Manual metadata search returned #{length(results)} results")

    {:noreply,
     socket
     |> assign(:metadata_matches, results)}
  end

  def handle_async(:manual_metadata_search, {:ok, {:error, reason}}, socket) do
    Logger.error("Manual metadata search failed: #{inspect(reason)}")

    {:noreply,
     put_flash(socket, :error, gettext("Search failed: %{reason}", reason: inspect(reason)))}
  end

  # The manual path used to add the item and never grab the release.
  def handle_async(:finalize_manual_add, {:ok, {:ok, media_item, status}}, socket) do
    Logger.info("Successfully added #{media_item.title} to library via manual search")

    # Stay on search page so user can download more items
    {:noreply,
     socket
     |> assign(:show_manual_search_modal, false)
     |> assign(:selecting_match_id, nil)
     |> complete_add(media_item, status)}
  end

  def handle_async(:finalize_manual_add, {:ok, {:error, reason}}, socket) do
    Logger.error("Failed to add to library via manual search: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:selecting_match_id, nil)
     |> clear_spinner()
     |> put_flash(:error, add_to_library_error_message(reason))}
  end

  def handle_async(:finalize_manual_add, {:exit, {:shutdown, :cancel}}, socket),
    do: {:noreply, socket}

  def handle_async(:finalize_manual_add, {:exit, reason}, socket) do
    Logger.error("Finalize manual add task crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:selecting_match_id, nil)
     |> finish_pending()
     |> put_flash(:error, gettext("Failed to add to library unexpectedly"))}
  end

  ## Private Functions

  # Runs `fun` (which returns the `{:noreply, socket}` tuple) only for a user
  # who may create media. Every write path on this page goes through it or
  # through the same check in `confirm_download`.
  defp with_create_access(socket, fun) do
    case MydiaWeb.Live.Authorization.authorize_create_media(socket) do
      :ok -> fun.()
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  # One add runs at a time: a second `start_async` under the same name would
  # replace the first task and overwrite its pending state.
  defp ensure_no_add_pending(socket) do
    if socket.assigns.pending_search_result, do: :add_pending, else: :ok
  end

  # Shared by every `handle_async` clause above that falls back to showing
  # `reason` verbatim. `:restricted` gets Media's own generic wording instead
  # of `inspect/1`, which would otherwise print the bare atom in the flash.
  defp add_to_library_error_message(:restricted), do: OperationErrors.restricted_message()

  defp add_to_library_error_message({:metadata_error, reason}),
    do: metadata_error_message(reason)

  defp add_to_library_error_message(reason),
    do: gettext("Failed to add to library: %{reason}", reason: inspect(reason))

  defp metadata_error_message(:search_failed),
    do: gettext("Metadata provider error: Search failed")

  defp metadata_error_message(:fetch_failed),
    do: gettext("Metadata provider error: Failed to fetch details")

  defp metadata_error_message(msg),
    do: gettext("Metadata provider error: %{message}", message: msg)

  # Map.replace_lazy/3 for the same reason handle_event("retry_indexer", ...)
  # uses it: an id that is not already in the map must be a clean no-op, never
  # an insert of a half-built entry.
  defp restore_retry_error(socket, indexer_id, message) do
    indexer_progress =
      Map.replace_lazy(socket.assigns.indexer_progress, indexer_id, fn entry ->
        %{entry | status: :error, error: message, result_count: nil, duration_ms: nil}
      end)

    assign(socket, :indexer_progress, indexer_progress)
  end

  defp close_download_modal(socket), do: assign(socket, :download_config, nil)

  # Shared by every successful add: clear the row spinner and the pending
  # state, then hand off to the download when one was requested.
  defp complete_add(socket, media_item, status) do
    pending = socket.assigns.pending_search_result
    download? = socket.assigns.should_download_after_add && pending

    if download? do
      send(
        self(),
        {:trigger_download, pending, media_item.title,
         ReleaseAdd.download_opts(media_item.id, status, socket.assigns.pending_add_defaults)}
      )
    end

    socket = finish_pending(socket)

    if download?,
      do: socket,
      else:
        put_flash(
          socket,
          :info,
          gettext("%{title} added to library", title: media_item.title)
        )
  end

  defp finish_pending(socket) do
    socket
    |> clear_spinner()
    |> assign(:pending_search_result, nil)
    |> assign(:pending_media_type, nil)
    |> assign(:pending_add_defaults, nil)
    |> assign(:should_download_after_add, false)
  end

  defp mark_downloading(socket), do: set_spinner(socket, &MapSet.put/2)
  defp clear_spinner(socket), do: set_spinner(socket, &MapSet.delete/2)

  # The row spinner follows `downloading_urls`; re-inserting the pending
  # result makes the stream re-render its row.
  defp set_spinner(socket, update) do
    case socket.assigns.pending_search_result do
      %SearchResult{} = result ->
        socket
        |> assign(
          :downloading_urls,
          update.(socket.assigns.downloading_urls, result.download_url)
        )
        |> stream_insert(:search_results, result)

      _ ->
        socket
    end
  end

  @media_types [:movie, :tv_show]

  defp parse_media_type("movie"), do: {:ok, :movie}
  defp parse_media_type("tv_show"), do: {:ok, :tv_show}
  defp parse_media_type(_value), do: :error

  defp download_type_label(:movie), do: gettext("Movies")
  defp download_type_label(:tv_show), do: gettext("TV Series")

  # Only types with a library to land in are offered. With no detected type
  # and exactly one type available, that one is chosen for the user. A
  # detected type with no library is left unchosen instead: swapping it for
  # the other type would send a movie through TV matching.
  defp build_download_config(socket, %SearchResult{} = result, preferred) do
    available =
      for type <- @media_types, MediaAddHelpers.candidate_libraries(type) != [], do: type

    media_type =
      cond do
        preferred in available -> preferred
        is_nil(preferred) and match?([_only], available) -> hd(available)
        true -> nil
      end

    %{
      result: result,
      available_types: available,
      media_type: media_type,
      libraries: if(media_type, do: MediaAddHelpers.candidate_libraries(media_type), else: []),
      defaults: media_type && AddDefaults.resolve(socket.assigns.current_user, media_type)
    }
  end

  defp generate_result_id(%SearchResult{} = result) do
    # Generate a unique ID based on the download URL and indexer
    # Use :erlang.phash2 to create a stable integer ID from the URL
    hash = :erlang.phash2({result.download_url, result.indexer})
    "search-result-#{hash}"
  end

  defp start_search(socket, query) do
    min_seeders = socket.assigns.min_seeders
    indexer_ids = MapSet.to_list(socket.assigns.selected_indexer_ids)
    # self() inside start_async is the task, not the LiveView, so capture it here.
    lv = self()
    search_id = socket.assigns.search_id + 1

    socket
    |> assign(:search_query, query)
    |> assign(:searching, true)
    |> assign(:search_id, search_id)
    |> assign(:indexer_progress, %{})
    |> assign(:cardigann_summary, Indexers.CardigannSummary.build())
    |> assign(:indexer_errors, [])
    |> assign(:search_results_map, %{})
    |> assign(:raw_search_results_map, %{})
    |> assign(:result_types, %{})
    # TRUE, not false: the display set is genuinely empty until the first
    # indexer reports. The loading gate is `@searching && @results_empty?`
    # and the results gate is `!@results_empty?`, so starting at false
    # suppresses the spinner and renders the results card with a count of
    # zero ("0 results for Dune") for the whole search window. The "No
    # Results Found" empty state is gated on `!@searching`, so it stays
    # hidden until the search actually ends.
    |> assign(:results_empty?, true)
    |> stream(:search_results, [], reset: true)
    |> start_async(:search, fn ->
      Indexers.ManualSearch.run(query, min_seeders, lv, search_id, indexer_ids)
    end)
  end

  defp start_indexer_retry(socket, indexer_id, retest_paused?) do
    query = socket.assigns.search_query
    min_seeders = socket.assigns.min_seeders
    lv = self()
    search_id = socket.assigns.search_id

    # Map.replace_lazy/3 no-ops when indexer_id isn't a key in the map, rather
    # than inserting `indexer_id => nil` (as Map.update/4's default would),
    # which would otherwise flow a nil straight into the status chip
    # component. Not reachable through the shipped UI today (the Retry
    # button only renders for rows already present in the map), but an
    # unknown or forged id should be a clean no-op, not a crash landmine.
    indexer_progress =
      Map.replace_lazy(socket.assigns.indexer_progress, indexer_id, fn entry ->
        %{entry | status: :pending, error: nil, result_count: nil, duration_ms: nil, paused: []}
      end)

    socket
    |> assign(:indexer_progress, indexer_progress)
    # A distinct key so a retry never cancels an in-flight full search.
    |> start_async({:retry, indexer_id}, fn ->
      if retest_paused? do
        result = Indexers.retest_paused_prowlarr_indexers(indexer_id)
        send(lv, {:paused_retest, search_id, result})
      end

      Indexers.ManualSearch.run(query, min_seeders, lv, search_id, [indexer_id])
    end)
  end

  defp apply_filters(socket) do
    # Re-filter the current results without re-searching
    results = socket.assigns.search_results_map |> Map.values()
    filtered_results = filter_results(results, socket.assigns)
    sorted_results = sort_results(filtered_results, socket.assigns.sort_by)

    socket
    |> assign(:results_empty?, sorted_results == [])
    |> stream(:search_results, sorted_results, reset: true)
  end

  # Folds one indexer's results into the accumulated set and re-ranks the whole
  # thing, so the list stays correctly ordered as indexers report out of order.
  #
  # Two collections are kept deliberately, and must NOT be collapsed back into
  # one:
  #
  #   - raw_search_results_map: every release ever seen this search, keyed by
  #     download_url, UNTRUNCATED. This is what future progress messages fold
  #     new results onto.
  #   - search_results_map: the ranked-and-deduplicated (and therefore
  #     truncated-to-max_results) DISPLAY set, matching what handle_async
  #     assigns at the end of a search. apply_filters/1 re-filters straight
  #     from this map without deduplicating, so it must stay deduplicated.
  #
  # Plain truncation is NOT why the raw map exists: Indexers.rank_and_dedupe/3
  # scores each result independently of the rest of the pool, so an item's
  # rank can only stay the same or worsen as the pool grows. An item outside
  # round one's top max_results is outside the full-history top max_results
  # too, and folding onto a truncated base can never lose a genuine contender
  # to truncation alone.
  #
  # The real reason is DEDUPLICATION across rounds. An item can be evicted by
  # truncation while it was the sole member of its dedup group, having never
  # lost a dedup comparison. If a WEAKER duplicate of that same group arrives
  # in a later round, deduping against the truncated search_results_map would
  # see only the weak duplicate (the true winner already gone) and crown it
  # as the group's representative, showing the wrong release or dropping the
  # group when the true winner would have qualified. Re-ranking from the full
  # raw_search_results_map every round means deduplication always compares
  # every variant of a release ever seen, so the strongest one always wins.
  #
  # `results` is cleared from the stored progress struct: it can be large and
  # the releases already live in raw_search_results_map.
  defp apply_indexer_progress(socket, %IndexerProgress{} = progress) do
    indexer_progress =
      Map.put(socket.assigns.indexer_progress, progress.indexer_id, %{progress | results: []})

    raw_results =
      Enum.reduce(progress.results, socket.assigns.raw_search_results_map, fn result, acc ->
        Map.put(acc, result.download_url, result)
      end)

    ranked =
      raw_results
      |> Map.values()
      |> Indexers.rank_and_dedupe(socket.assigns.search_query,
        min_seeders: socket.assigns.min_seeders
      )

    results_map = Map.new(ranked, fn result -> {result.download_url, result} end)

    cached = socket.assigns.result_types

    result_types =
      Map.new(ranked, fn r ->
        {r.download_url, classify(cached, r)}
      end)

    sorted =
      ranked
      |> filter_results(socket.assigns, result_types)
      |> sort_results(socket.assigns.sort_by)

    socket
    |> assign(:indexer_progress, indexer_progress)
    |> assign(:raw_search_results_map, raw_results)
    |> assign(:search_results_map, results_map)
    |> assign(:result_types, result_types)
    |> assign(:results_empty?, sorted == [])
    |> stream(:search_results, sorted, reset: true)
  end

  defp apply_sort(socket) do
    # Re-sort the current results
    results = socket.assigns.search_results_map |> Map.values()
    sorted_results = sort_results(results, socket.assigns.sort_by)

    socket
    |> stream(:search_results, sorted_results, reset: true)
  end

  defp filter_results(results, assigns, result_types \\ nil) do
    result_types = result_types || assigns.result_types

    results
    |> filter_by_seeders(assigns.min_seeders)
    |> filter_by_quality(assigns.quality_filter)
    |> filter_by_library_type(assigns.library_type_filter, result_types)
    |> filter_by_size(assigns.min_size_gb, assigns.max_size_gb)
  end

  defp filter_by_seeders(results, min_seeders) when min_seeders > 0 do
    Enum.filter(results, fn result -> result.seeders >= min_seeders end)
  end

  defp filter_by_seeders(results, _), do: results

  defp filter_by_quality(results, nil), do: results

  defp filter_by_quality(results, quality_filter) do
    Enum.filter(results, fn result ->
      case result.quality do
        %{resolution: resolution} when not is_nil(resolution) ->
          # Normalize 2160p to 4k and vice versa
          normalized_resolution = normalize_resolution(resolution)
          normalized_filter = normalize_resolution(quality_filter)
          normalized_resolution == normalized_filter

        _ ->
          false
      end
    end)
  end

  defp filter_by_library_type(results, :all, _result_types), do: results

  # Classified by ResultType, so a release with no indexer category is kept
  # when its title parses as the requested type (#1104). Only releases that
  # cannot be classified at all drop out of a type filter.
  defp filter_by_library_type(results, library_type, result_types) do
    Enum.filter(results, fn result ->
      {kind, _source} = result_type(result_types, result)
      kind == library_type
    end)
  end

  defp filter_by_size(results, nil, nil), do: results

  defp filter_by_size(results, min_gb, max_gb) do
    Enum.filter(results, fn result ->
      size_gb = result.size / (1024 * 1024 * 1024)

      min_ok = if min_gb, do: size_gb >= min_gb, else: true
      max_ok = if max_gb, do: size_gb <= max_gb, else: true

      min_ok && max_ok
    end)
  end

  defp normalize_resolution("2160p"), do: "4k"
  defp normalize_resolution("4k"), do: "4k"
  defp normalize_resolution(res), do: String.downcase(res)

  defp sort_results(results, :quality) do
    # Sort by quality score (already done by search_all), then by seeders
    results
    |> Enum.sort_by(fn result -> {quality_score(result), result.seeders} end, :desc)
  end

  defp sort_results(results, :seeders) do
    Enum.sort_by(results, & &1.seeders, :desc)
  end

  defp sort_results(results, :size) do
    Enum.sort_by(results, & &1.size, :desc)
  end

  defp sort_results(results, :date) do
    Enum.sort_by(
      results,
      fn result ->
        case result.published_at do
          nil -> DateTime.from_unix!(0)
          dt -> dt
        end
      end,
      {:desc, DateTime}
    )
  end

  defp quality_score(%SearchResult{quality: nil}), do: 0

  defp quality_score(%SearchResult{quality: quality}) do
    alias Mydia.Indexers.QualityParser
    QualityParser.quality_score(quality)
  end

  defp parse_float(str) do
    case Float.parse(str) do
      {float, _} -> float
      :error -> nil
    end
  end

  # Helper functions for the template

  defp get_quality_badge(%SearchResult{} = result) do
    SearchResult.quality_description(result)
  end

  defp format_size(%SearchResult{} = result) do
    SearchResult.format_size(result)
  end

  defp health_score(%SearchResult{} = result) do
    SearchResult.health_score(result)
  end

  defp health_color(score) when score >= 0.7, do: "text-success"
  defp health_color(score) when score >= 0.4, do: "text-warning"
  defp health_color(_), do: "text-error"

  defp format_date(%DateTime{} = dt, display) do
    format(dt, :date, display)
  end

  # Indexer type helpers for the template
  defp indexer_type_badge_class(:prowlarr), do: "badge-primary"
  defp indexer_type_badge_class(:jackett), do: "badge-secondary"
  defp indexer_type_badge_class(:newznab), do: "badge-accent"
  defp indexer_type_badge_class(_), do: "badge-ghost"

  defp indexer_type_label(:prowlarr), do: "Prowlarr"
  defp indexer_type_label(:jackett), do: "Jackett"
  defp indexer_type_label(:newznab), do: "Newznab"
  defp indexer_type_label(:public), do: pgettext("indexer type", "Public")
  defp indexer_type_label(type), do: to_string(type)

  defp format_client_error(error) when is_binary(error), do: error
  defp format_client_error(error), do: inspect(error)

  # Helper to get library type label for display
  defp library_type_label(:movies), do: gettext("Movies")
  defp library_type_label(:series), do: gettext("TV Series")
  defp library_type_label(:unknown), do: gettext("Unknown")

  defp type_source_hint(:title), do: gettext("Guessed from release title")
  defp type_source_hint(:category), do: gettext("From indexer category")
  defp type_source_hint(:none), do: gettext("Type could not be detected")

  # Helper to get library type icon
  defp library_type_icon(:movies), do: "hero-film"
  defp library_type_icon(:series), do: "hero-tv"
  defp library_type_icon(:unknown), do: "hero-question-mark-circle"
  defp library_type_icon(_), do: "hero-question-mark-circle"

  # Reads the per-search cache, classifying on a miss so a result that reached
  # a modal by another path still gets a type.
  defp result_type(result_types, %SearchResult{} = result) do
    {_inputs, classification} = classify(result_types, result)
    classification
  end

  # Cache entries are `{inputs, {kind, source}}`. Two indexers can return the
  # same download_url with a different title or category, so an entry is reused
  # only while the inputs `ResultType.detect/1` reads are unchanged.
  defp classify(result_types, %SearchResult{} = result) do
    inputs = {result.title, result.category}

    case Map.get(result_types, result.download_url) do
      {^inputs, _classification} = entry -> entry
      _ -> {inputs, ResultType.detect(result)}
    end
  end

  # Badge color for library type
  defp library_type_badge_class(:movies), do: "badge-primary"
  defp library_type_badge_class(:series), do: "badge-secondary"
  defp library_type_badge_class(:unknown), do: "badge-neutral"
  defp library_type_badge_class(_), do: "badge-ghost"
end
