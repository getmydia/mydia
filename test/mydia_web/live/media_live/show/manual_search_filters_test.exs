defmodule MydiaWeb.MediaLive.Show.ManualSearchFiltersTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MydiaWeb.MediaLive.Show.ManualSearchFilters

  defp indexer_chip(indexers) do
    render_component(&ManualSearchFilters.active_chips/1, indexer_filters: indexers)
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#manual-search-chip-indexer")
  end

  test "up to two indexers are named in full" do
    chip = indexer_chip(["Ashvale Commons", "Saltmarsh Mirror"])

    assert LazyHTML.text(chip) =~ "Ashvale Commons, Saltmarsh Mirror"
  end

  test "three or more indexers name two and count the rest, listing all in the title" do
    names = ["Ashvale Commons", "Brinewater Exchange", "Saltmarsh Mirror", "Westmarch Lantern"]
    chip = indexer_chip(names)

    assert LazyHTML.text(chip) =~ "Ashvale Commons, Brinewater Exchange +2 more"
    refute LazyHTML.text(chip) =~ "Westmarch Lantern"
    assert LazyHTML.attribute(chip, "title") == [Enum.join(names, ", ")]

    # The remove button names every indexer, not the capped label.
    assert chip |> LazyHTML.query("button") |> LazyHTML.attribute("aria-label") ==
             ["Remove filter: " <> Enum.join(names, ", ")]
  end

  test "exactly three indexers name two and count one" do
    names = ["Ashvale Commons", "Brinewater Exchange", "Saltmarsh Mirror"]
    chip = indexer_chip(names)

    assert LazyHTML.text(chip) =~ "Ashvale Commons, Brinewater Exchange +1 more"
    refute LazyHTML.text(chip) =~ "Saltmarsh Mirror"
    assert LazyHTML.attribute(chip, "title") == [Enum.join(names, ", ")]
  end

  test "other dimensions keep joining every value" do
    html =
      render_component(&ManualSearchFilters.active_chips/1, source_filters: ["REMUX", "BluRay"])

    assert html =~ "REMUX, BluRay"
  end

  describe "chip_bar/1" do
    test "shows at every breakpoint with a Filters button that opens the drawer" do
      doc =
        render_component(&ManualSearchFilters.chip_bar/1, quality_filters: ["1080p"])
        |> LazyHTML.from_fragment()

      [bar] = doc |> LazyHTML.query("#manual-search-chip-bar") |> Enum.to_list()
      refute bar |> LazyHTML.attribute("class") |> hd() =~ "lg:hidden"

      button = LazyHTML.query(doc, "#manual-search-filters-button")
      assert LazyHTML.attribute(button, "aria-controls") == ["manual-search-filter-sheet"]
      click = button |> LazyHTML.attribute("phx-click") |> hd()
      assert click =~ "#manual-search-filter-toggle"
      # Opening moves focus into the panel; the DOM puts the results between
      # the button and the panel.
      assert click =~ "focus_first"
      assert click =~ "#manual-search-filter-sheet"
      # Opening marks the button expanded and makes the results inert.
      assert click =~ "aria-expanded"
      assert click =~ "inert"
      assert click =~ "#manual-search-results-pane"
      assert LazyHTML.attribute(button, "aria-expanded") == ["false"]
      assert button |> LazyHTML.query(".badge") |> LazyHTML.text() =~ "1"
    end
  end

  describe "filter_panel/1" do
    defp panel_doc do
      render_component(&ManualSearchFilters.filter_panel/1, result_count: 3)
      |> LazyHTML.from_fragment()
    end

    test "is a daisyUI drawer side with an overlay bound to the toggle" do
      doc = panel_doc()

      assert [_] =
               doc |> LazyHTML.query(".drawer-side #manual-search-filter-sheet") |> Enum.to_list()

      assert doc
             |> LazyHTML.query(".drawer-side > label.drawer-overlay")
             |> LazyHTML.attribute("for") ==
               ["manual-search-filter-toggle"]

      assert [] = doc |> LazyHTML.query("#manual-search-filter-backdrop") |> Enum.to_list()
    end

    test "close and show-results controls dispatch to the toggle and return focus" do
      doc = panel_doc()

      for id <- ["#manual-search-filter-close", "#manual-search-show-results"] do
        click = doc |> LazyHTML.query(id) |> LazyHTML.attribute("phx-click") |> hd()
        assert click =~ "#manual-search-filter-toggle"
        assert click =~ "#manual-search-filters-button"
        assert click =~ "focus"
        assert click =~ "remove_attr"
        assert click =~ "inert"
      end

      # The overlay is a `<label for>`: the browser unchecks the toggle, so
      # its click must not dispatch another one, only undo the open state.
      overlay_click =
        doc
        |> LazyHTML.query(".drawer-overlay")
        |> LazyHTML.attribute("phx-click")
        |> hd()

      refute overlay_click =~ "dispatch"
      assert overlay_click =~ "remove_attr"
      assert overlay_click =~ "inert"
      assert overlay_click =~ "aria-expanded"
      assert overlay_click =~ "#manual-search-filters-button"

      assert doc |> LazyHTML.query("#manual-search-show-results") |> LazyHTML.text() =~
               "Show 3 results"
    end
  end
end
