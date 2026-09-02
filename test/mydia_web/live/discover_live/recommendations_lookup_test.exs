defmodule MydiaWeb.DiscoverLive.RecommendationsLookupTest do
  @moduledoc """
  Covers the widened `show_details` lookup for Discover's two lists.

  A recommendation is not part of the current grid page, so resolving the click
  against `items` alone silently drops it and the dialog never swaps. That
  failure is invisible in the UI, which is why it gets a direct test.

  The lookup itself moved to `MydiaWeb.Live.Helpers.DetailModal` when the
  detail page became a third host; this file keeps Discover's two-list shape
  under test.

  No rendering test here on purpose: see the header of library_picker_test.exs.
  """

  use ExUnit.Case, async: true

  alias MydiaWeb.Live.Helpers.DetailModal

  defp result(provider_id), do: %{provider_id: provider_id, title: "Title #{provider_id}"}

  defp lookup(items, recommendations, id),
    do: DetailModal.find_selectable_item([items, recommendations], id)

  test "finds an item on the current grid page" do
    assert %{provider_id: "2"} = lookup([result("1"), result("2")], [], "2")
  end

  test "finds an item that exists only in the recommendations rail" do
    assert %{provider_id: "101"} = lookup([], [result("101")], "101")
  end

  test "prefers the grid item when both lists carry the id" do
    grid = %{provider_id: "5", title: "From grid"}
    rail = %{provider_id: "5", title: "From rail"}

    assert %{title: "From grid"} = lookup([grid], [rail], "5")
  end

  test "returns nil for an unknown id" do
    assert is_nil(lookup([result("1")], [result("101")], "999"))
  end
end
