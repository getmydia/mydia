defmodule MydiaWeb.DiscoverLive.RecommendationsLookupTest do
  @moduledoc """
  Covers the widened `show_details` lookup.

  A recommendation is not part of the current grid page, so resolving the click
  against `items` alone silently drops it and the modal never swaps. That failure
  is invisible in the UI, which is why it gets a direct test.

  No rendering test here on purpose: see the header of library_picker_test.exs.
  """

  use ExUnit.Case, async: true

  alias MydiaWeb.DiscoverLive.Index

  defp result(provider_id), do: %{provider_id: provider_id, title: "Title #{provider_id}"}

  test "finds an item on the current grid page" do
    items = [result("1"), result("2")]

    assert %{provider_id: "2"} = Index.find_selectable_item(items, [], "2")
  end

  test "finds an item that exists only in the recommendations rail" do
    recommendations = [result("101")]

    assert %{provider_id: "101"} = Index.find_selectable_item([], recommendations, "101")
  end

  test "prefers the grid item when both lists carry the id" do
    grid = %{provider_id: "5", title: "From grid"}
    rail = %{provider_id: "5", title: "From rail"}

    assert %{title: "From grid"} = Index.find_selectable_item([grid], [rail], "5")
  end

  test "returns nil for an unknown id" do
    assert is_nil(Index.find_selectable_item([result("1")], [result("101")], "999"))
  end
end
