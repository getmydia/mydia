defmodule MydiaWeb.DashboardLive.ShelfComponents do
  @moduledoc "The Home rail for a plugin shelf: cards with a reason and a dismiss control."
  use MydiaWeb, :html

  import MydiaWeb.DiscoverComponents, only: [trending_card: 1]
  import MydiaWeb.PosterCardComponents, only: [poster_rail: 1]

  alias MydiaWeb.DashboardLive.ShelfRail

  attr :rail, ShelfRail, required: true
  attr :current_user, :map, required: true
  attr :adding_ids, MapSet, required: true
  attr :requesting_item_id, :string, default: nil

  def shelf_rail(assigns) do
    ~H"""
    <div :if={@rail.items != []} id={@rail.id} class="mb-6 md:mb-8">
      <div class="flex items-center gap-2 mb-3">
        <.icon name="hero-sparkles" class="w-5 h-5 text-primary shrink-0" />
        <h2 class="text-lg md:text-xl font-semibold truncate">{@rail.title}</h2>
      </div>
      <%!-- items-start keeps each wrapper at its content height. A stretched
            flex item has a definite height, so the card's h-full would grow to
            fill the tallest column and push the reason out of view. --%>
      <.poster_rail class="items-start">
        <div
          :for={item <- @rail.items}
          id={"#{@rail.id}-item-#{item.shelf_item_id}"}
          class="snap-start flex-shrink-0 w-36"
        >
          <.trending_card
            item={item}
            media_type={item.media_type}
            current_user={@current_user}
            adding_ids={@adding_ids}
            requesting_item_id={@requesting_item_id}
            on_select="show_details"
            poster_size="w342"
          />
          <%!-- Three lines are always reserved (3 x 1.375 x 0.75rem) so the
                buttons line up whatever the reason length, or without one. --%>
          <p class="mt-2 h-[3.0938rem] overflow-hidden text-xs leading-snug text-base-content/70 line-clamp-3">
            {item.reason}
          </p>
          <button
            type="button"
            id={"shelf-dismiss-#{item.shelf_item_id}"}
            phx-click="dismiss_shelf_item"
            phx-value-id={item.shelf_item_id}
            class="btn btn-ghost btn-xs mt-1 w-full text-base-content/60 transition-colors hover:text-base-content"
          >
            Not interested
          </button>
        </div>
      </.poster_rail>
    </div>
    """
  end
end
