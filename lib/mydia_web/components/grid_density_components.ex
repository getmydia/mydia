defmodule MydiaWeb.GridDensityComponents do
  @moduledoc """
  A shared poster-grid density control for Discover and the Libraries grid.

  The class strings below are written out in full on purpose. Tailwind v4
  scans source text for class names (`assets/css/app.css` declares
  `@source "../../lib/mydia_web"`), so a class built by interpolation such as
  `"grid-cols-\#{n}"` is never generated and the grid silently keeps whatever
  columns it had. Any new level must be added here as complete literals.

  Two LiveViews use this module, so it is deliberately not imported in
  `html_helpers`; the project reserves global imports for components with
  three or more consumers.
  """

  use Phoenix.Component

  import MydiaWeb.CoreComponents, only: [icon: 1]

  @default "comfortable"

  @classes %{
    "comfortable" => "grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6",
    "compact" => "grid-cols-3 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-7 xl:grid-cols-8",
    "dense" => "grid-cols-4 sm:grid-cols-6 md:grid-cols-8 lg:grid-cols-10 xl:grid-cols-12"
  }

  @levels [
    {"comfortable", "Comfortable", "hero-squares-2x2"},
    {"compact", "Compact", "hero-squares-plus"},
    {"dense", "Dense", "hero-view-columns"}
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
    <div class="join" id={@id}>
      <button
        :for={{value, label, icon_name} <- @levels}
        type="button"
        class={[
          "btn btn-sm join-item",
          @density == value && "btn-primary",
          @density != value && "btn-ghost"
        ]}
        phx-click="set_grid_density"
        phx-value-density={value}
        title={label}
      >
        <.icon name={icon_name} class="w-5 h-5" />
        <span class="hidden sm:inline ml-1">{label}</span>
      </button>
    </div>
    """
  end
end
