defmodule MydiaWeb.DiscoverComponents do
  @moduledoc """
  Shared media card and rail components, used by Dashboard, Discover, and the
  media detail page's Collection and recommendations strips.
  """
  use Phoenix.Component

  import MydiaWeb.CoreComponents, only: [icon: 1, poster_figure: 1]

  alias Mydia.Metadata.ImageUrl
  alias MydiaWeb.LibraryComponents

  use Phoenix.VerifiedRoutes,
    endpoint: MydiaWeb.Endpoint,
    router: MydiaWeb.Router,
    statics: MydiaWeb.static_paths()

  @doc """
  Renders a trending media card with poster, status badge, title, year,
  and an action button (Add to Library / Request / Go to Movie/Show).

  ## Attributes

    * `item` - enriched search result map with `in_library`, `monitored`,
      `id`, `provider_id`, `poster_path`, `title`, `year` fields.
    * `media_type` - `:movie` or `:tv_show`.
    * `current_user` - current user struct (for guest vs admin logic).
    * `adding_ids` - MapSet of provider ids whose add is in flight.
  """
  attr :item, :map, required: true
  attr :media_type, :atom, required: true
  attr :current_user, :map, required: true
  # The ids whose add is in flight. A MapSet rather than a single id because
  # every rail can have several adds running at once, and a single id has to
  # pick an arbitrary survivor when one of them finishes (#459). Members are
  # compared as strings: the detail page sets hold parsed integers while a
  # SearchResult's provider_id is a string.
  attr :adding_ids, MapSet, default: MapSet.new()
  attr :requesting_item_id, :string, default: nil
  attr :libraries, :list, default: []
  # :any rather than :string because nil is a meaningful value here: it renders
  # an inert poster, which is what a LiveView with no select handler needs.
  # Typing this :string makes `on_select={nil}` a compile error under
  # --warnings-as-errors.
  attr :on_select, :any, default: "show_details"
  attr :navigate, :string, default: nil
  # The action buttons are the card's event contract with its host LiveView.
  # Discover handles "add_to_library"/"request_media", so those stay the
  # defaults, but a host with different handlers must be able to say so:
  # emitting an event the host does not handle raises FunctionClauseError and
  # kills the LiveView process on the very first click.
  attr :add_event, :string, default: "add_to_library"
  attr :request_event, :string, default: "request_media"
  attr :can_add, :boolean, default: true
  # The card for the title whose page you are already on. It draws the ring and
  # renders no action, because a "Go to Movie" pointing at the current page is
  # nonsense.
  attr :current, :boolean, default: false
  # "lazy" is the safe default: eagerly fetching every card, including the
  # ones below the fold, is what starved the Dashboard's actual LCP poster
  # under 40 competing requests. A caller with a poster above the fold
  # (roughly the first grid row on Dashboard and Discover) opts out with
  # loading={nil}, which renders no loading attribute at all.
  attr :loading, :string, default: "lazy"
  # w500 is the right size for a grid card; a rail card is w-36 (144px), which
  # wants the smaller w342 step.
  attr :poster_size, :string, default: "w500"

  def trending_card(assigns) do
    assigns = assign(assigns, :adding?, adding?(assigns))

    ~H"""
    <div class={[
      "card bg-base-100 shadow-sm hover:shadow-md transition-shadow relative group",
      @current && "ring-2 ring-primary"
    ]}>
      <%= if (vote = Map.get(@item, :vote_average)) && vote > 0 do %>
        <div class="absolute top-2 left-2 z-10">
          <div class="badge badge-warning gap-1 shadow-md">
            <.icon name="hero-star-solid" class="w-3 h-3" />
            <span class="text-xs">{Float.round(vote / 1, 1)}</span>
          </div>
        </div>
      <% end %>
      <%= if @item.in_library do %>
        <div class="absolute top-2 right-2 z-10">
          <%= if @item.monitored do %>
            <div class="w-6 h-6 rounded-full bg-success flex items-center justify-center shadow-md">
              <.icon name="hero-check-mini" class="w-4 h-4 text-success-content" />
            </div>
          <% else %>
            <div class="w-6 h-6 rounded-full bg-base-300 flex items-center justify-center shadow-md">
              <.icon name="hero-minus-small" class="w-4 h-4 text-base-content/60" />
            </div>
          <% end %>
        </div>
      <% end %>
      <%= cond do %>
        <% @navigate -> %>
          <.link navigate={@navigate} class="block">
            <.card_poster
              item={@item}
              media_type={@media_type}
              loading={@loading}
              poster_size={@poster_size}
              class="cursor-pointer rounded-t-box"
            />
          </.link>
        <% @on_select -> %>
          <div
            phx-click={@on_select}
            phx-value-id={@item.provider_id}
            phx-value-type={@media_type}
          >
            <.card_poster
              item={@item}
              media_type={@media_type}
              loading={@loading}
              poster_size={@poster_size}
              class="cursor-pointer rounded-t-box"
            />
          </div>
        <% true -> %>
          <.card_poster
            item={@item}
            media_type={@media_type}
            loading={@loading}
            poster_size={@poster_size}
            class="rounded-t-box"
          />
      <% end %>
      <div class="card-body p-3">
        <h3 class="font-semibold text-sm line-clamp-2" title={@item.title}>
          {@item.title}
        </h3>
        <%= if @item.year do %>
          <p class="text-xs text-base-content/60">{@item.year}</p>
        <% end %>
        <.trending_card_action
          :if={not @current}
          item={@item}
          media_type={@media_type}
          current_user={@current_user}
          adding={@adding?}
          requesting_item_id={@requesting_item_id}
          libraries={@libraries}
          add_event={@add_event}
          request_event={@request_event}
          can_add={@can_add}
        />
      </div>
    </div>
    """
  end

  # Members and provider ids are normalised to strings on both sides. The hosts
  # genuinely disagree about the type and cannot cheaply be made to agree, and a
  # mismatch under MapSet.member?/2 would silently draw no spinner at all.
  defp adding?(%{item: item, adding_ids: adding_ids}) do
    provider_id = to_string(item.provider_id)
    Enum.any?(adding_ids, &(to_string(&1) == provider_id))
  end

  @doc """
  Renders a horizontal strip of media cards under a heading.

  Reuses `trending_card/1` so an owned title carries the same badge and an
  unowned one the same add-or-request action as it would on the Discover grid.
  The strip renders nothing at all when `items` is empty, which is the designed
  behaviour for a title TMDB has no recommendations for and for a movie in no
  collection.

  An item may carry these optional keys:

    * `:navigate` - the poster becomes a link instead of a click target, which
      is how an owned title reaches its own page from a LiveView that has no
      `show_details` handler.
    * `:current` - the card draws the primary ring and renders no action,
      because this is the title whose page the user is already on.
  """
  attr :items, :list, required: true
  attr :media_type, :atom, required: true
  attr :current_user, :map, required: true
  attr :adding_ids, MapSet, default: MapSet.new()
  attr :requesting_item_id, :string, default: nil
  # The rail is a horizontal scroll container, so the old anchored dropdown
  # could not escape it at any placement and was withdrawn here (#465). The
  # picker is now a page-level dialog, which no ancestor's overflow can clip,
  # so the attr is back. A host that passes nothing still gets no caret.
  attr :libraries, :list, default: []

  attr :id, :string, default: "media-rail"
  attr :title, :string, default: "More like this"
  # :any, not :string - see the note on trending_card/1. The media detail page
  # passes nil here because it has no show_details handler.
  attr :on_select, :any, default: "show_details"
  # Forwarded to trending_card/1. A host LiveView that does not handle
  # "add_to_library"/"request_media" must override these or the first click on
  # an unowned card crashes it.
  attr :add_event, :string, default: "add_to_library"
  attr :request_event, :string, default: "request_media"
  attr :can_add, :boolean, default: true

  # Opt-in disclosure, off by default so Discover, Dashboard and the franchise
  # strip keep rendering exactly as before. A function component cannot hold
  # state, so the host LiveView owns `expanded` and handles `toggle_event`.
  attr :collapsible, :boolean, default: false
  attr :expanded, :boolean, default: true
  attr :toggle_event, :string, default: nil

  slot :badge

  def media_rail(assigns) do
    if assigns.collapsible and is_nil(assigns.toggle_event) do
      raise ArgumentError,
            "media_rail #{inspect(assigns.id)} is collapsible but was given no " <>
              "toggle_event, so its header would render a chevron nothing can open"
    end

    assigns = assign(assigns, :open?, not assigns.collapsible or assigns.expanded)

    ~H"""
    <div :if={@items != []} id={@id} class="mb-6 md:mb-8">
      <div class="flex items-center justify-between gap-3 mb-3">
        <%!-- The heading is repeated across both branches on purpose: HEEx cannot
              swap a tag name. The collapsible branch puts the button inside the
              heading rather than the other way around, because `button` takes
              phrasing content and a heading is not phrasing content. --%>
        <h2 :if={@collapsible} class="min-w-0">
          <button
            type="button"
            id={"#{@id}-toggle"}
            class="flex items-center gap-2 min-w-0 w-full cursor-pointer text-left"
            phx-click={@toggle_event}
            aria-expanded={to_string(@open?)}
            aria-controls={if @open?, do: "#{@id}-items"}
          >
            <.icon
              name={if @open?, do: "hero-chevron-down", else: "hero-chevron-right"}
              class="w-4 h-4 text-base-content/40 shrink-0"
            />
            <span class="text-lg md:text-xl font-semibold truncate">{@title}</span>
            <span class="badge badge-ghost badge-sm shrink-0">{length(@items)}</span>
          </button>
        </h2>
        <h2 :if={not @collapsible} class="text-lg md:text-xl font-semibold truncate">{@title}</h2>
        <div :if={@badge != []} class="flex-shrink-0">{render_slot(@badge)}</div>
      </div>

      <div
        :if={@open?}
        id={if @collapsible, do: "#{@id}-items"}
        class="flex gap-3 overflow-x-auto snap-x scroll-smooth pb-2"
      >
        <div
          :for={item <- @items}
          id={"#{@id}-item-#{item.provider_id}"}
          class="snap-start flex-shrink-0 w-36"
        >
          <.trending_card
            item={item}
            media_type={@media_type}
            current_user={@current_user}
            adding_ids={@adding_ids}
            current={Map.get(item, :current, false)}
            requesting_item_id={@requesting_item_id}
            libraries={@libraries}
            on_select={@on_select}
            navigate={Map.get(item, :navigate)}
            add_event={@add_event}
            request_event={@request_event}
            can_add={@can_add}
            poster_size="w342"
          />
        </div>
      </div>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :media_type, :atom, required: true
  attr :current_user, :map, required: true
  attr :adding, :boolean, default: false
  attr :requesting_item_id, :string, default: nil
  attr :libraries, :list, default: []
  attr :add_event, :string, default: "add_to_library"
  attr :request_event, :string, default: "request_media"
  attr :can_add, :boolean, default: true

  defp trending_card_action(assigns) do
    ~H"""
    <%= cond do %>
      <% not @item.in_library and guest?(@current_user) -> %>
        <button
          phx-click={@request_event}
          phx-value-tmdb_id={@item.provider_id}
          phx-value-media_type={@media_type}
          disabled={requested?(@item) or requesting?(@item, @requesting_item_id)}
          class="btn btn-primary btn-sm mt-2 w-full"
        >
          <%= cond do %>
            <% requesting?(@item, @requesting_item_id) -> %>
              <span class="loading loading-spinner loading-xs"></span> Requesting...
            <% requested?(@item) -> %>
              <.icon name="hero-check" class="w-4 h-4" /> Requested
            <% true -> %>
              <.icon name="hero-paper-airplane" class="w-4 h-4" /> Request
          <% end %>
        </button>
      <% not @item.in_library and @can_add -> %>
        <div class="join w-full mt-2">
          <button
            phx-click={@add_event}
            phx-value-tmdb_id={@item.provider_id}
            phx-value-media_type={@media_type}
            disabled={@adding}
            class="btn btn-primary btn-sm join-item flex-1"
          >
            <%= if @adding do %>
              <span class="loading loading-spinner loading-xs"></span> Adding...
            <% else %>
              <.icon name="hero-plus" class="w-4 h-4" /> Add to Library
            <% end %>
          </button>
          <LibraryComponents.library_picker_button
            libraries={@libraries}
            tmdb_id={@item.provider_id}
            media_type={@media_type}
            title={@item.title}
          />
        </div>
      <% @item.in_library -> %>
        <.link navigate={library_path(@media_type, @item.id)} class="btn btn-ghost btn-sm mt-2 w-full">
          <.icon name="hero-arrow-right" class="w-4 h-4" />
          {if(@media_type == :movie, do: "Go to Movie", else: "Go to Show")}
        </.link>
      <% true -> %>
        <%!-- Unowned, and this viewer may neither add nor request. Rendering the
             owned branch here would build a link from a nil id. --%>
    <% end %>
    """
  end

  # A guest requests rather than adds, so the guest branch is gated on the
  # request permission, not on `can_add`.
  defp guest?(%{role: "guest"}), do: true
  defp guest?(_), do: false

  defp requested?(item), do: Map.get(item, :request_status) != nil

  defp requesting?(item, requesting_item_id),
    do: requesting_item_id != nil and requesting_item_id == to_string(item.provider_id)

  defp library_path(:movie, id), do: "/movies/#{id}"
  defp library_path(:tv_show, id), do: "/tv/#{id}"

  attr :item, :map, required: true
  attr :media_type, :atom, required: true
  # nil renders no loading attribute at all. See the note on trending_card/1's
  # :loading attr for why that matters for an above-the-fold grid.
  attr :loading, :string, default: nil
  attr :poster_size, :string, default: "w500"
  attr :class, :string, default: nil

  defp card_poster(assigns) do
    ~H"""
    <.poster_figure
      src={@item.poster_path && ImageUrl.poster_url(@item.poster_path, @poster_size)}
      alt={@item.title}
      loading={@loading}
      fallback_icon={if(@media_type == :movie, do: "hero-film", else: "hero-tv")}
      class={@class}
    />
    """
  end
end
