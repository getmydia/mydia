defmodule MydiaWeb.MediaLive.Show.SearchEvents do
  @moduledoc false

  use Gettext, backend: MydiaWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, start_async: 3, stream: 4, stream_insert: 3]

  alias Mydia.Media
  alias Mydia.Downloads
  alias Mydia.Indexers
  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.Structs.SearchResultMetadata
  alias MydiaWeb.Live.Authorization
  alias MydiaWeb.Live.SearchResultRef
  alias MydiaWeb.MediaLive.Show.{ExistingFiles, TrackerLimitNote}

  import MydiaWeb.MediaLive.Show.SearchHelpers
  import MydiaWeb.MediaLive.Show.Helpers, only: [maybe_add_opt: 3]

  require Logger

  @doc """
  Assigns the initial manual-search state used by the results stream and rows.
  """
  def assign_manual_search_defaults(socket) do
    socket
    |> assign(:raw_search_results, [])
    # Untruncated, undeduplicated pool of every release seen so far in the
    # current manual search, keyed by {download_url, indexer}. Progress messages fold
    # onto this (never onto :raw_search_results, which is already truncated
    # and deduplicated) so a later, weaker duplicate can never crown itself
    # over a stronger release evicted by an earlier round's truncation. See
    # apply_indexer_progress/2 in SearchHelpers.
    |> assign(:indexer_raw_results, %{})
    # Per-row grab state (:downloading, :downloaded, :duplicate, :grab_failed)
    # keyed by download_url. The stream is rebuilt with reset: true on every
    # progress message, filter change and re-sort, and a reset drops anything
    # that only lived in the stream, so this is the assign those badges
    # actually survive in. See SearchHelpers.stream_prepared_results/2.
    |> assign(:result_states, %{})
    # Download id => the download_url keying that row in :result_states. Grab
    # events carry only the id (a URL can carry a tracker passkey), so this is
    # how a :grab_completed finds the row this dialog started.
    |> assign(:grab_rows, %{})
    # Releases that already failed for the searched target or are
    # blacklisted, keyed by download_url, plus every URL already looked up
    # (a release with no prior attempt is never a key in :prior_attempts).
    # Folded in under :result_states, so a live grab state wins.
    |> assign(:prior_attempts, %{})
    |> assign(:prior_attempts_checked, MapSet.new())
    # Downloads that would block any grab in the open manual search dialog.
    |> assign(:manual_search_blocking, [])
    # Trackers at their daily grab cap, refreshed with :manual_search_blocking;
    # see TrackerLimitNote.
    |> assign(:grab_caps, %{})
  end

  def manual_search(_params, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      media_item = socket.assigns.media_item

      search_query =
        case media_item.type do
          "movie" ->
            if media_item.year do
              "#{media_item.title} #{media_item.year}"
            else
              media_item.title
            end

          "tv_show" ->
            media_item.title
        end

      lv = self()
      search_id = socket.assigns.search_id + 1

      {:noreply,
       socket
       |> assign(:show_manual_search_modal, true)
       |> assign(:manual_search_query, search_query)
       |> assign(:manual_search_context, %{type: :media_item})
       |> assign_existing_files()
       |> assign_manual_search_blocking()
       |> assign(:searching, true)
       # TRUE, not false: the display set is genuinely empty until the first
       # indexer reports. The modal's loading gate is
       # `@searching && @results_empty?` and its results list is gated on
       # `!@results_empty?`, so starting at false suppresses the spinner and
       # renders an empty <ul> with no message for the whole search window.
       # The "No Results Found" state is gated on `!@searching`, so it stays
       # hidden until the search actually ends. The other two search entry
       # points below do the same for the same reason.
       |> assign(:results_empty?, true)
       |> assign(:download_error, nil)
       |> assign(:search_id, search_id)
       |> assign(:indexer_progress, %{})
       |> assign(:cardigann_summary, Indexers.CardigannSummary.build())
       |> assign(:indexer_raw_results, %{})
       |> assign(:indexer_errors, [])
       |> assign(:raw_search_results, [])
       |> assign(:result_states, %{})
       |> assign(:prior_attempts, %{})
       |> assign(:prior_attempts_checked, MapSet.new())
       |> stream(:search_results, [], reset: true)
       |> start_async(:search, fn ->
         perform_search(search_query, 0, lv, search_id)
       end)}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def auto_search_download(_params, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      media_item = socket.assigns.media_item

      case media_item.type do
        "movie" ->
          %{mode: "specific", media_item_id: media_item.id, bypass_delay: true}
          |> Mydia.Jobs.MovieSearch.new()
          |> Oban.insert()

          Logger.info("Queued auto search for movie",
            media_item_id: media_item.id,
            title: media_item.title
          )

          Process.send_after(self(), :auto_search_timeout, 30_000)

          {:noreply,
           socket
           |> assign(:auto_searching, true)
           |> put_flash(
             :info,
             gettext("Searching indexers for %{title}...", title: media_item.title)
           )}

        "tv_show" ->
          %{mode: "show", media_item_id: media_item.id, bypass_delay: true}
          |> Mydia.Jobs.TVShowSearch.new()
          |> Oban.insert()

          Logger.info("Queued auto search for TV show",
            media_item_id: media_item.id,
            title: media_item.title
          )

          Process.send_after(self(), :auto_search_timeout, 30_000)

          {:noreply,
           socket
           |> assign(:auto_searching, true)
           |> put_flash(
             :info,
             gettext("Searching for all missing episodes of %{title}...", title: media_item.title)
           )}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def search_episode(%{"episode-id" => episode_id}, socket) do
    episode = Media.get_episode!(socket.assigns.current_scope, episode_id, preload: [:media_item])
    media_item = episode.media_item

    search_query =
      "#{media_item.title} S#{String.pad_leading(to_string(episode.season_number), 2, "0")}E#{String.pad_leading(to_string(episode.episode_number), 2, "0")}"

    lv = self()
    search_id = socket.assigns.search_id + 1

    {:noreply,
     socket
     |> assign(:show_manual_search_modal, true)
     |> assign(:manual_search_query, search_query)
     |> assign(
       :manual_search_context,
       %{
         type: :episode,
         episode_id: episode_id,
         season_number: episode.season_number,
         episode_number: episode.episode_number
       }
     )
     |> assign_existing_files()
     |> assign_manual_search_blocking()
     |> assign(:searching, true)
     # true so the spinner shows until the first indexer reports; see
     # manual_search/2 above.
     |> assign(:results_empty?, true)
     |> assign(:download_error, nil)
     |> assign(:search_id, search_id)
     |> assign(:indexer_progress, %{})
     |> assign(:cardigann_summary, Indexers.CardigannSummary.build())
     |> assign(:indexer_raw_results, %{})
     |> assign(:indexer_errors, [])
     |> assign(:raw_search_results, [])
     |> assign(:result_states, %{})
     |> assign(:prior_attempts, %{})
     |> assign(:prior_attempts_checked, MapSet.new())
     |> stream(:search_results, [], reset: true)
     |> start_async(:search, fn ->
       perform_search(search_query, 0, lv, search_id)
     end)}
  end

  def manual_search_season(%{"season-number" => season_number_str}, socket) do
    media_item = socket.assigns.media_item
    season_num = String.to_integer(season_number_str)

    search_query =
      "#{media_item.title} S#{String.pad_leading(to_string(season_num), 2, "0")}"

    lv = self()
    search_id = socket.assigns.search_id + 1

    {:noreply,
     socket
     |> assign(:show_manual_search_modal, true)
     |> assign(:manual_search_query, search_query)
     |> assign(:manual_search_context, %{type: :season, season_number: season_num})
     |> assign_existing_files()
     |> assign_manual_search_blocking()
     |> assign(:searching, true)
     # true so the spinner shows until the first indexer reports; see
     # manual_search/2 above.
     |> assign(:results_empty?, true)
     |> assign(:download_error, nil)
     |> assign(:search_id, search_id)
     |> assign(:indexer_progress, %{})
     |> assign(:cardigann_summary, Indexers.CardigannSummary.build())
     |> assign(:indexer_raw_results, %{})
     |> assign(:indexer_errors, [])
     |> assign(:raw_search_results, [])
     |> assign(:result_states, %{})
     |> assign(:prior_attempts, %{})
     |> assign(:prior_attempts_checked, MapSet.new())
     |> stream(:search_results, [], reset: true)
     |> start_async(:search, fn ->
       perform_search(search_query, 0, lv, search_id)
     end)}
  end

  def auto_search_season(%{"season-number" => season_number_str}, socket) do
    media_item = socket.assigns.media_item
    season_num = String.to_integer(season_number_str)

    %{
      mode: "season",
      media_item_id: media_item.id,
      season_number: season_num,
      bypass_delay: true
    }
    |> Mydia.Jobs.TVShowSearch.new()
    |> Oban.insert()

    Logger.info("Queued auto search for season",
      media_item_id: media_item.id,
      season_number: season_num,
      title: media_item.title
    )

    Process.send_after(self(), {:auto_search_season_timeout, season_num}, 30_000)

    {:noreply,
     socket
     |> assign(:auto_searching_season, season_num)
     |> put_flash(
       :info,
       gettext("Searching for season %{season} (preferring season pack)...", season: season_num)
     )}
  end

  def auto_search_episode(%{"episode-id" => episode_id}, socket) do
    episode = Media.get_episode!(socket.assigns.current_scope, episode_id)

    %{mode: "specific", episode_id: episode_id, bypass_delay: true}
    |> Mydia.Jobs.TVShowSearch.new()
    |> Oban.insert()

    Logger.info("Queued auto search for episode",
      episode_id: episode_id,
      season_number: episode.season_number,
      episode_number: episode.episode_number
    )

    Process.send_after(self(), {:auto_search_episode_timeout, episode_id}, 30_000)

    {:noreply,
     socket
     |> assign(:auto_searching_episode, episode_id)
     |> put_flash(
       :info,
       gettext("Searching for S%{season}E%{episode}...",
         season: episode.season_number,
         episode: episode.episode_number
       )
     )}
  end

  def close_manual_search_modal(_params, socket) do
    {:noreply, reset_search_modal(socket)}
  end

  # Retries a single indexer under a distinct start_async key so it cannot
  # cancel an in-flight full search (LiveView only cancels a prior async when
  # the key matches) and reuses the current search_id so its progress
  # messages pass the stale-guard in handle_info({:indexer_progress, ...}).
  #
  # The retry is SCOPED to the one indexer via perform_search/5's indexer_ids
  # argument. Re-running every indexer would not just waste requests against
  # hosts that ban on rate: since handle_info({:indexer_search_started, ...})
  # merges rather than replaces, an unscoped retry's on_start carries a
  # :pending entry for EVERY indexer, so clicking Retry on one failed chip
  # would visibly restart all of them.
  #
  # Authorized exactly like the other three entry points that start an indexer
  # search (manual_search/2, auto_search_download/2, download_from_search/2):
  # Retry hits the same indexers with the same query, so it must sit behind
  # the same permission check rather than being a side door around it.
  #
  # With `retest_paused: true` it first asks Prowlarr to retest the indexers it
  # paused for this config; same authorization, since it also hits the indexers.
  def handle_retry_indexer(indexer_id, socket, opts \\ []) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      retest_paused? = Keyword.get(opts, :retest_paused, false)
      query = socket.assigns.manual_search_query
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

      {:noreply,
       socket
       |> assign(:indexer_progress, indexer_progress)
       |> start_async({:retry, indexer_id}, fn ->
         if retest_paused? do
           result = Indexers.retest_paused_prowlarr_indexers(indexer_id)
           send(lv, {:paused_retest, search_id, result})
         end

         # min_seeders is 0, as on every manual search: the slider filters
         # at display time, so the pool must keep low-seeder releases.
         perform_search(query, 0, lv, search_id, [indexer_id])
       end)}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  @doc "Flashes the outcome of a paused-indexer retest started by handle_retry_indexer/3."
  def handle_paused_retest(search_id, result, socket) do
    if search_id == socket.assigns.search_id do
      {kind, message} = MydiaWeb.IndexerComponents.retest_flash(result)
      {:noreply, Phoenix.LiveView.put_flash(socket, kind, message)}
    else
      {:noreply, socket}
    end
  end

  # Terminal handler for a single-indexer retry.
  #
  # The SUCCESS case is deliberately a no-op: every release the retry found
  # already arrived through `on_indexer_result` (see handle_search_async/2's
  # note above), and the batched aggregate carries ONLY the retried indexer,
  # so applying it would clobber every other indexer's contribution.
  #
  # The failure cases are not no-ops. handle_retry_indexer/2 sets the chip to
  # `:pending` before starting the task; if that task dies or returns an error
  # before any progress message lands, nothing else ever clears `:pending`, so
  # the chip spins forever AND the Retry button disappears (it only renders
  # for `:error`/`:timeout`). Restoring an error state puts the indexer back
  # into an actionable state.
  def handle_retry_async(_indexer_id, {:ok, {:ok, _results, _indexer_errors}}, socket) do
    {:noreply, socket}
  end

  def handle_retry_async(indexer_id, {:ok, {:error, reason}}, socket) do
    Logger.error("Indexer retry failed: #{inspect(reason)}")

    {:noreply,
     restore_retry_error(
       socket,
       indexer_id,
       gettext("Retry failed: %{reason}", reason: inspect(reason))
     )}
  end

  def handle_retry_async(indexer_id, {:exit, reason}, socket) do
    Logger.error("Indexer retry crashed: #{inspect(reason)}")
    {:noreply, restore_retry_error(socket, indexer_id, gettext("Retry failed unexpectedly"))}
  end

  # Map.replace_lazy/3 for the same reason handle_retry_indexer/2 uses it: an
  # id that is not already in the map must be a clean no-op, never an insert
  # of a half-built entry.
  defp restore_retry_error(socket, indexer_id, message) do
    indexer_progress =
      Map.replace_lazy(socket.assigns.indexer_progress, indexer_id, fn entry ->
        %{entry | status: :error, error: message, result_count: nil, duration_ms: nil}
      end)

    assign(socket, :indexer_progress, indexer_progress)
  end

  # Built once when the dialog opens: the files cannot change while it is up,
  # and recomputing in the template would reparse every filename on each
  # streamed indexer update.
  defp assign_existing_files(socket) do
    assign(
      socket,
      :manual_search_existing,
      ExistingFiles.summarize(socket.assigns.media_item, socket.assigns.manual_search_context)
    )
  end

  # The downloads that would make any grab in this dialog come back "Already
  # downloading", shown as a banner above the results. Database only: the
  # click-time check in Queue.Duplicates also verifies the rows against the
  # download client and stays authoritative, so a failed lookup just means no
  # banner. A no-op while the dialog is closed, since the grab PubSub handlers
  # below call it whether or not it is open.
  defp assign_manual_search_blocking(socket) do
    if socket.assigns.show_manual_search_modal do
      socket
      |> assign(:manual_search_blocking, load_blocking_downloads(socket.assigns))
      |> assign(:grab_caps, TrackerLimitNote.load_caps())
    else
      socket
    end
  end

  defp load_blocking_downloads(%{media_item: media_item, manual_search_context: context}) do
    Downloads.blocking_downloads(media_item, context || %{type: :media_item})
  rescue
    error ->
      Logger.warning("Blocking downloads lookup failed: #{Exception.message(error)}")
      []
  end

  defp reset_search_modal(socket) do
    socket
    |> assign(:show_manual_search_modal, false)
    |> assign(:manual_search_query, "")
    |> assign(:manual_search_context, nil)
    |> assign(:manual_search_existing, nil)
    |> assign(:searching, false)
    |> assign(:results_empty?, false)
    |> assign(:raw_search_results, [])
    |> assign(:indexer_errors, [])
    |> assign(:indexer_progress, %{})
    |> assign(:indexer_raw_results, %{})
    |> assign(:result_states, %{})
    |> assign(:grab_rows, %{})
    |> assign(:prior_attempts, %{})
    |> assign(:prior_attempts_checked, MapSet.new())
    |> assign(:manual_search_blocking, [])
    |> assign(:download_error, nil)
    |> assign(quality_filters: [], source_filters: [], codec_filters: [], indexer_filters: [])
    |> assign(:min_seeders, 0)
    |> assign(:result_count, 0)
    |> stream(:search_results, [], reset: true)
  end

  def toggle_close_after_grab(_params, socket) do
    new_value = not socket.assigns.close_after_grab

    preference = Mydia.Accounts.get_user_preference!(socket.assigns.current_user)

    case Mydia.Accounts.update_preference(preference, %{
           "close_manual_search_after_grab" => new_value
         }) do
      {:ok, _} ->
        {:noreply, assign(socket, :close_after_grab, new_value)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save preference"))}
    end
  end

  # The row sends a SearchResultRef, never the URL (it can carry a tracker
  # passkey), and the release is looked up among the results this dialog holds.
  def download_from_search(%{"ref" => ref}, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket),
         %SearchResult{} = result <- find_search_result(socket, ref) do
      grab_search_result(result, socket)
    else
      {:unauthorized, socket} ->
        {:noreply, socket}

      nil ->
        {:noreply,
         assign(
           socket,
           :download_error,
           gettext("That release is no longer in the results. Search again.")
         )}
    end
  end

  defp find_search_result(socket, ref) do
    SearchResultRef.find(Map.get(socket.assigns, :raw_search_results, []), ref) ||
      SearchResultRef.find(Map.get(socket.assigns, :indexer_raw_results, %{}), ref)
  end

  # Grabs the result as the indexer returned it, so the Download keeps its
  # protocol, guid and tracker terms. Only `metadata` is replaced, as before:
  # a season search tags the grab as that season's pack.
  defp grab_search_result(
         %SearchResult{download_url: download_url, title: title} = result,
         socket
       ) do
    media_item = socket.assigns.media_item

    {episode_id, metadata} =
      case socket.assigns.manual_search_context do
        %{type: :episode, episode_id: ep_id} ->
          {ep_id, nil}

        %{type: :season, season_number: season_num} ->
          # Tag the request as a season pack so duplicate detection and
          # category routing are scoped to this season rather than the whole
          # show. Without this, an active download for a *different* season
          # falsely reports :duplicate_download.
          {nil, %SearchResultMetadata{season_pack: true, season_number: season_num}}

        _ ->
          {nil, nil}
      end

    opts =
      [manual: true]
      |> maybe_add_opt(:media_item_id, media_item.id)
      |> maybe_add_opt(:episode_id, episode_id)

    case Downloads.grab_async(%{result | metadata: metadata}, opts) do
      {:ok, download} ->
        socket =
          socket
          |> assign(:download_error, nil)
          |> assign(:grab_rows, Map.put(socket.assigns.grab_rows, download.id, download_url))
          |> mark_result(download_url, %{
            downloading: true,
            downloaded: false,
            grab_failed: nil,
            duplicate: false
          })

        socket =
          if socket.assigns.close_after_grab do
            socket
            |> reset_search_modal()
            |> put_flash(
              :info,
              gettext("Grabbing \"%{title}\" — progress will appear on this page", title: title)
            )
          else
            socket
          end

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply,
         assign(
           socket,
           :download_error,
           gettext("Could not start download for \"%{title}\"", title: title)
         )}
    end
  end

  # Re-stream a single result row with extra fields merged in (e.g. `:downloading`,
  # `:downloaded`). Streams don't re-render existing items on parent assign changes,
  # so per-row state must be pushed via stream_insert.
  #
  # The same state is also recorded in `:result_states`, keyed by download_url.
  # The stream is rebuilt with `reset: true` on every progress message, filter
  # change and re-sort, and a reset drops anything that only ever lived in the
  # stream. `:result_states` is what SearchHelpers.stream_prepared_results/2
  # folds back in on each rebuild, so a badge survives the next indexer
  # reporting mid-search.
  defp mark_result(socket, download_url, extra) do
    states =
      Map.update(
        Map.get(socket.assigns, :result_states, %{}),
        download_url,
        extra,
        &Map.merge(&1, extra)
      )

    socket = assign(socket, :result_states, states)

    case find_prepared_result(socket, download_url) do
      nil ->
        socket

      item ->
        # Merge the ACCUMULATED state, not just this call's `extra`, so the row
        # rendered here matches exactly what a later stream rebuild produces.
        #
        # This stays Map.merge/2 rather than struct-update syntax
        # (`%{item | ...}`) or `struct!/2` on purpose. `states` is built from
        # partial maps contributed by four different call sites over the
        # lifetime of a grab (this module's download_from_search/2,
        # handle_grab_completed/2, handle_grab_failed/2,
        # handle_grab_duplicate/2), so its key set is only known at runtime,
        # not as compile-time literals struct-update syntax could check.
        # `struct!/2` would get the same "reject an unknown key" check, but
        # only by raising `KeyError` and crashing this LiveView for what is
        # purely a per-row badge, in exchange for a check that is already
        # satisfied: every caller above passes a literal subset of
        # SearchResult's four declared grab-state display fields.
        stream_insert(socket, :search_results, Map.merge(item, Map.fetch!(states, download_url)))
    end
  end

  # Applies :prior_attempts the same way SearchHelpers.stream_prepared_results/2
  # does, so the row mark_result/3 re-inserts carries the same annotation a
  # full rebuild would.
  defp find_prepared_result(socket, download_url) do
    raw_results = Map.get(socket.assigns, :raw_search_results, [])
    assigns = socket.assigns
    ranking_opts = build_manual_ranking_opts(assigns)

    raw_results
    |> filter_search_results(assigns)
    |> sort_search_results_with_opts(assigns.sort_by, ranking_opts)
    |> prepare_for_stream()
    |> Enum.find(&(&1.download_url == download_url))
    |> case do
      nil ->
        nil

      item ->
        item
        |> put_prior_attempt(Map.get(assigns, :prior_attempts, %{}))
        |> TrackerLimitNote.put_limit_reason(Map.get(assigns, :grab_caps, %{}))
    end
  end

  # handle_async dispatches

  # Terminal handler for the full search. It deliberately does NOT touch the
  # displayed results.
  #
  # Every indexer's output already arrived through `on_indexer_result`:
  # Indexers.search_all/2 invokes it on the success branch, the error branch
  # and the exit/timeout branch alike, and start_async delivers this reply
  # from the same process that sent those progress messages, so all of them
  # have already been folded in by SearchHelpers.apply_indexer_progress/2
  # (which owns :raw_search_results, :indexer_raw_results, :results_empty?
  # and the stream).
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
  # :results_empty? was set to true when the search started and nothing has
  # flipped it, so the "No Results Found" state renders correctly.
  def handle_search_async({:ok, {:ok, results, indexer_errors}}, socket) do
    Logger.info(
      "Search completed: query=\"#{socket.assigns.manual_search_query}\", " <>
        "aggregate_results=#{length(results)}, " <>
        "displayed=#{length(Map.get(socket.assigns, :raw_search_results, []))}, " <>
        "indexer_errors=#{length(indexer_errors)}"
    )

    {:noreply,
     socket
     |> assign(:searching, false)
     |> assign(:indexer_errors, indexer_errors)}
  end

  def handle_search_async({:ok, {:error, reason}}, socket) do
    Logger.error("Search failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:searching, false)
     |> put_flash(:error, gettext("Search failed: %{reason}", reason: inspect(reason)))}
  end

  def handle_search_async({:exit, reason}, socket) do
    Logger.error("Search task crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:searching, false)
     |> put_flash(:error, gettext("Search failed unexpectedly"))}
  end

  # Grab pipeline PubSub handlers (topic "downloads", broadcast by
  # Mydia.Downloads.Grabber). Row lookup is a no-op when the modal is closed.

  # Caps refresh first, so the re-streamed row shows a cap this grab reached.
  def handle_grab_completed(%{download_id: id}, socket) do
    {:noreply,
     socket
     |> assign_manual_search_blocking()
     |> mark_grab_row(id, %{downloading: false, downloaded: true})}
  end

  def handle_grab_failed(%{download_id: id, reason: reason}, socket) do
    {:noreply,
     socket
     |> assign_manual_search_blocking()
     |> mark_grab_row(id, %{downloading: false, grab_failed: reason})}
  end

  def handle_grab_duplicate(%{download_id: id}, socket) do
    {:noreply,
     socket
     |> assign_manual_search_blocking()
     |> mark_grab_row(id, %{downloading: false, duplicate: true})}
  end

  # A grab another page started has no row here.
  defp mark_grab_row(socket, download_id, extra) do
    case Map.get(Map.get(socket.assigns, :grab_rows, %{}), download_id) do
      nil -> socket
      download_url -> mark_result(socket, download_url, extra)
    end
  end
end
