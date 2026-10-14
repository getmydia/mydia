defmodule MydiaWeb.AdminModalComponents do
  @moduledoc """
  The one modal shell every admin page uses: icon tile header, the body the
  page supplies (usually its `<.form>`), a bordered action row and a dimmed
  backdrop that closes it.

  The page owns the form, its events and the open/closed assign. A form whose
  buttons must live inside the `<form>` element renders
  `admin_modal_actions/1` itself and leaves the `:actions` slot empty.
  """
  use Phoenix.Component

  import MydiaWeb.CoreComponents, only: [icon: 1]

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil

  attr :on_close, :any,
    required: true,
    doc:
      "event name or JS for the backdrop and the header close button; nil for a modal a stray click must not dismiss (no close button)"

  attr :tone, :atom,
    default: :primary,
    values: [:primary, :error],
    doc: ":error for destructive confirmations"

  attr :size, :atom, default: :md, values: [:md, :lg], doc: ":lg for browsers and catalogues"
  slot :header_aside, doc: "right side of the header, e.g. an Enabled toggle"
  slot :inner_block, required: true
  slot :actions

  def admin_modal(assigns) do
    ~H"""
    <div
      id={@id}
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-title"}
    >
      <div class={[
        "modal-box flex flex-col overflow-hidden",
        "max-sm:w-full max-sm:max-w-none max-sm:h-full max-sm:max-h-none max-sm:rounded-none",
        "[&_.label]:whitespace-normal",
        box_width(@size)
      ]}>
        <div class="flex items-center justify-between gap-3 mb-5 shrink-0">
          <div class="flex items-center gap-3 min-w-0">
            <div class={[
              "w-10 h-10 rounded-xl flex items-center justify-center shrink-0",
              tile_tone(@tone)
            ]}>
              <.icon name={@icon} class={"w-5 h-5 " <> icon_tone(@tone)} />
            </div>
            <div class="min-w-0">
              <h3 id={"#{@id}-title"} class="font-bold text-lg">{@title}</h3>
              <p :if={@subtitle} class="text-sm text-base-content/60">{@subtitle}</p>
            </div>
          </div>
          <div class="flex items-center gap-2 shrink-0">
            {render_slot(@header_aside)}
            <button
              :if={@on_close}
              id={"#{@id}-close"}
              type="button"
              class="btn btn-sm btn-circle btn-ghost"
              aria-label="Close"
              phx-click={@on_close}
            >
              <.icon name="hero-x-mark" class="w-5 h-5" />
            </button>
          </div>
        </div>
        <div id={"#{@id}-body"} class="flex-1 min-h-0 overflow-y-auto px-1 -mx-1">
          {render_slot(@inner_block)}
        </div>
        <.admin_modal_actions :if={@actions != []}>{render_slot(@actions)}</.admin_modal_actions>
      </div>
      <div class="modal-backdrop bg-black/50" phx-click={@on_close}></div>
    </div>
    """
  end

  slot :inner_block, required: true

  @doc """
  The bordered button row at the bottom of an admin_modal/1. Sticky, so a form
  that renders it inside its own `<form>` (and so inside the scrolling body)
  still keeps its buttons on screen.
  """
  def admin_modal_actions(assigns) do
    ~H"""
    <div class="modal-action mt-6 pt-4 border-t border-base-300 sticky bottom-0 bg-base-100">
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp tile_tone(:primary), do: "bg-primary/20"
  defp tile_tone(:error), do: "bg-error/20"

  defp icon_tone(:primary), do: "text-primary"
  defp icon_tone(:error), do: "text-error"

  defp box_width(:md), do: "max-w-2xl"
  defp box_width(:lg), do: "max-w-4xl"
end
