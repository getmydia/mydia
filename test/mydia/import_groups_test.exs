defmodule Mydia.ImportGroupsTest do
  use Mydia.DataCase, async: true

  import Mydia.SettingsFixtures

  alias Mydia.ImportGroups
  alias Mydia.Library.ImportGroup
  alias Mydia.Repo

  defp group(library_path, attrs) do
    base = %{
      library_path_id: library_path.id,
      anchor_path: attrs[:anchor_path] || "Show",
      cluster_key: attrs[:cluster_key] || "show",
      status: "pending"
    }

    %ImportGroup{}
    |> ImportGroup.changeset(Map.merge(base, Map.new(attrs)))
    |> Repo.insert!()
  end

  describe "band/1" do
    test "ready when every member matched at or above the threshold" do
      assert ImportGroups.band(%ImportGroup{provider_id: "1", min_confidence: 0.95}) == :ready
      assert ImportGroups.band(%ImportGroup{provider_id: "1", min_confidence: 0.85}) == :ready
    end

    test "needs attention below the threshold" do
      assert ImportGroups.band(%ImportGroup{provider_id: "1", min_confidence: 0.70}) ==
               :needs_attention
    end

    test "no match when no member resolved a provider" do
      assert ImportGroups.band(%ImportGroup{provider_id: nil, min_confidence: nil}) == :no_match
    end

    test "member disagreement forces needs attention regardless of confidence" do
      g = %ImportGroup{provider_id: "1", min_confidence: 1.0, evidence: %{"disagreement" => true}}
      assert ImportGroups.band(g) == :needs_attention
    end
  end

  describe "band_counts/1" do
    test "counts each band" do
      lp = library_path_fixture(%{type: "series"})

      group(lp, cluster_key: "a", provider_id: "1", min_confidence: 1.0)
      group(lp, cluster_key: "b", provider_id: "1", min_confidence: 0.95)
      group(lp, cluster_key: "c", provider_id: "1", min_confidence: 0.70)
      group(lp, cluster_key: "d", provider_id: nil, min_confidence: nil)

      assert %{ready: 2, needs_attention: 1, no_match: 1, total: 4} =
               ImportGroups.band_counts(lp.id)
    end

    test "ignores groups that are not pending" do
      lp = library_path_fixture(%{type: "series"})
      group(lp, cluster_key: "a", provider_id: "1", min_confidence: 1.0, status: "applied")

      assert %{total: 0} = ImportGroups.band_counts(lp.id)
    end
  end

  describe "page/2" do
    test "pages by keyset on file_count descending and never repeats a row" do
      lp = library_path_fixture(%{type: "series"})

      for n <- 1..5 do
        group(lp, cluster_key: "k#{n}", file_count: n, provider_id: "1", min_confidence: 1.0)
      end

      {first, cursor} = ImportGroups.page(lp.id, limit: 2)
      assert Enum.map(first, & &1.file_count) == [5, 4]
      assert cursor

      {second, cursor2} = ImportGroups.page(lp.id, limit: 2, after: cursor)
      assert Enum.map(second, & &1.file_count) == [3, 2]

      {third, nil} = ImportGroups.page(lp.id, limit: 2, after: cursor2)
      assert Enum.map(third, & &1.file_count) == [1]
    end

    test "breaks file_count ties by id ascending without repeating or skipping rows" do
      lp = library_path_fixture(%{type: "series"})

      tied_a =
        group(lp, cluster_key: "tied-a", file_count: 3, provider_id: "1", min_confidence: 1.0)

      tied_b =
        group(lp, cluster_key: "tied-b", file_count: 3, provider_id: "1", min_confidence: 1.0)

      group(lp, cluster_key: "lowest", file_count: 2, provider_id: "1", min_confidence: 1.0)

      [first_tied, second_tied] = Enum.sort_by([tied_a, tied_b], & &1.id)

      {first_page, cursor} = ImportGroups.page(lp.id, limit: 1)
      assert Enum.map(first_page, & &1.cluster_key) == [first_tied.cluster_key]

      {second_page, cursor2} = ImportGroups.page(lp.id, limit: 1, after: cursor)
      assert Enum.map(second_page, & &1.cluster_key) == [second_tied.cluster_key]

      {third_page, nil} = ImportGroups.page(lp.id, limit: 1, after: cursor2)
      assert Enum.map(third_page, & &1.cluster_key) == ["lowest"]
    end

    test "filters by band" do
      lp = library_path_fixture(%{type: "series"})
      group(lp, cluster_key: "hi", file_count: 9, provider_id: "1", min_confidence: 1.0)
      group(lp, cluster_key: "lo", file_count: 8, provider_id: "1", min_confidence: 0.7)

      {ready, _} = ImportGroups.page(lp.id, band: :ready)
      assert Enum.map(ready, & &1.cluster_key) == ["hi"]
    end

    test "filters by search text on the anchor path" do
      lp = library_path_fixture(%{type: "series"})
      group(lp, cluster_key: "a", anchor_path: "Cornemuse (1999)", file_count: 2)
      group(lp, cluster_key: "b", anchor_path: "Pin-Pon (1996)", file_count: 1)

      {hits, _} = ImportGroups.page(lp.id, q: "corne")
      assert Enum.map(hits, & &1.cluster_key) == ["a"]
    end

    test "matches a literal percent in the search text without it acting as a wildcard" do
      lp = library_path_fixture(%{type: "series"})
      group(lp, cluster_key: "pct", anchor_path: "100% Wolf (2020)", file_count: 2)
      group(lp, cluster_key: "no_pct", anchor_path: "1002 Dalmatians (2000)", file_count: 1)

      {hits, _} = ImportGroups.page(lp.id, q: "100%")
      assert Enum.map(hits, & &1.cluster_key) == ["pct"]
    end
  end
end
