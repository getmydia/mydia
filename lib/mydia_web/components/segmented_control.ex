defmodule MydiaWeb.SegmentedControl do
  @moduledoc """
  A daisyUI `join` of buttons where exactly one option is selected.

  This is the single owner of segment markup. Before it existed the app had
  three conventions for the same control and two of them were invisible in
  dark mode, measured against the built stylesheet:

    * `btn-ghost` on the inactive segments sets `--btn-bg: #0000`. The segment
      computes to `alpha=0` and paints the page background exactly, contrast
      1.000. The button has no body at all.
    * `btn-active` on the selected segment sets
      `color-mix(in oklab, base-200, #000 5%)`, which is 1.059 against a plain
      button and *darker* than it, so the chosen option reads as recessed.

  So: the selected option gets `btn-primary` (4.055 against the page, 3.363
  against its neighbours) and unselected options get no colour class at all,
  falling through to plain `.btn` at opaque `base-200`.

  Unselected options also carry `dark:hover:bg-base-300`. daisyUI's own
  `.btn:hover` mixes toward black, which in dark mode moves `42,49,58` to
  `37,44,51`, a contrast of 1.075 in the wrong direction. `base-300` is a
  1.459 step and lightens. Light mode keeps daisyUI's default, which is
  already a reasonable 1.226 there and stronger than `base-300` would be.

  Full measurements and method in
  `docs/superpowers/specs/2026-09-01-segmented-control-design.md`.

  ## Icon-only controls

  `icon_only` makes the buttons square and moves each label into `aria-label`
  and a tooltip. Three daisyUI traps are handled here so no call site has to:

    * `btn-square` keeps a label-less button from collapsing to its icon.
    * The tooltip goes on a wrapper `div`, never on the button. daisyUI shows
      the tip via `.tooltip:has(:focus-visible)`, and `:has()` carries an
      implicit descendant combinator, so a `.tooltip` button whose only
      descendant is the non-focusable `<span>` from `icon/1` never shows its
      tip on keyboard focus.
    * `join-item` stays on the button and off that wrapper. `.join-item > *`
      resets `--join-ss`/`--join-se`/`--join-es`/`--join-ee` to `initial`, so
      a button nested inside a `join-item` wrapper computes all four corners
      to 0 and the filled active button spills square out of the join's
      rounded end cap.

  ## Values

  `value` and each option's `value` both pass through `to_string/1` before
  comparison, and `phx-value-*` is serialized the same way. Call sites hold
  atoms (`:grid`, `:movie`) and strings (`"dense"`, `"today"`), and
  `phx-value-*` reaches `handle_event` as a string either way, so one coercion
  removes any per-call-site handling.
  """

  use Phoenix.Component

  import MydiaWeb.CoreComponents, only: [icon: 1]

  @doc """
  Renders a segmented control.

  ## Examples

      <.segmented_control
        id="library-density-toggle"
        value={@grid_density}
        event="set_grid_density"
        param="density"
        label="Grid density"
        icon_only
      >
        <:option value="comfortable" label="Comfortable" icon="hero-stop" />
        <:option value="compact" label="Compact" icon="hero-view-columns" />
        <:option value="dense" label="Dense" icon="hero-table-cells" />
      </.segmented_control>
  """
  attr :id, :string, default: nil, doc: "DOM id for the join container"
  attr :value, :any, required: true, doc: "the currently selected value"
  attr :event, :string, required: true, doc: "phx-click event name"
  attr :param, :string, required: true, doc: "key for phx-value-<param>"
  attr :label, :string, required: true, doc: "aria-label for the group"

  attr :size, :string,
    default: "sm",
    values: ~w(sm md),
    doc: "sm adds btn-sm; md leaves the button full size"

  attr :icon_only, :boolean,
    default: false,
    doc: "square buttons whose label moves to aria-label and a tooltip"

  slot :option, required: true do
    attr :value, :any, required: true
    attr :label, :string, required: true
    attr :icon, :string
  end

  def segmented_control(assigns) do
    ~H"""
    <div class="join" id={@id} role="group" aria-label={@label}>
      <%= for option <- @option do %>
        <%= if @icon_only do %>
          <div class="tooltip tooltip-bottom" data-tip={option.label}>
            <.segment
              option={option}
              selected?={selected?(option, @value)}
              event={@event}
              param={@param}
              size={@size}
              icon_only={@icon_only}
            />
          </div>
        <% else %>
          <.segment
            option={option}
            selected?={selected?(option, @value)}
            event={@event}
            param={@param}
            size={@size}
            icon_only={@icon_only}
          />
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :option, :map, required: true
  attr :selected?, :boolean, required: true
  attr :event, :string, required: true
  attr :param, :string, required: true
  attr :size, :string, required: true
  attr :icon_only, :boolean, required: true

  defp segment(assigns) do
    assigns = assign(assigns, :icon_name, Map.get(assigns.option, :icon))

    ~H"""
    <button
      type="button"
      class={[
        "btn join-item",
        @size == "sm" && "btn-sm",
        @icon_only && "btn-square",
        !@icon_only && "gap-1.5",
        @selected? && "btn-primary",
        !@selected? && "dark:hover:bg-base-300"
      ]}
      phx-click={@event}
      aria-label={@icon_only && @option.label}
      aria-pressed={to_string(@selected?)}
      {%{"phx-value-#{@param}" => to_string(@option.value)}}
    >
      <.icon :if={@icon_name} name={@icon_name} class="w-4 h-4" />
      <%= unless @icon_only do %>
        {@option.label}
      <% end %>
    </button>
    """
  end

  defp selected?(option, value), do: to_string(option.value) == to_string(value)
end
