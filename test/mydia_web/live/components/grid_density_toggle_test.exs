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

  test "every button carries an accessible name and an explicit pressed state" do
    html =
      render_component(&GridDensityComponents.grid_density_toggle/1,
        density: "compact",
        id: "library-density-toggle"
      )

    buttons =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("button")

    # Removing the visible labels removes each button's accessible name, so
    # aria-label has to carry it instead.
    assert LazyHTML.attribute(buttons, "aria-label") == ["Comfortable", "Compact", "Dense"]

    # btn-primary alone is invisible to a screen reader. These must be the
    # literal strings: HEEx renders aria-pressed={true} as a bare attribute
    # and drops it entirely for false, so the component needs to_string/1.
    assert LazyHTML.attribute(buttons, "aria-pressed") == ["false", "true", "false"]
  end

  test "the buttons render no visible text label" do
    html =
      render_component(&GridDensityComponents.grid_density_toggle/1,
        density: "compact",
        id: "library-density-toggle"
      )

    # Checked as text content, not as a substring of the raw HTML: the level
    # names still appear inside aria-label and data-tip, so `refute html =~
    # "Compact"` would fail even on a correct implementation.
    text =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("button")
      |> LazyHTML.text()
      |> String.trim()

    assert text == ""
  end
end
