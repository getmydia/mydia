defmodule MydiaWeb.MyRequestsLive.Index do
  use MydiaWeb, :live_view

  import MydiaWeb.MediaRequestComponents

  alias Mydia.MediaRequests
  alias MydiaWeb.Live.Helpers.MediaRequestHelpers
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "My Requests")
     |> assign(:filter_status, "all")
     |> assign(:poster_backfill_attempted, MapSet.new())
     |> assign(:detail_request, nil)
     |> assign(:detail_item, nil)
     |> assign(:detail_metadata, nil)
     |> assign(:detail_loading, false)
     |> load_requests()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_filters(socket, params)}
  end

  ## Event Handlers

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    {:noreply, push_patch(socket, to: ~p"/requests?status=#{status}")}
  end

  def handle_event("show_details", %{"id" => id}, socket) do
    request = Enum.find(socket.assigns.requests, &(&1.id == id))
    item = request && MediaRequestHelpers.to_search_result(request)

    if item do
      {:noreply,
       socket
       |> assign(:detail_request, request)
       |> assign(:detail_item, item)
       |> assign(:detail_metadata, nil)
       |> assign(:detail_loading, true)
       |> fetch_request_metadata_async(request)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_details", _params, socket) do
    {:noreply, close_details(socket)}
  end

  @impl true
  def handle_async(:backfill_posters, {:ok, :ok}, socket) do
    # Re-read through load_requests/1 so the refreshed rows and the active
    # filter stay in agreement. Every id in the batch was already added to
    # :poster_backfill_attempted before start_async was called (see
    # maybe_backfill_posters/2), so this cannot re-trigger a backfill for them
    # even when the fetch above left poster_path nil.
    {:noreply, load_requests(socket)}
  end

  def handle_async(:backfill_posters, {:exit, reason}, socket) do
    Logger.warning("Poster backfill crashed: #{inspect(reason)}")
    {:noreply, load_requests(socket)}
  end

  def handle_async(:fetch_request_metadata, {:ok, {request_id, result}}, socket) do
    # Drop a fetch the user has already navigated away from, so a slow relay
    # cannot repopulate a popup that was closed or switched away from.
    # Comparing by id here (rather than relying only on start_async's
    # same-key replacement) also covers the popup being closed outright:
    # close_details/1 does not start a new task under this key, so the
    # in-flight one's result would otherwise still land here.
    if socket.assigns.detail_request && socket.assigns.detail_request.id == request_id do
      case result do
        {:ok, metadata} ->
          {:noreply,
           socket
           |> assign(:detail_metadata, metadata)
           |> assign(:detail_loading, false)}

        {:error, _reason} ->
          {:noreply, assign(socket, :detail_loading, false)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_async(:fetch_request_metadata, {:exit, reason}, socket) do
    Logger.warning("Request metadata fetch crashed: #{inspect(reason)}")
    {:noreply, assign(socket, :detail_loading, false)}
  end

  ## Private Helpers

  defp apply_filters(socket, params) do
    status = params["status"] || "all"

    socket
    |> assign(:filter_status, status)
    |> close_details()
    |> load_requests()
  end

  defp load_requests(socket) do
    user_id = socket.assigns.current_user.id

    opts = [
      requester_id: user_id,
      preload: [:requester, :approved_by, :media_item]
    ]

    opts =
      case socket.assigns.filter_status do
        "all" -> opts
        status -> Keyword.put(opts, :status, status)
      end

    requests = MediaRequests.list_requests(opts)

    socket
    |> assign(:requests, requests)
    |> maybe_backfill_posters(requests)
  end

  # Runs through start_async rather than inline: backfill_poster_paths/1 makes
  # a relay round trip per row, and doing that in mount/3, a handle_event, or
  # a handle_info would block the LiveView process while its page is already
  # on screen. Deferring only to handle_info (as this used to) merely lets the
  # first render paint -- the process is still blocked for every event
  # afterward (Close) while the batch runs, so start_async is what actually
  # keeps the page responsive.
  #
  # Ids are marked attempted at send time, not after the fetch completes.
  # handle_async/3 re-reads through load_requests/1, and LiveView calls
  # handle_params/3 (which also reaches load_requests/1) immediately after
  # mount/3 on the first connected render, so this runs at least twice per
  # page view. needs_poster?/1 never goes false for a row whose fetch cannot
  # succeed (relay down, 404, or metadata with no poster), so marking on
  # completion would resend that row forever for as long as the socket stays
  # connected. Marking at send time bounds every id to at most one attempt per
  # connected socket; a permanently-failing row is retried on the next page
  # visit, which starts with a fresh MapSet.
  defp maybe_backfill_posters(socket, requests) do
    attempted = socket.assigns.poster_backfill_attempted

    pending =
      Enum.filter(requests, fn request ->
        MediaRequestHelpers.needs_poster?(request) and request.id not in attempted
      end)

    if connected?(socket) and pending != [] do
      pending_ids = MapSet.new(pending, & &1.id)

      socket
      |> assign(:poster_backfill_attempted, MapSet.union(attempted, pending_ids))
      |> start_async(:backfill_posters, fn ->
        MediaRequestHelpers.backfill_poster_paths(pending)
      end)
    else
      socket
    end
  end

  # Runs through start_async rather than inline: fetch_request_metadata/1
  # makes a relay round trip (TMDB via MediaAddHelpers.fetch_detail_metadata/2,
  # or TVDB via Metadata.fetch_by_id/3), and doing that in the handle_event
  # would block the LiveView process while the popup is already on screen --
  # close_details would queue behind the fetch and the modal would look
  # frozen.
  defp fetch_request_metadata_async(socket, request) do
    start_async(socket, :fetch_request_metadata, fn ->
      {request.id, MediaRequestHelpers.fetch_request_metadata(request)}
    end)
  end

  defp close_details(socket) do
    socket
    |> assign(:detail_request, nil)
    |> assign(:detail_item, nil)
    |> assign(:detail_metadata, nil)
    |> assign(:detail_loading, false)
  end
end
