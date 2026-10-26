defmodule MydiaWeb.ProfileLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  @doc """
  A preference select whose blank option means "inherit the server default".

  Every add-option preference is tri-state: a value, or absent meaning inherit.
  A checkbox cannot express the third state, so even the boolean fields are
  selects.
  """
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :options, :list, required: true, doc: "list of {value, label} tuples"

  def inherit_select(assigns) do
    ~H"""
    <div>
      <label class="block">
        <span class="label mb-1 text-sm font-medium text-base-content/80">{@label}</span>
        <select name={@name} class="select select-bordered select-sm w-full">
          <option value="">{gettext("Use server default")}</option>
          <option
            :for={{value, label} <- @options}
            value={to_string(value)}
            selected={@value == value}
          >
            {label}
          </option>
        </select>
      </label>
    </div>
    """
  end

  @doc """
  A radio group of theme cards for one slot (light or dark).

  Each preview carries `data-theme`, so daisyUI scopes that theme's colours to
  the card and it renders as the real theme, not a swatch approximation.
  """
  attr :id, :string, required: true
  attr :slot, :string, required: true, values: ~w(light dark)
  attr :title, :string, required: true
  attr :themes, :list, required: true
  attr :selected, :string, required: true, doc: "id of the theme in this slot"
  attr :in_use, :boolean, default: false

  def theme_gallery(assigns) do
    ~H"""
    <fieldset id={@id} class="mt-6">
      <legend class="mb-3 flex items-center gap-2 text-sm font-medium">
        {@title}
        <span :if={@in_use} data-role="in-use" class="badge badge-primary badge-sm">{gettext("In use")}</span>
      </legend>
      <div class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
        <label :for={theme <- @themes} id={"#{@id}-#{theme.id}"} class="group cursor-pointer">
          <input
            type="radio"
            name={"#{@slot}_theme"}
            value={theme.id}
            checked={theme.id == @selected}
            phx-click="update_theme_slot"
            phx-value-slot={@slot}
            phx-value-theme={theme.id}
            class="peer sr-only"
          />
          <div class="rounded-box ring-offset-2 ring-offset-base-100 transition duration-150 group-hover:-translate-y-0.5 peer-checked:ring-2 peer-checked:ring-primary peer-focus-visible:ring-2 peer-focus-visible:ring-base-content/40">
            <div
              data-theme={theme.id}
              class="rounded-box border border-base-300 bg-base-200 p-2 text-base-content"
            >
              <div class="flex gap-2">
                <div class="aspect-[2/3] w-8 shrink-0 rounded bg-base-300"></div>
                <div class="flex-1 space-y-1.5">
                  <div class="h-2 w-3/4 rounded bg-base-content/70"></div>
                  <div class="h-2 w-1/2 rounded bg-base-content/30"></div>
                  <div class="flex gap-1 pt-0.5">
                    <span class="h-2 w-3 rounded-full bg-info"></span>
                    <span class="h-2 w-3 rounded-full bg-success"></span>
                    <span class="h-2 w-3 rounded-full bg-warning"></span>
                    <span class="h-2 w-3 rounded-full bg-error"></span>
                  </div>
                  <div class="h-3 w-10 rounded bg-primary"></div>
                </div>
              </div>
            </div>
          </div>
          <span class="mt-2 flex items-center gap-1 text-sm">
            <.icon
              :if={theme.id == @selected}
              name="hero-check-circle-mini"
              class="size-4 text-primary"
            />
            {theme.label}
          </span>
        </label>
      </div>
    </fieldset>
    """
  end

  # Glyph corner per radius id: each preset's --radius-box from app.css.
  # `theme` gets an icon instead, since var(--radius-box) would draw the
  # active preset's corner rather than the theme's own.
  defp radius_options do
    [
      {"theme", gettext("Theme"), nil},
      {"sharp", gettext("Sharp"), "0.25rem"},
      {"soft", gettext("Soft"), "0.5rem"},
      {"round", gettext("Round"), "0.75rem"}
    ]
  end

  @doc """
  A joined row of radio buttons for the corner roundness, one per
  `Mydia.Accounts.Themes.radii/0` id. Each shows a corner drawn at that
  preset's `--radius-box`.
  Stacks vertically below `sm`, where four labelled buttons do not fit a phone.
  """
  attr :id, :string, required: true
  attr :selected, :string, required: true, doc: "the current radius id"

  def radius_picker(assigns) do
    assigns = assign(assigns, :options, radius_options())

    ~H"""
    <div
      id={@id}
      class="join join-vertical w-full sm:join-horizontal sm:w-auto"
      role="radiogroup"
      aria-label={gettext("Corners")}
    >
      <label
        :for={{value, label, corner} <- @options}
        class={["btn join-item", value == @selected && "btn-primary"]}
      >
        <input
          id={"theme-radius-#{value}"}
          type="radio"
          name="theme_radius"
          value={value}
          checked={value == @selected}
          phx-click="set_theme_radius"
          phx-value-radius={value}
          class="sr-only"
        />
        <.icon :if={is_nil(corner)} name="hero-swatch" class="size-4" />
        <span
          :if={corner}
          class="inline-block size-4 border-t-2 border-l-2 border-current"
          style={"border-top-left-radius: #{corner}"}
          aria-hidden="true"
        ></span>
        {label}
      </label>
    </div>
    """
  end
end
