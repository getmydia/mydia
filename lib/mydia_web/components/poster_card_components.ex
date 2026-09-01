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
  card-body's own `gap-2` so children keep the spacing they had when they were
  direct card-body children.

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
end
