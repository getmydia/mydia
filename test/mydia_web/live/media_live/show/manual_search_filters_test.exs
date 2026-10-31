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
    assert LazyHTML.attribute(chip, "title") == [Enum.join(names, ", ")]
  end

  test "other dimensions keep joining every value" do
    html =
      render_component(&ManualSearchFilters.active_chips/1, source_filters: ["REMUX", "BluRay"])

    assert html =~ "REMUX, BluRay"
  end
end
