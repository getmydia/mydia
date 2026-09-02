defmodule MydiaWeb.PosterCardComponents do
  @moduledoc """
  The body of a poster card: a title box of reserved height, and a metadata
  block pinned to the card's bottom edge.

  This exists for the same reason `poster_figure/1` does. The markup was
  hand-copied across seven files and drifted, and the drift is visible. A long
  title wraps to two lines while a short one takes one, so everything below the
  title sits at a different height on each card in a row.

  Three details are load-bearing.

  `min-h-[2lh]` reserves two of the element's own line-heights, so the title box
  stays correct if the type scale changes. `add_media_live` previously hardcoded
  `h-10`, which is two lines only while the title is `text-sm`. Where `lh` is
  unsupported the declaration is dropped and the card falls back to the
  unreserved behaviour it had before, never to a clipped title.

  `font-semibold` rather than daisyUI's `card-title`. `.card-title` is
  `display: flex` in layer `daisyui.l1.l2.l3`, while `.line-clamp-2` is
  `display: -webkit-box` declared directly in `utilities`. A rule declared
  directly in a layer beats that layer's nested sublayers, so clamping wins, but
  only by cascade accident. What `card-title` contributed here was
  `font-weight: 600` plus flex properties that never applied.

  `mt-auto` on the metadata wrapper replaces daisyUI's
  `.card-body p { flex-grow: 1 }`, which pinned Discover's action button to the
  bottom only because its year happened to be a `p`. The wrapper repeats
  card-body's own `gap-2` so the gap between metadata children is unchanged. Gap
  and margin are additive, not interchangeable: a caller that also had margin
  utilities on those children (an `mt-1` on an overview paragraph, an `mt-2` on
  `card-actions`) must keep them, or that spacing is silently deleted.

  The caller's `.card` has to stretch to its row for `mt-auto` to have anything
  to push against. Where the card is nested below the grid or flex item rather
  than being it, the caller adds `h-full`.
  """

  use Phoenix.Component

  @doc """
  Renders a poster card's body.

  The `title` is rendered clamped to two lines and repeated in the `title`
  attribute, so a clamped title is still readable on hover.

  ## Example

      <.poster_card_body title={item.title}>
        <:meta>
          <span class="text-xs text-base-content/70">{item.year}</span>
        </:meta>
      </.poster_card_body>
  """
  attr :title, :string, required: true

  slot :meta,
    doc: "badges, year, counts and actions, pinned to the card's bottom edge"

  def poster_card_body(assigns) do
    ~H"""
    <div class="card-body p-3">
      <h3 class="font-semibold text-sm line-clamp-2 min-h-[2lh]" title={@title}>
        {@title}
      </h3>
      <div :if={@meta != []} class="mt-auto flex flex-col gap-2">
        {render_slot(@meta)}
      </div>
    </div>
    """
  end

  # A TMDB page. Both Metadata.trending_movies/0 and Metadata.discover/2 return
  # a provider page uncapped, so a skeleton grid of this size is replaced
  # one-for-one by real cards and the grid does not resize when they land.
  @skeleton_count 20

  @doc """
  Renders a grid of placeholder cards shaped like a `poster_card_body/1` card.

  Sits beside `poster_card_body/1` rather than in a generic module because the
  two have to keep the same shape, and co-location is the only thing that
  makes a drift visible in review.

  `columns` is a parameter because the consumers genuinely differ: Discover
  drives columns from `GridDensityComponents.grid_columns_class/1` across three
  density levels, while the Dashboard trending rows hardcode a 2/3/4/5 grid.
  Each caller passes the same string its real grid uses, so the placeholder and
  the results lay out identically.

  Reduced motion needs no handling here. daisyUI gates the shimmer behind
  `prefers-reduced-motion: no-preference` and leaves a flat base-300 fill
  otherwise.
  """
  attr :id, :string, default: nil
  attr :count, :integer, default: @skeleton_count
  attr :columns, :string, required: true
  attr :gap, :string, default: "gap-4 md:gap-5"

  def poster_card_grid_skeleton(assigns) do
    ~H"""
    <div id={@id} class={["grid", @gap, @columns]} role="status" aria-label="Loading titles">
      <div :for={_ <- 1..@count} class="card bg-base-100 shadow-lg h-full">
        <div class="skeleton aspect-[2/3] rounded-t-box rounded-b-none"></div>
        <div class="card-body p-3">
          <div class="skeleton h-4 w-full"></div>
          <div class="skeleton h-4 w-2/3"></div>
          <div class="mt-auto flex flex-col gap-4">
            <div class="skeleton h-4 w-10"></div>
            <div class="skeleton h-8 w-full"></div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
