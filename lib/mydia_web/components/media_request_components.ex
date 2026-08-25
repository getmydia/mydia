defmodule MydiaWeb.MediaRequestComponents do
  @moduledoc """
  Card chrome shared by the two media request pages.

  Imported by `MydiaWeb.AdminRequestsLive.Index` and
  `MydiaWeb.MyRequestsLive.Index` rather than added to `html_helpers`: the
  project reserves global imports for components used by three or more
  LiveViews, which is how `MydiaWeb.DiscoverComponents` is wired.

  Everything the two pages disagree about lives in the `:badges`, `:details`
  and `:actions` slots, so neither page needs a flag for the other's chrome.
  """
  use Phoenix.Component

  alias Mydia.Media.MediaRequest
  alias Mydia.Metadata.ImageUrl

  @placeholder_poster "/images/no-poster.svg"
  @poster_size "w185"

  @doc """
  Renders one request as a card with a poster and a clickable title.

  The poster and the title both fire `on_select` with the request id, matching
  how a Discovery card behaves. A request with no TMDB or TVDB id cannot be
  resolved against a provider, so it renders as static text with no click
  target.
  """
  attr :request, MediaRequest, required: true
  attr :on_select, :string, default: "show_details"

  slot :badges, doc: "Extra badges rendered beside the status and media type."
  slot :details, doc: "The page-specific body: requester, timestamps, notes."
  slot :actions, doc: "The page-specific footer buttons."

  def request_card(assigns) do
    assigns =
      assigns
      |> assign(:detailable, MediaRequest.detailable?(assigns.request))
      |> assign(:poster_src, poster_src(assigns.request))

    ~H"""
    <div class="card bg-base-100 shadow-lg" id={"request-#{@request.id}"}>
      <div class="card-body">
        <div class="flex gap-4">
          <%= if @detailable do %>
            <button
              type="button"
              phx-click={@on_select}
              phx-value-id={@request.id}
              aria-label={"View details for #{@request.title}"}
              class="shrink-0 w-16 md:w-24 rounded-lg overflow-hidden transition hover:opacity-80 focus:outline-none focus:ring-2 focus:ring-primary"
            >
              <img
                src={@poster_src}
                alt=""
                loading="lazy"
                class="w-full aspect-[2/3] object-cover bg-base-300"
              />
            </button>
          <% else %>
            <div class="shrink-0 w-16 md:w-24 rounded-lg overflow-hidden">
              <img
                src={@poster_src}
                alt=""
                loading="lazy"
                class="w-full aspect-[2/3] object-cover bg-base-300"
              />
            </div>
          <% end %>

          <div class="flex-1 min-w-0">
            <h3 class="card-title">
              <%= if @detailable do %>
                <button
                  type="button"
                  phx-click={@on_select}
                  phx-value-id={@request.id}
                  class="link link-hover text-left"
                >
                  {@request.title}
                </button>
              <% else %>
                <span>{@request.title}</span>
              <% end %>
              <%= if @request.year do %>
                <span class="text-base-content/70 font-normal">({@request.year})</span>
              <% end %>
            </h3>

            <div class="flex flex-wrap items-center gap-2 mt-1">
              <span class={["badge badge-sm", status_badge_class(@request.status)]}>
                {status_text(@request.status)}
              </span>
              <span class="badge badge-sm badge-ghost">
                {media_type_text(@request.media_type)}
              </span>
              {render_slot(@badges)}
            </div>

            <div :if={@details != []} class="mt-4 space-y-2 text-sm">
              {render_slot(@details)}
            </div>

            <div :if={@actions != []} class="card-actions mt-4">
              {render_slot(@actions)}
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc "DaisyUI badge modifier for a request status."
  def status_badge_class("pending"), do: "badge-warning"
  def status_badge_class("approved"), do: "badge-success"
  def status_badge_class("rejected"), do: "badge-error"
  def status_badge_class(_), do: "badge-ghost"

  @doc "Human label for a request status."
  def status_text("pending"), do: "Pending Review"
  def status_text("approved"), do: "Approved"
  def status_text("rejected"), do: "Rejected"
  def status_text(_), do: "Unknown"

  @doc "Formats a request timestamp, or \"N/A\" when it is nil."
  def format_date(nil), do: "N/A"
  def format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d, %Y at %I:%M %p")

  defp media_type_text(media_type) do
    media_type
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp poster_src(%MediaRequest{poster_path: nil}), do: @placeholder_poster
  defp poster_src(%MediaRequest{poster_path: path}), do: ImageUrl.poster_url(path, @poster_size)
end
