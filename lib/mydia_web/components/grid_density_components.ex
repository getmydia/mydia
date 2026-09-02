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

  import MydiaWeb.SegmentedControl, only: [segmented_control: 1]

  @default "comfortable"

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
end
