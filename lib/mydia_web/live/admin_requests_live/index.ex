defmodule MydiaWeb.AdminRequestsLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.MediaRequests
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

    assign(socket, :requests, requests)
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

  defp format_date(nil), do: "N/A"

  defp format_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y at %I:%M %p")
  end

  defp status_badge_class("pending"), do: "badge-warning"
  defp status_badge_class("approved"), do: "badge-success"
  defp status_badge_class("rejected"), do: "badge-error"
  defp status_badge_class(_), do: "badge-ghost"

  defp status_text("pending"), do: "Pending Review"
  defp status_text("approved"), do: "Approved"
  defp status_text("rejected"), do: "Rejected"
  defp status_text(_), do: "Unknown"
end
