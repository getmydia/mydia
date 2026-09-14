defmodule MydiaWeb.MediaLive.Index.SelectionComponents do
  @moduledoc """
  Controls for starting bulk selection from a media card or row. Used only by
  the sibling LiveView, never imported globally.
  """
  use MydiaWeb, :html

  @doc """
  Renders the round checkbox that appears while a grid card or list row is
  hovered or keyboard-focused. Clicking it turns on selection mode with this
  item already selected, so someone deep in the library never has to scroll
  back up to the header's Select button.

  The enclosing card or row must carry Tailwind's `group` class. The button
  stays `opacity-0 pointer-events-none` until that group is hovered. Tailwind
  v4 emits `hover` variants inside `@media (hover: hover)`, so a touch-only
  screen never reveals it and a tap on the poster still reaches its link.

  `hide-on-select` removes it once selection mode is on, where the card's own
  selection indicator takes its place.

  Two things happen on click. `start_selection` updates the server. Streamed
  items do not re-render when only assigns change, so `mydia:start-selection`
  also marks `target` selected in the browser, the same way the toolbar's
  Select all dispatches `mydia:select-all`.
  """
  attr :item, :map, required: true
  attr :target, :string, required: true, doc: "selector of the card or row to mark selected"
  attr :size, :atom, values: [:sm, :xs], default: :sm
  attr :class, :any, default: nil

  def start_selection_button(assigns) do
    ~H"""
    <button
      type="button"
      id={"select-from-card-#{@item.id}"}
      aria-label={"Select #{@item.title}"}
      title="Select"
      phx-click={
        JS.push("start_selection", value: %{id: @item.id})
        |> JS.dispatch("mydia:start-selection", to: @target)
      }
      class={[
        "btn btn-circle border-2 border-base-300 bg-base-100/90 shadow-lg hide-on-select",
        "hover:border-primary hover:text-primary",
        "opacity-0 pointer-events-none transition-opacity duration-150",
        "group-hover:opacity-100 group-hover:pointer-events-auto focus-visible:opacity-100",
        @size == :sm && "btn-sm",
        @size == :xs && "btn-xs",
        @class
      ]}
    >
      <.icon name="hero-check" class={if(@size == :sm, do: "w-4 h-4", else: "w-3 h-3")} />
    </button>
    """
  end
end
