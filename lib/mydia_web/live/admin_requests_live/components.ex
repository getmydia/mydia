defmodule MydiaWeb.AdminRequestsLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  import MydiaWeb.MediaRequestComponents,
    only: [format_date: 1, status_badge_class: 1, status_text: 1]

  import MydiaWeb.AddMediaComponents, only: [add_config_fields: 1]

  alias Mydia.Media.MediaRequest
  alias Mydia.Metadata.ImageUrl

  @placeholder_poster "/images/no-poster.svg"

  attr :requests, :list, required: true
  attr :filter_status, :string, required: true

  def requests_tab(assigns) do
    ~H"""
    <div class="p-4 sm:p-6 space-y-4">
      <.segmented_control
        id="requests-status-filter"
        value={@filter_status}
        event="filter_requests"
        param="status"
        label="Filter requests by status"
      >
        <:option value="pending" label="Pending" />
        <:option value="all" label="All" />
        <:option value="approved" label="Approved" />
        <:option value="rejected" label="Rejected" />
      </.segmented_control>

      <.admin_list id="requests" items={@requests}>
        <:row :let={request}>
          <.request_row request={request} />
        </:row>
        <:empty>
          <%= if @filter_status == "pending" do %>
            No pending requests at this time. Great job keeping up!
          <% else %>
            No {status_text(@filter_status)} requests found.
          <% end %>
        </:empty>
      </.admin_list>
    </div>
    """
  end

  attr :request, MediaRequest, required: true

  defp request_row(assigns) do
    assigns =
      assigns
      |> assign(:detailable, MediaRequest.detailable?(assigns.request))
      |> assign(:poster_src, poster_src(assigns.request))

    ~H"""
    <.admin_row id={"request-#{@request.id}"}>
      <:title>
        <%= if @detailable do %>
          <button
            type="button"
            phx-click="show_request_details"
            phx-value-id={@request.id}
            aria-label={"View details for #{@request.title}"}
            class="shrink-0 w-10 rounded overflow-hidden transition hover:opacity-80 focus:outline-none focus:ring-2 focus:ring-primary"
          >
            <img
              src={@poster_src}
              alt=""
              loading="lazy"
              class="w-full aspect-[2/3] object-cover bg-base-300"
            />
          </button>
          <button
            type="button"
            phx-click="show_request_details"
            phx-value-id={@request.id}
            class="link link-hover text-left"
          >
            {@request.title}
          </button>
        <% else %>
          <div class="shrink-0 w-10 rounded overflow-hidden">
            <img
              src={@poster_src}
              alt=""
              loading="lazy"
              class="w-full aspect-[2/3] object-cover bg-base-300"
            />
          </div>
          <span>{@request.title}</span>
        <% end %>
        <span :if={@request.year} class="font-normal text-base-content/60">({@request.year})</span>
      </:title>

      <:descriptor>
        Requested by {@request.requester.email} on {format_date(@request.inserted_at)}
      </:descriptor>

      <:details>
        <.request_outcome request={@request} />
      </:details>

      <:badges>
        <span class={["badge badge-sm badge-outline", status_badge_class(@request.status)]}>
          {status_text(@request.status)}
        </span>
        <span class="badge badge-sm badge-outline">{media_type_text(@request.media_type)}</span>
        <span :if={@request.tvdb_id} class="badge badge-sm badge-outline">
          TVDB: {@request.tvdb_id}
        </span>
        <span :if={@request.tmdb_id} class="badge badge-sm badge-outline">
          TMDB: {@request.tmdb_id}
        </span>
      </:badges>

      <:actions>
        <.row_actions>
          <.row_action
            :if={@detailable}
            icon="hero-eye"
            title="Details"
            phx-click="show_request_details"
            phx-value-id={@request.id}
          />
          <.link
            :if={@request.status == "approved" and @request.media_item}
            navigate={~p"/media/#{@request.media_item.id}"}
            class="btn btn-sm btn-ghost join-item"
            title="View in Library"
            aria-label="View in Library"
          >
            <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" />
          </.link>
          <.row_action
            :if={@request.status == "pending"}
            icon="hero-check"
            title="Approve"
            phx-click="open_approve_modal"
            phx-value-id={@request.id}
          />
          <.row_action
            :if={@request.status == "pending"}
            icon="hero-x-mark"
            title="Reject"
            destructive
            phx-click="open_reject_modal"
            phx-value-id={@request.id}
          />
        </.row_actions>
      </:actions>
    </.admin_row>
    """
  end

  attr :request, MediaRequest, required: true

  defp request_outcome(assigns) do
    ~H"""
    <div :if={@request.status == "approved"} class="flex items-start gap-2 text-success">
      <.icon name="hero-check-circle" class="w-4 h-4 mt-0.5" />
      <div>
        <div>
          <%= if @request.approved_by do %>
            Approved by {@request.approved_by.email} on {format_date(@request.approved_at)}
          <% else %>
            Approved automatically on {format_date(@request.approved_at)}
          <% end %>
        </div>
        <div :if={@request.admin_notes} class="text-xs mt-1">
          Admin notes: {@request.admin_notes}
        </div>
      </div>
    </div>
    <div :if={@request.status == "rejected"} class="flex items-start gap-2 text-error">
      <.icon name="hero-x-circle" class="w-4 h-4 mt-0.5" />
      <div>
        <div>
          Rejected by {@request.approved_by.email} on {format_date(@request.rejected_at)}
        </div>
        <div :if={@request.rejection_reason} class="text-xs mt-1">
          Reason: {@request.rejection_reason}
        </div>
        <div :if={@request.admin_notes} class="text-xs mt-1">
          Admin notes: {@request.admin_notes}
        </div>
      </div>
    </div>
    """
  end

  attr :detail_request, :any, default: nil

  @doc "The header action buttons of the request detail popup."
  def detail_actions(assigns) do
    ~H"""
    <button class="btn btn-ghost" phx-click="close_request_details_modal">Close</button>
    <.link
      :if={@detail_request && @detail_request.media_item}
      navigate={~p"/media/#{@detail_request.media_item.id}"}
      class="btn btn-primary"
    >
      <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" /> View in Library
    </.link>
    <%= if @detail_request && @detail_request.status == "pending" do %>
      <button class="btn btn-error" phx-click="open_reject_modal" phx-value-id={@detail_request.id}>
        <.icon name="hero-x-mark" class="w-4 h-4" /> Reject
      </button>
      <button
        class="btn btn-success"
        phx-click="open_approve_modal"
        phx-value-id={@detail_request.id}
      >
        <.icon name="hero-check" class="w-4 h-4" /> Approve
      </button>
    <% end %>
    """
  end

  attr :selected_request, MediaRequest, required: true
  attr :approve_form, :any, required: true
  attr :approve_config, :map, default: nil
  attr :quality_profiles, :list, default: []

  def approve_request_modal(assigns) do
    ~H"""
    <.admin_modal
      id="approve-request-modal"
      icon="hero-check-circle"
      title="Approve Request"
      on_close="close_approve_modal"
    >
      <div class="alert alert-success mb-4">
        <.icon name="hero-information-circle" class="w-5 h-5" />
        <div>
          <p class="font-semibold">{@selected_request.title}</p>
          <p class="text-sm">This will create the media item in your library.</p>
        </div>
      </div>
      <.form
        for={@approve_form}
        phx-change="validate_approve"
        phx-submit="submit_approve"
        id="approve-form"
      >
        <.add_config_fields
          :if={@approve_config}
          config={@approve_config}
          quality_profiles={@quality_profiles}
        />
        <div class="form-control mb-4">
          <label class="label">
            <span class="label-text font-semibold">Admin Notes (Optional)</span>
          </label>
          <textarea
            name="approve[admin_notes]"
            class="textarea textarea-bordered h-24"
            placeholder="Add any notes about this approval..."
          >{@approve_form[:admin_notes].value}</textarea>
        </div>
        <.admin_modal_actions>
          <button type="button" class="btn btn-ghost" phx-click="close_approve_modal">
            Cancel
          </button>
          <button
            type="submit"
            class="btn btn-success"
            disabled={@approve_config && @approve_config.libraries == []}
          >
            <.icon name="hero-check" class="w-5 h-5" /> Approve & Add to Library
          </button>
        </.admin_modal_actions>
      </.form>
    </.admin_modal>
    """
  end

  attr :selected_request, MediaRequest, required: true
  attr :reject_form, :any, required: true

  def reject_request_modal(assigns) do
    ~H"""
    <.admin_modal
      id="reject-request-modal"
      icon="hero-x-circle"
      title="Reject Request"
      on_close="close_reject_modal"
    >
      <div class="alert alert-error mb-4">
        <.icon name="hero-information-circle" class="w-5 h-5" />
        <div>
          <p class="font-semibold">{@selected_request.title}</p>
          <p class="text-sm">Please provide a reason for rejecting this request.</p>
        </div>
      </div>
      <.form
        for={@reject_form}
        phx-change="validate_reject"
        phx-submit="submit_reject"
        id="reject-form"
      >
        <div class="form-control mb-4">
          <label class="label">
            <span class="label-text font-semibold">Rejection Reason</span>
            <span class="label-text-alt text-error">*</span>
          </label>
          <textarea
            name="reject[rejection_reason]"
            class="textarea textarea-bordered h-24"
            placeholder="Explain why this request is being rejected..."
            required
          >{@reject_form[:rejection_reason].value}</textarea>
          <%= if @reject_form[:rejection_reason].errors != [] do %>
            <label class="label">
              <span class="label-text-alt text-error">
                {Enum.map_join(@reject_form[:rejection_reason].errors, ", ", fn {msg, _} -> msg end)}
              </span>
            </label>
          <% end %>
        </div>
        <div class="form-control mb-4">
          <label class="label">
            <span class="label-text font-semibold">Admin Notes (Optional)</span>
          </label>
          <textarea
            name="reject[admin_notes]"
            class="textarea textarea-bordered h-20"
            placeholder="Add any additional notes..."
          >{@reject_form[:admin_notes].value}</textarea>
        </div>
        <.admin_modal_actions>
          <button type="button" class="btn btn-ghost" phx-click="close_reject_modal">
            Cancel
          </button>
          <button type="submit" class="btn btn-error">
            <.icon name="hero-x-mark" class="w-5 h-5" /> Reject Request
          </button>
        </.admin_modal_actions>
      </.form>
    </.admin_modal>
    """
  end

  defp media_type_text(media_type) do
    media_type
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp poster_src(%MediaRequest{poster_path: nil}), do: @placeholder_poster
  defp poster_src(%MediaRequest{poster_path: path}), do: ImageUrl.poster_url(path, "w185")
end
