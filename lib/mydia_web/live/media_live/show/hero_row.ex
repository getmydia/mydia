defmodule MydiaWeb.MediaLive.Show.HeroRow do
  @moduledoc """
  The clickable row in the media detail hero's info card (quality profile,
  download audio, target library, category).

  A ghost `btn` rather than a `menu` item: the same card also holds static rows
  (path, size on disk) that must not pick up a menu's hover state.
  """
  use MydiaWeb, :html

  attr :rest, :global
  slot :inner_block, required: true

  def row_button(assigns) do
    ~H"""
    <button
      type="button"
      class="btn btn-ghost btn-block h-auto min-h-0 flex-nowrap justify-start gap-2.5 px-2 py-1.5 font-normal text-left group hover:bg-base-300/50"
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end
end
