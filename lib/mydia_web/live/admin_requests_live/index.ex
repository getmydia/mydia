defmodule MydiaWeb.AdminRequestsLive.Index do
  use MydiaWeb, :live_view

  import MydiaWeb.MediaRequestComponents

  alias Mydia.MediaRequests
  alias MydiaWeb.Live.Helpers.MediaRequestHelpers
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Manage Requests")
     |> assign(:filter_status, "pending")
     |> assign(:show_approve_modal, false)
     |> assign(:show_reject_modal, false)
     |> assign(:selected_request, nil)
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
    {:noreply, push_patch(socket, to: ~p"/admin/requests?status=#{status}")}
  end

  def handle_event("open_approve_modal", %{"id" => id}, socket) do
    request = MediaRequests.get_request!(id, preload: [:requester, :approved_by, :media_item])

    {:noreply,
     socket
     |> close_details()
     |> assign(:show_approve_modal, true)
     |> assign(:selected_request, request)
     |> assign_approve_form()}
  end

  def handle_event("close_approve_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_approve_modal, false)
     |> assign(:selected_request, nil)}
  end

  def handle_event("open_reject_modal", %{"id" => id}, socket) do
    request = MediaRequests.get_request!(id, preload: [:requester, :approved_by, :media_item])

    {:noreply,
     socket
     |> close_details()
     |> assign(:show_reject_modal, true)
     |> assign(:selected_request, request)
     |> assign_reject_form()}
  end

  def handle_event("close_reject_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_reject_modal, false)
     |> assign(:selected_request, nil)}
  end

  def handle_event("validate_approve", %{"approve" => approve_params}, socket) do
    changeset = validate_approve(approve_params)

    {:noreply, assign(socket, :approve_form, to_form(changeset, as: :approve))}
  end

  def handle_event("submit_approve", %{"approve" => approve_params}, socket) do
    request = socket.assigns.selected_request

    attrs = %{
      approved_by_id: socket.assigns.current_user.id,
      admin_notes: approve_params["admin_notes"]
    }

    case MediaRequests.approve_request(request, attrs) do
      {:ok, %{request: _updated_request, media_item: media_item}} ->
        {:noreply,
         socket
         |> assign(:show_approve_modal, false)
         |> assign(:selected_request, nil)
         |> put_flash(
           :info,
           "Request approved! #{media_item.title} has been added to the library."
         )
         |> load_requests()}

      {:error, {:metadata, reason}} ->
        Logger.warning("Approval blocked by metadata failure: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:show_approve_modal, false)
         |> assign(:selected_request, nil)
         |> put_flash(
           :error,
           "Could not reach the metadata service, so the request was not approved. Please try again."
         )}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to approve request: #{inspect(changeset.errors)}")
         |> assign(:approve_form, to_form(changeset, as: :approve))}
    end
  end

  def handle_event("show_details", %{"id" => id}, socket) do
    request = Enum.find(socket.assigns.requests, &(&1.id == id))
    item = request && MediaRequestHelpers.to_search_result(request)

    if item do
      send(self(), {:fetch_request_metadata, request})

      {:noreply,
       socket
       |> assign(:detail_request, request)
       |> assign(:detail_item, item)
       |> assign(:detail_metadata, nil)
       |> assign(:detail_loading, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_details", _params, socket) do
    {:noreply, close_details(socket)}
  end

  def handle_event("validate_reject", %{"reject" => reject_params}, socket) do
    changeset = validate_reject(reject_params)

    {:noreply, assign(socket, :reject_form, to_form(changeset, as: :reject))}
  end

  def handle_event("submit_reject", %{"reject" => reject_params}, socket) do
    request = socket.assigns.selected_request

    attrs = %{
      approved_by_id: socket.assigns.current_user.id,
      rejection_reason: reject_params["rejection_reason"],
      admin_notes: reject_params["admin_notes"]
    }

    case MediaRequests.reject_request(request, attrs) do
      {:ok, _updated_request} ->
        {:noreply,
         socket
         |> assign(:show_reject_modal, false)
         |> assign(:selected_request, nil)
         |> put_flash(:info, "Request rejected successfully.")
         |> load_requests()}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to reject request: #{inspect(changeset.errors)}")
         |> assign(:reject_form, to_form(changeset, as: :reject))}
    end
  end

  @impl true
  def handle_info({:backfill_posters, requests}, socket) do
    MediaRequestHelpers.backfill_poster_paths(requests)

    # Re-read through load_requests/1 so the refreshed rows and the active
    # filter stay in agreement. Every id in `requests` was already added to
    # :poster_backfill_attempted before this message was sent (see
    # maybe_backfill_posters/2), so this cannot re-send for them even when the
    # fetch above left poster_path nil.
    {:noreply, load_requests(socket)}
  end

  @impl true
  def handle_info({:fetch_request_metadata, request}, socket) do
    # Drop a fetch the user has already navigated away from, so a slow relay
    # cannot repopulate a popup that was closed or replaced.
    if socket.assigns.detail_request && socket.assigns.detail_request.id == request.id do
      case MediaRequestHelpers.fetch_request_metadata(request) do
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

  ## Private Helpers

  defp apply_filters(socket, params) do
    status = params["status"] || "pending"

    socket
    |> assign(:filter_status, status)
    |> load_requests()
  end

  defp load_requests(socket) do
    opts = [preload: [:requester, :approved_by, :media_item]]

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
  #
  # Ids are marked attempted at send time, not after the fetch completes.
  # handle_info/2 re-reads through load_requests/1, and LiveView calls
  # handle_params/3 (which also reaches load_requests/1) immediately after
  # mount/3 on the first connected render, so this runs at least twice per
  # page view. needs_poster?/1 never goes false for a row whose fetch cannot
  # succeed (relay down, 404, or metadata with no poster), so marking on
  # completion would resend that row to self() forever for as long as the
  # socket stays connected. Marking at send time bounds every id to at most
  # one attempt per connected socket; a permanently-failing row is retried on
  # the next page visit, which starts with a fresh MapSet.
  defp maybe_backfill_posters(socket, requests) do
    attempted = socket.assigns.poster_backfill_attempted

    pending =
      Enum.filter(requests, fn request ->
        MediaRequestHelpers.needs_poster?(request) and request.id not in attempted
      end)

    if connected?(socket) and pending != [] do
      send(self(), {:backfill_posters, pending})

      pending_ids = MapSet.new(pending, & &1.id)
      assign(socket, :poster_backfill_attempted, MapSet.union(attempted, pending_ids))
    else
      socket
    end
  end

  defp close_details(socket) do
    socket
    |> assign(:detail_request, nil)
    |> assign(:detail_item, nil)
    |> assign(:detail_metadata, nil)
    |> assign(:detail_loading, false)
  end

  defp assign_approve_form(socket) do
    changeset =
      {%{},
       %{
         admin_notes: :string
       }}
      |> Ecto.Changeset.cast(
        %{
          admin_notes: ""
        },
        [:admin_notes]
      )

    assign(socket, :approve_form, to_form(changeset, as: :approve))
  end

  defp assign_reject_form(socket) do
    changeset =
      {%{},
       %{
         rejection_reason: :string,
         admin_notes: :string
       }}
      |> Ecto.Changeset.cast(
        %{
          rejection_reason: "",
          admin_notes: ""
        },
        [:rejection_reason, :admin_notes]
      )
      |> Ecto.Changeset.validate_required([:rejection_reason])

    assign(socket, :reject_form, to_form(changeset, as: :reject))
  end

  defp validate_approve(params) do
    types = %{
      admin_notes: :string
    }

    {%{}, types}
    |> Ecto.Changeset.cast(params, Map.keys(types))
  end

  defp validate_reject(params) do
    types = %{
      rejection_reason: :string,
      admin_notes: :string
    }

    {%{}, types}
    |> Ecto.Changeset.cast(params, Map.keys(types))
    |> Ecto.Changeset.validate_required([:rejection_reason])
  end
end
