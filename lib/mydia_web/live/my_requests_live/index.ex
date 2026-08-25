defmodule MydiaWeb.MyRequestsLive.Index do
  use MydiaWeb, :live_view

  import MydiaWeb.MediaRequestComponents

  alias Mydia.MediaRequests
  alias MydiaWeb.Live.Helpers.MediaRequestHelpers

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "My Requests")
     |> assign(:filter_status, "all")
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

  @impl true
  def handle_info({:backfill_posters, requests}, socket) do
    MediaRequestHelpers.backfill_poster_paths(requests)

    # Re-read through load_requests/1 so the refreshed rows and the active
    # filter stay in agreement. needs_poster?/1 is false for every row it just
    # filled, so this does not loop.
    {:noreply, load_requests(socket)}
  end

  ## Private Helpers

  defp apply_filters(socket, params) do
    status = params["status"] || "all"

    socket
    |> assign(:filter_status, status)
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

  # Sent to self rather than fetched here: a relay round trip inside mount/3 or
  # a handle_event would freeze the LiveView while its page is on screen.
  defp maybe_backfill_posters(socket, requests) do
    if connected?(socket) and Enum.any?(requests, &MediaRequestHelpers.needs_poster?/1) do
      send(self(), {:backfill_posters, requests})
    end

    socket
  end
end
