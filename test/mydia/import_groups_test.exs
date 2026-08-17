defmodule Mydia.ImportGroupsTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
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

  describe "upsert_for_library/2" do
    setup do
      lp = library_path_fixture(%{type: "series", path: "/media/Series"})
      {:ok, library_path: lp}
    end

    defp unresolved_file(lp, relative_path, candidate_attrs) do
      file =
        orphaned_media_file_fixture(%{
          library_path_id: lp.id,
          relative_path: relative_path
        })

      if candidate_attrs do
        %Mydia.Library.MatchCandidate{}
        |> Mydia.Library.MatchCandidate.changeset(
          Map.merge(%{media_file_id: file.id, rank: 0}, Map.new(candidate_attrs))
        )
        |> Repo.insert!()
      end

      file
    end

    test "collapses a season tree into one group", %{library_path: lp} do
      for n <- 1..3 do
        unresolved_file(
          lp,
          "Cornemuse (1999)/Season 02/Cornemuse (1999) - S02E0#{n}.mkv",
          provider_id: "277262",
          provider_type: "tvdb",
          title: "Cornemuse",
          confidence: 1.0
        )
      end

      assert {:ok, %{groups: 1, files: 3}} = ImportGroups.upsert_for_library(lp)

      group = Repo.one!(ImportGroup)
      assert group.anchor_path == "Cornemuse (1999)"
      assert group.cluster_key == "cornemuse"
      assert group.file_count == 3
      assert group.unresolved_count == 3
      assert group.provider_id == "277262"
      assert group.min_confidence == 1.0
      assert ImportGroup.season_span(group) == [2]
      assert ImportGroups.band(group) == :ready
    end

    test "merges sibling seasons of one show into a single group", %{library_path: lp} do
      unresolved_file(lp, "Passe-Partout (2018)/Season 01/a.mkv",
        provider_id: "9",
        confidence: 0.95
      )

      unresolved_file(lp, "Passe-Partout (2018)/Season 02/b.mkv",
        provider_id: "9",
        confidence: 0.90
      )

      assert {:ok, %{groups: 1, files: 2}} = ImportGroups.upsert_for_library(lp)

      group = Repo.one!(ImportGroup)
      assert group.file_count == 2
      assert group.min_confidence == 0.90
      assert ImportGroup.season_span(group) == [1, 2]
    end

    test "a group whose members disagree on provider is not ready", %{library_path: lp} do
      unresolved_file(lp, "Show/Season 01/a.mkv", provider_id: "1", confidence: 1.0)
      unresolved_file(lp, "Show/Season 01/b.mkv", provider_id: "2", confidence: 1.0)

      assert {:ok, %{groups: 1}} = ImportGroups.upsert_for_library(lp)

      group = Repo.one!(ImportGroup)
      assert group.evidence["disagreement"] == true
      assert group.min_confidence == nil
      assert ImportGroups.band(group) == :needs_attention
    end

    test "files with no provider match land in a no_match group", %{library_path: lp} do
      unresolved_file(lp, "Les mots de Passe-Partout (2023)/Season 01/a.mkv",
        provider_id: nil,
        last_error: "no_match"
      )

      assert {:ok, %{groups: 1}} = ImportGroups.upsert_for_library(lp)

      group = Repo.one!(ImportGroup)
      assert group.provider_id == nil
      assert group.evidence["kind"] == "none"
      assert ImportGroups.band(group) == :no_match
    end

    test "is idempotent and keeps a decided group's status", %{library_path: lp} do
      unresolved_file(lp, "Show/Season 01/a.mkv", provider_id: "1", confidence: 1.0)

      assert {:ok, %{groups: 1}} = ImportGroups.upsert_for_library(lp)
      Repo.update_all(ImportGroup, set: [status: "ignored"])

      assert {:ok, %{groups: 1}} = ImportGroups.upsert_for_library(lp)
      assert Repo.one!(ImportGroup).status == "ignored"
      assert Repo.aggregate(ImportGroup, :count) == 1
    end

    test "stamps import_group_id onto every member file", %{library_path: lp} do
      file = unresolved_file(lp, "Show/Season 01/a.mkv", provider_id: "1", confidence: 1.0)

      assert {:ok, _} = ImportGroups.upsert_for_library(lp)

      group = Repo.one!(ImportGroup)
      assert Repo.reload!(file).import_group_id == group.id
    end
  end
end
