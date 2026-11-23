defmodule MydiaWeb.MediaLive.Show.AvailabilityComponents do
  @moduledoc """
  The hero column's Search Starts row and its page-level modal, for movies.

  A modal rather than an anchored dropdown for the reason documented on
  `MydiaWeb.MediaLive.Show.LibraryComponents.target_library_row/1`: the hero
  column is `overflow-y-auto`, which clips an anchored `.dropdown-content`.

  The level chosen here decides when automatic search may start looking for
  this movie; see `Mydia.Media.MinimumAvailability`. The Search button on this
  page ignores it.
  """
  use MydiaWeb, :html

  alias Mydia.Media.MinimumAvailability
  alias MydiaWeb.MediaLive.Show.Formatters
  alias MydiaWeb.MediaLive.Show.HeroRow
  alias MydiaWeb.MinimumAvailabilityLabels

  attr :media_item, :map, required: true

  def availability_row(assigns) do
    assigns = assign(assigns, :status, MinimumAvailability.status(assigns.media_item))

    ~H"""
    <HeroRow.row_button
      id="availability-row"
      phx-click="show_availability_modal"
      title={gettext("Click to change when automatic search starts")}
    >
      <div class="w-8 h-8 rounded-lg bg-warning/10 flex items-center justify-center flex-shrink-0">
        <.icon name="hero-calendar" class="w-4 h-4 text-warning" />
      </div>
      <div class="flex-1 min-w-0 text-left">
        <div class="text-xs text-base-content/50">{gettext("Search Starts")}</div>
        <div class="text-sm font-medium truncate">
          {when_label(@status)}
          <span class="text-base-content/50">
            · {MinimumAvailabilityLabels.label(@status.level)}
          </span>
        </div>
      </div>
      <.icon
        name="hero-chevron-right"
        class="w-4 h-4 text-base-content/30 group-hover:text-base-content/60 transition-colors flex-shrink-0"
      />
    </HeroRow.row_button>
    """
  end

  attr :media_item, :map, required: true

  def availability_modal(assigns) do
    assigns =
      assigns
      |> assign(:current, assigns.media_item.minimum_availability)
      |> assign(
        :global_label,
        MinimumAvailabilityLabels.label(MinimumAvailability.global_level())
      )
      |> assign(:options, MinimumAvailabilityLabels.options())

    ~H"""
    <div id="availability-modal" class="modal modal-open">
      <div class="modal-box max-w-sm">
        <h3 class="font-bold text-lg mb-1">{gettext("Search Starts")}</h3>
        <p class="text-sm text-base-content/60 mb-3">
          {gettext(
            "Automatic search waits until this point. The Search button on this page ignores it."
          )}
        </p>
        <ul class="menu w-full p-0">
          <.option id="availability-option-default" value="default" active?={is_nil(@current)}>
            {gettext("Server default (%{level})", level: @global_label)}
          </.option>
          <.option
            :for={{level, label} <- @options}
            id={"availability-option-#{level}"}
            value={level}
            active?={@current == level}
          >
            {label}
          </.option>
        </ul>
        <div class="modal-action">
          <button type="button" phx-click="hide_availability_modal" class="btn btn-ghost">
            {gettext("Cancel")}
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="hide_availability_modal"></div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :active?, :boolean, default: false
  slot :inner_block, required: true

  defp option(assigns) do
    ~H"""
    <li>
      <button
        id={@id}
        type="button"
        phx-click="set_minimum_availability"
        phx-value-level={@value}
        class={["justify-between", @active? && "active"]}
      >
        <span>{render_slot(@inner_block)}</span>
        <.icon :if={@active?} name="hero-check" class="w-4 h-4" />
      </button>
    </li>
    """
  end

  defp when_label(%{available?: true}), do: gettext("Now")

  defp when_label(%{eligible_on: date}),
    do: gettext("On %{date}", date: Formatters.format_date(date))
end
