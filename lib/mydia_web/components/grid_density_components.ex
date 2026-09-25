defmodule MydiaWeb.GridDensityComponents do
  @moduledoc """
  A shared poster-grid density control for Discover and the Libraries grid.

  The class strings below are written out in full on purpose. Tailwind v4
  scans source text for class names (`assets/css/app.css` declares
  `@source "../../lib/mydia_web"`), so a class built by interpolation such as
  `"grid-cols-\#{n}"` is never generated and the grid silently keeps whatever
  columns it had. Any new level must be added here as complete literals.

  The buttons are icon-only. `MydiaWeb.SegmentedControl` owns the accessible
  naming, the tooltip wrapper and the `join-item` placement that icon-only
  segments need; see its moduledoc for why each is shaped the way it is.

  Kept in step with `MydiaWeb.LibraryComponents.view_mode_toggle/1`, which is
  icon-only for the same reasons; the two sit side by side on the Libraries
  toolbar.

  Two LiveViews use this module, so it is deliberately not imported in
  `html_helpers`; the project reserves global imports for components with
  three or more consumers.
  """

  use Phoenix.Component

  import MydiaWeb.CoreComponents, only: [icon: 1]
  import MydiaWeb.SegmentedControl, only: [segmented_control: 1]

  @default "comfortable"

  # Each density has its own phone (unprefixed) column count. This is safe
  # because density is a per-browser setting (see
  # `MydiaWeb.Plugs.GridDensityCookie`): a phone only shows what was chosen
  # on that phone. Issue #700 was the account-wide version of this setting
  # pushing a desktop's Dense onto phones; at 3 or 4 columns the poster
  # fields menu is how a phone user trims card text.
  @classes %{
    "comfortable" => "grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6",
    "compact" => "grid-cols-3 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-7 xl:grid-cols-8",
    "dense" => "grid-cols-4 sm:grid-cols-6 md:grid-cols-8 lg:grid-cols-10 xl:grid-cols-12"
  }

  # A 1 → 3 → many progression. The labels used to carry the meaning; once
  # they are gone the icons have to, and the previous three sat on no common
  # scale. hero-squares-2x2 is deliberately absent: it is already the Grid
  # icon on view_mode_toggle three buttons to the left on the same toolbar,
  # and the Activity page's "All" tab.
  @levels [
    {"comfortable", "Comfortable", "hero-stop"},
    {"compact", "Compact", "hero-view-columns"},
    {"dense", "Dense", "hero-table-cells"}
  ]

  @values Enum.map(@levels, &elem(&1, 0))

  @doc "The density values, in toggle order."
  @spec levels() :: [String.t()]
  def levels, do: @values

  @doc "Whether `density` is one of `levels/0`."
  @spec valid?(term()) :: boolean()
  def valid?(density), do: density in @values

  @doc "The density used when a browser has not chosen one."
  @spec default() :: String.t()
  def default, do: @default

  @doc """
  Maps a density to its complete grid-column class string.

  Falls back to the default for any unrecognized value, so a preference row
  written by a different version of the app cannot break rendering.
  """
  @spec grid_columns_class(String.t() | nil) :: String.t()
  def grid_columns_class(density) do
    Map.get(@classes, density, @classes[@default])
  end

  @doc """
  Segmented control for choosing grid density.

  Mirrors `MydiaWeb.LibraryComponents.view_mode_toggle/1` so the two controls
  sit together on the Libraries toolbar without looking mismatched.
  """
  attr :density, :string, required: true
  attr :id, :string, required: true

  def grid_density_toggle(assigns) do
    assigns = assign(assigns, :levels, @levels)

    ~H"""
    <.segmented_control
      id={@id}
      value={@density}
      event="set_grid_density"
      param="density"
      label="Grid density"
      icon_only
      phx-hook="GridDensity"
      data-value={@density}
    >
      <:option
        :for={{value, label, icon_name} <- @levels}
        value={value}
        label={label}
        icon={icon_name}
      />
    </.segmented_control>
    """
  end

  @doc """
  The eye-icon dropdown that picks which parts of a library poster card render.

  Every change submits the whole checked set, so the handler never tracks
  individual toggles. The hidden empty `fields[]` makes "everything off"
  submit `[""]` instead of the key being omitted entirely, which
  `PosterFields.resolve/1` would otherwise read as "never set" (defaults)
  rather than "none".

  Uses daisyUI's `.filter` component rather than a hand-rolled `flex
  flex-wrap` row. `lib/mydia_web/components/README.md` measured the
  stylesheet Tailwind actually builds (not the stale vendored
  `daisyui.js`) and found 5.7.7 excludes checkboxes from `.filter`'s
  single-choice collapse trigger
  (`:has(:checked:not(.filter-reset, [type="checkbox"]))`), so a multi-select
  checkbox row stays fully visible once one is checked.
  `MydiaWeb.MediaLive.Show.SubtitleModal`'s language chips already rely on the
  same behaviour.
  """
  attr :id, :string, default: "poster-fields-menu"
  attr :fields, :list, required: true

  def poster_fields_menu(assigns) do
    assigns = assign(assigns, :catalog, Mydia.Accounts.PosterFields.catalog())

    ~H"""
    <div id={@id} class="dropdown dropdown-end">
      <div
        tabindex="0"
        role="button"
        class="btn btn-ghost btn-sm btn-square"
        aria-label="Poster display"
      >
        <.icon name="hero-eye" class="w-5 h-5" />
      </div>
      <div
        tabindex="0"
        class="dropdown-content z-30 mt-2 w-64 rounded-box bg-base-100 p-3 shadow-lg border border-base-300"
      >
        <p class="text-xs font-semibold text-base-content/70 mb-2">Show on posters</p>
        <form id="poster-fields-form" phx-change="set_poster_fields">
          <input type="hidden" name="fields[]" value="" />
          <div class="filter" role="group" aria-label="Poster fields">
            <input
              :for={{key, label} <- @catalog}
              type="checkbox"
              class="btn btn-xs"
              name="fields[]"
              value={key}
              aria-label={label}
              id={"poster-field-#{key}"}
              checked={key in @fields}
            />
          </div>
        </form>
        <button
          id="poster-fields-reset"
          type="button"
          phx-click="reset_poster_fields"
          class="btn btn-link btn-xs px-0 mt-2"
        >
          Reset to default
        </button>
      </div>
    </div>
    """
  end
end
