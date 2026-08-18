defmodule Mydia.ImportGroupsTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.ImportGroups
  alias Mydia.Library.ImportGroup
  alias Mydia.Library.MatchCandidate
  alias Mydia.Library.MediaFile
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
        %MatchCandidate{}
        |> MatchCandidate.changeset(
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

    test "stamps every file even when the unresolved set crosses the chunk and buffer boundaries",
         %{library_path: lp} do
      # Deliberately just over @upsert_chunk / @id_bind_chunk (both 500): the
      # keyset walk sees a full 500-row chunk followed by a short remainder
      # chunk, and stamp_members/2's buffer flushes once at the 500 cap and
      # once more via the trailing Enum.each for what's left. A regular
      # fixture-based insert at this count would be far too slow, so this
      # bulk-inserts directly and skips the changesets.
      count = 520
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      file_rows =
        for n <- 1..count do
          %{
            id: Ecto.UUID.generate(),
            library_path_id: lp.id,
            relative_path:
              "Bulk Show (2020)/Season 01/Bulk Show - S01E#{String.pad_leading(Integer.to_string(n), 4, "0")}.mkv",
            media_item_id: nil,
            episode_id: nil,
            trashed_at: nil,
            inserted_at: now,
            updated_at: now
          }
        end

      {^count, _} = Repo.insert_all(MediaFile, file_rows)

      candidate_rows =
        for %{id: file_id} <- file_rows do
          %{
            id: Ecto.UUID.generate(),
            media_file_id: file_id,
            rank: 0,
            provider_id: "1",
            provider_type: "tvdb",
            title: "Bulk Show",
            confidence: 1.0,
            inserted_at: now,
            updated_at: now
          }
        end

      {^count, _} = Repo.insert_all(MatchCandidate, candidate_rows)

      assert {:ok, %{groups: 1, files: ^count}} = ImportGroups.upsert_for_library(lp)

      group = Repo.one!(ImportGroup)
      assert group.file_count == count

      stamped_count =
        Repo.aggregate(from(f in MediaFile, where: f.import_group_id == ^group.id), :count)

      assert stamped_count == count
    end

    # The negative case for write_group/4's local-group special-casing (see
    # ImportGroups.create_local_show/1's rescan test): a provider-*matched*
    # group is deliberately NOT protected the same way, because a match can
    # legitimately improve on a later pass. This is the same shape a real
    # rematch produces -- the matcher overwrites the rank-0 candidate in
    # place -- not a new candidate row.
    test "a rescan still refreshes a provider-matched group's provider_id", %{library_path: lp} do
      file =
        unresolved_file(
          lp,
          "Show (2023)/Season 01/ep1.mkv",
          provider_id: "111",
          provider_type: "tvdb",
          confidence: 0.9
        )

      {:ok, _} = ImportGroups.upsert_for_library(lp)
      group = Repo.one!(ImportGroup)
      assert group.provider_id == "111"

      MatchCandidate
      |> Repo.get_by!(media_file_id: file.id, rank: 0)
      |> MatchCandidate.changeset(%{provider_id: "222"})
      |> Repo.update!()

      {:ok, _} = ImportGroups.upsert_for_library(lp)

      assert Repo.reload!(group).provider_id == "222"
    end
  end

  describe "create_local_show/1" do
    test "builds a media item from the folder name and links the members" do
      lp = library_path_fixture(%{type: "series", path: "/media/Series"})

      for n <- 1..3 do
        file =
          orphaned_media_file_fixture(%{
            library_path_id: lp.id,
            relative_path: "Les mots de Passe-Partout (2023)/Season 01/ep#{n}.mkv"
          })

        %MatchCandidate{}
        |> MatchCandidate.changeset(%{
          media_file_id: file.id,
          rank: 0,
          last_error: "no_match",
          parsed_info: %{"season" => 1, "episodes" => [n]}
        })
        |> Repo.insert!()
      end

      {:ok, _} = ImportGroups.upsert_for_library(lp)
      group = Repo.one!(ImportGroup)
      assert ImportGroups.band(group) == :no_match

      assert {:ok, item} = ImportGroups.create_local_show(group.id)

      assert item.title == "Les mots de Passe-Partout"
      assert item.year == 2023
      assert item.type == "tv_show"
      # A local show has no provider identity at all. MediaItem has no
      # provider_type column; metadata_source is an Ecto.Enum limited to
      # [:tvdb, :tmdb], so "not from a provider" is expressed as nil.
      assert item.metadata_source == nil
      assert item.tmdb_id == nil
      assert item.tvdb_id == nil

      # The files are linked to real episodes here, not queued for the worker,
      # because there is no provider match for FileIngest to enrich from.
      episodes = Repo.all(from e in Mydia.Media.Episode, where: e.media_item_id == ^item.id)
      assert length(episodes) == 3
      assert Enum.sort(Enum.map(episodes, & &1.episode_number)) == [1, 2, 3]
      assert Enum.all?(episodes, &(&1.season_number == 1))

      assert Repo.aggregate(
               from(f in MediaFile, where: is_nil(f.episode_id)),
               :count
             ) == 0

      reloaded_group = Repo.reload!(group)
      assert reloaded_group.status == "applied"
      assert reloaded_group.unresolved_count == 0
      # The synthetic provider identity is what makes a second call refuse
      # instead of building a duplicate show -- see "a second call refuses..."
      # below.
      assert reloaded_group.provider_type == "local"
      assert reloaded_group.provider_id == "local-" <> item.id
    end

    test "a second call refuses rather than creating a duplicate show" do
      lp = library_path_fixture(%{type: "series", path: "/media/Series"})

      file =
        orphaned_media_file_fixture(%{
          library_path_id: lp.id,
          relative_path: "Les mots de Passe-Partout (2023)/Season 01/ep1.mkv"
        })

      %MatchCandidate{}
      |> MatchCandidate.changeset(%{
        media_file_id: file.id,
        rank: 0,
        last_error: "no_match",
        parsed_info: %{"season" => 1, "episodes" => [1]}
      })
      |> Repo.insert!()

      {:ok, _} = ImportGroups.upsert_for_library(lp)
      group = Repo.one!(ImportGroup)

      assert {:ok, _item} = ImportGroups.create_local_show(group.id)
      # Same failure whether it is a genuine double-click (no `phx-disable-with`
      # guards the button) or a retry after a crash partway through the first
      # call's link loop -- there is nothing left the second call could do
      # differently, since every member the first call could link is already
      # detached from the group.
      assert {:error, :already_created} = ImportGroups.create_local_show(group.id)

      assert Repo.aggregate(Mydia.Media.MediaItem, :count) == 1
    end

    test "refuses a group that already has a provider match" do
      lp = library_path_fixture(%{type: "series", path: "/media/Series"})

      file =
        orphaned_media_file_fixture(%{
          library_path_id: lp.id,
          relative_path: "Show/Season 01/a.mkv"
        })

      %MatchCandidate{}
      |> MatchCandidate.changeset(%{
        media_file_id: file.id,
        rank: 0,
        provider_id: "1",
        confidence: 1.0
      })
      |> Repo.insert!()

      {:ok, _} = ImportGroups.upsert_for_library(lp)
      group = Repo.one!(ImportGroup)

      assert {:error, :already_matched} = ImportGroups.create_local_show(group.id)
    end

    test "leaves an unnumbered member orphaned and keeps the group pending and visible" do
      lp = library_path_fixture(%{type: "series", path: "/media/Series"})

      numbered_files =
        for n <- 1..2 do
          file =
            orphaned_media_file_fixture(%{
              library_path_id: lp.id,
              relative_path: "L'univers des Coucou (2023)/Season 01/ep#{n}.mkv"
            })

          %MatchCandidate{}
          |> MatchCandidate.changeset(%{
            media_file_id: file.id,
            rank: 0,
            last_error: "no_match",
            parsed_info: %{"season" => 1, "episodes" => [n]}
          })
          |> Repo.insert!()

          file
        end

      unnumbered_file =
        orphaned_media_file_fixture(%{
          library_path_id: lp.id,
          relative_path: "L'univers des Coucou (2023)/Season 01/bonus.mkv"
        })

      %MatchCandidate{}
      |> MatchCandidate.changeset(%{
        media_file_id: unnumbered_file.id,
        rank: 0,
        last_error: "no_match",
        parsed_info: %{}
      })
      |> Repo.insert!()

      {:ok, _} = ImportGroups.upsert_for_library(lp)
      group = Repo.one!(ImportGroup)

      assert {:ok, item} = ImportGroups.create_local_show(group.id)

      episodes = Repo.all(from e in Mydia.Media.Episode, where: e.media_item_id == ^item.id)
      assert length(episodes) == 2

      for file <- numbered_files do
        assert Repo.reload!(file).episode_id
      end

      reloaded_unnumbered = Repo.reload!(unnumbered_file)
      assert reloaded_unnumbered.episode_id == nil
      assert reloaded_unnumbered.media_item_id == nil

      # Staying "pending" (not "applied") is what keeps this group -- and the
      # orphaned file inside it -- reachable at all: write_group/4 preserves
      # an existing group's status across a rescan, and this folder produces
      # the same cluster_key every time, so an "applied" group here would
      # vanish from the review page, the band counts, and the nav badge for
      # good, with no worker able to hand it back (there is no provider match
      # to retry against).
      reloaded_group = Repo.reload!(group)
      assert reloaded_group.status == "pending"
      assert reloaded_group.unresolved_count == 1

      {page, _cursor} = ImportGroups.page(lp.id)
      assert Enum.any?(page, &(&1.id == group.id))

      assert ImportGroups.count_pending() == 1
    end

    test "a rescan preserves the local-show marker, so a second call still refuses" do
      lp = library_path_fixture(%{type: "series", path: "/media/Series"})

      numbered_file =
        orphaned_media_file_fixture(%{
          library_path_id: lp.id,
          relative_path: "L'univers des Coucou (2023)/Season 01/ep1.mkv"
        })

      %MatchCandidate{}
      |> MatchCandidate.changeset(%{
        media_file_id: numbered_file.id,
        rank: 0,
        last_error: "no_match",
        parsed_info: %{"season" => 1, "episodes" => [1]}
      })
      |> Repo.insert!()

      # The leftover, unnumbered member is what makes this a genuine test: it
      # stays orphaned after create_local_show/1, so it is still genuinely
      # unresolved and gets picked up again by the rescan below.
      unnumbered_file =
        orphaned_media_file_fixture(%{
          library_path_id: lp.id,
          relative_path: "L'univers des Coucou (2023)/Season 01/bonus.mkv"
        })

      %MatchCandidate{}
      |> MatchCandidate.changeset(%{
        media_file_id: unnumbered_file.id,
        rank: 0,
        last_error: "no_match",
        parsed_info: %{}
      })
      |> Repo.insert!()

      {:ok, _} = ImportGroups.upsert_for_library(lp)
      group = Repo.one!(ImportGroup)

      assert {:ok, _item} = ImportGroups.create_local_show(group.id)

      after_create = Repo.reload!(group)
      assert after_create.provider_type == "local"
      assert after_create.provider_id

      # Simulates a routine rescan of the same library path -- a scheduled
      # scan, or a user starting another import run over it.
      {:ok, _} = ImportGroups.upsert_for_library(lp)

      after_rescan = Repo.reload!(group)
      assert after_rescan.provider_type == "local"
      assert after_rescan.provider_id == after_create.provider_id
      assert after_rescan.status == "pending"

      # The end-to-end proof that the hole is closed, not just that a column
      # survived: the guard the marker exists for must still work after a
      # rescan folds the leftover file back into a fresh rollup.
      assert {:error, :already_created} = ImportGroups.create_local_show(group.id)
      assert Repo.aggregate(Mydia.Media.MediaItem, :count) == 1
    end
  end
end
