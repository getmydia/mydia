defmodule MydiaWeb.DownloadsLive.SortingTest do
  use ExUnit.Case, async: true

  alias MydiaWeb.DownloadsLive.Sorting

  defp keys(view), do: view |> Sorting.options() |> Enum.map(&elem(&1, 0))

  test "Active offers queue sorts, not ratio" do
    assert "eta_asc" in keys(:active)
    refute "ratio_desc" in keys(:active)
  end

  test "Imported offers ratio and imported-date sorts, not ETA" do
    assert "ratio_desc" in keys(:imported)
    assert "imported_desc" in keys(:imported)
    refute "eta_asc" in keys(:imported)
  end

  test "All offers both sets, each key once" do
    assert "eta_asc" in keys(:all)
    assert "ratio_desc" in keys(:all)
    assert keys(:all) == Enum.uniq(keys(:all))
    assert Enum.sort(keys(:all)) == Enum.sort(Sorting.allowed_fields())
  end
end
