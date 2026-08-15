defmodule MydiaWeb.Components.GridDensityToggleTest do
  @moduledoc """
  The class map must return complete literal strings. Tailwind v4 scans source
  text, so a class assembled by interpolation is never generated and the grid
  silently keeps its previous columns.
  """

  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MydiaWeb.GridDensityComponents

  test "comfortable keeps the columns the grids used before the toggle existed" do
    assert GridDensityComponents.grid_columns_class("comfortable") ==
             "grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6"
  end

  test "compact and dense each return a distinct complete class string" do
    compact = GridDensityComponents.grid_columns_class("compact")
    dense = GridDensityComponents.grid_columns_class("dense")

    assert compact == "grid-cols-3 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-7 xl:grid-cols-8"
    assert dense == "grid-cols-4 sm:grid-cols-6 md:grid-cols-8 lg:grid-cols-10 xl:grid-cols-12"
    refute compact == dense
  end

  test "an unknown density falls back to comfortable" do
    assert GridDensityComponents.grid_columns_class("tiny") ==
             GridDensityComponents.grid_columns_class("comfortable")
  end

  test "the toggle renders one button per level, marking the active one" do
    html =
      render_component(&GridDensityComponents.grid_density_toggle/1,
        density: "compact",
        id: "library-density-toggle"
      )

    assert html =~ ~s(id="library-density-toggle")
    assert html =~ ~s(phx-value-density="comfortable")
    assert html =~ ~s(phx-value-density="compact")
    assert html =~ ~s(phx-value-density="dense")
    assert html =~ "set_grid_density"
    assert html =~ "btn-primary"
  end
end
