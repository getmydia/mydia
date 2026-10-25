defmodule MydiaWeb.AdminRequestsLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  import MydiaWeb.MediaRequestComponents,
    only: [
      format_date: 2,
      media_type_text: 1,
      poster_src: 1,
      status_badge_class: 1,
      status_text: 1
    ]

  import MydiaWeb.AddMediaComponents, only: [add_config_fields: 1]

  alias Mydia.Media.MediaRequest

  attr :requests, :list, required: true
  attr :filter_status, :string, required: true
  attr :display, Mydia.TimeDisplay, required: true

  def requests_tab(assigns) do
    ~H"""
    <.segmented_control
      id="requests-status-filter"
      value={@filter_status}
      event="filter_requests"
      param="status"
      label={gettext("Filter requests by status")}
    >
      <:option value="pending" label={pgettext("request status", "Pending")} />
      <:option value="all" label={pgettext("selection", "All")} />
      <:option value="approved" label={pgettext("request status", "Approved")} />
      <:option value="rejected" label={pgettext("request status", "Rejected")} />
    </.segmented_control>

    <.admin_list id="requests" items={@requests}>
      <:row :let={request}>
        <.request_row request={request} display={@display} />
      </:row>
      <:empty>
        <%= if @filter_status == "pending" do %>
          {gettext("No pending requests at this time. Great job keeping up!")}
        <% else %>
          {empty_text(@filter_status)}
        <% end %>
      </:empty>
    </.admin_list>
    """
  end

  defp empty_text("approved"), do: gettext("No Approved requests found.")
  defp empty_text("rejected"), do: gettext("No Rejected requests found.")
  defp empty_text(_), do: gettext("No requests found.")

  attr :request, MediaRequest, required: true
  attr :display, Mydia.TimeDisplay, required: true

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
            aria-label={gettext("View details for %{title}", title: @request.title)}
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
        {gettext("Requested by %{email} on %{date}",
          email: @request.requester.email,
          date: format_date(@request.inserted_at, @display)
        )}
      </:descriptor>

      <:details>
        <.request_outcome request={@request} display={@display} />
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
            title={gettext("Details")}
            phx-click="show_request_details"
            phx-value-id={@request.id}
          />
          <.link
            :if={@request.status == "approved" and @request.media_item}
            navigate={~p"/media/#{@request.media_item.id}"}
            class="btn btn-sm btn-ghost join-item"
            title={gettext("View in Library")}
            aria-label={gettext("View in Library")}
          >
            <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" />
          </.link>
          <.row_action
            :if={@request.status == "pending"}
            icon="hero-check"
            title={gettext("Approve")}
            phx-click="open_approve_modal"
            phx-value-id={@request.id}
          />
          <.row_action
            :if={@request.status == "pending"}
            icon="hero-x-mark"
            title={gettext("Reject")}
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
  attr :display, Mydia.TimeDisplay, required: true

  defp request_outcome(assigns) do
    ~H"""
    <div :if={@request.status == "approved"} class="flex items-start gap-2 text-success">
      <.icon name="hero-check-circle" class="w-4 h-4 mt-0.5" />
      <div>
        <div>
          <%= if @request.approved_by do %>
            {gettext("Approved by %{email} on %{date}",
              email: @request.approved_by.email,
              date: format_date(@request.approved_at, @display)
            )}
          <% else %>
            {gettext("Approved automatically on %{date}",
              date: format_date(@request.approved_at, @display)
            )}
          <% end %>
        </div>
        <div :if={@request.admin_notes} class="text-xs mt-1">
          {gettext("Admin notes: %{notes}", notes: @request.admin_notes)}
        </div>
      </div>
    </div>
    <div :if={@request.status == "rejected"} class="flex items-start gap-2 text-error">
      <.icon name="hero-x-circle" class="w-4 h-4 mt-0.5" />
      <div>
        <div>
          {gettext("Rejected by %{email} on %{date}",
            email: @request.approved_by.email,
            date: format_date(@request.rejected_at, @display)
          )}
        </div>
        <div :if={@request.rejection_reason} class="text-xs mt-1">
          {gettext("Reason: %{reason}", reason: @request.rejection_reason)}
        </div>
        <div :if={@request.admin_notes} class="text-xs mt-1">
          {gettext("Admin notes: %{notes}", notes: @request.admin_notes)}
        </div>
      </div>
    </div>
    """
  end

  attr :detail_request, :any, default: nil

  @doc "The header action buttons of the request detail popup."
  def detail_actions(assigns) do
    ~H"""
    <button class="btn btn-ghost" phx-click="close_request_details_modal">
      {gettext("Close")}
    </button>
    <.link
      :if={@detail_request && @detail_request.media_item}
      navigate={~p"/media/#{@detail_request.media_item.id}"}
      class="btn btn-primary"
    >
      <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" /> {gettext("View in Library")}
    </.link>
    <%= if @detail_request && @detail_request.status == "pending" do %>
      <button class="btn btn-error" phx-click="open_reject_modal" phx-value-id={@detail_request.id}>
        <.icon name="hero-x-mark" class="w-4 h-4" /> {gettext("Reject")}
      </button>
      <button
        class="btn btn-success"
        phx-click="open_approve_modal"
        phx-value-id={@detail_request.id}
      >
        <.icon name="hero-check" class="w-4 h-4" /> {gettext("Approve")}
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
      title={gettext("Approve Request")}
      on_close="close_approve_modal"
    >
      <div class="alert alert-success mb-4">
        <.icon name="hero-information-circle" class="w-5 h-5" />
        <div>
          <p class="font-semibold">{@selected_request.title}</p>
          <p class="text-sm">{gettext("This will create the media item in your library.")}</p>
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
            <span class="label-text font-semibold">{gettext("Admin Notes (Optional)")}</span>
          </label>
          <textarea
            name="approve[admin_notes]"
            class="textarea textarea-bordered h-24"
            placeholder={gettext("Add any notes about this approval...")}
          >{@approve_form[:admin_notes].value}</textarea>
        </div>
        <.admin_modal_actions>
          <button type="button" class="btn btn-ghost" phx-click="close_approve_modal">
            {gettext("Cancel")}
          </button>
          <button
            type="submit"
            class="btn btn-success"
            disabled={@approve_config && @approve_config.libraries == []}
          >
            <.icon name="hero-check" class="w-5 h-5" /> {gettext("Approve & Add to Library")}
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
      title={gettext("Reject Request")}
      on_close="close_reject_modal"
    >
      <div class="alert alert-error mb-4">
        <.icon name="hero-information-circle" class="w-5 h-5" />
        <div>
          <p class="font-semibold">{@selected_request.title}</p>
          <p class="text-sm">{gettext("Please provide a reason for rejecting this request.")}</p>
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
            <span class="label-text font-semibold">{gettext("Rejection Reason")}</span>
            <span class="label-text-alt text-error">*</span>
          </label>
          <textarea
            name="reject[rejection_reason]"
            class="textarea textarea-bordered h-24"
            placeholder={gettext("Explain why this request is being rejected...")}
            required
          >{@reject_form[:rejection_reason].value}</textarea>
          <%= if @reject_form[:rejection_reason].errors != [] do %>
            <label class="label">
              <span class="label-text-alt text-error">
                {Enum.map_join(@reject_form[:rejection_reason].errors, ", ", &translate_error/1)}
              </span>
            </label>
          <% end %>
        </div>
        <div class="form-control mb-4">
          <label class="label">
            <span class="label-text font-semibold">{gettext("Admin Notes (Optional)")}</span>
          </label>
          <textarea
            name="reject[admin_notes]"
            class="textarea textarea-bordered h-20"
            placeholder={gettext("Add any additional notes...")}
          >{@reject_form[:admin_notes].value}</textarea>
        </div>
        <.admin_modal_actions>
          <button type="button" class="btn btn-ghost" phx-click="close_reject_modal">
            {gettext("Cancel")}
          </button>
          <button type="submit" class="btn btn-error">
            <.icon name="hero-x-mark" class="w-5 h-5" /> {gettext("Reject Request")}
          </button>
        </.admin_modal_actions>
      </.form>
    </.admin_modal>
    """
  end
end
