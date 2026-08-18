defmodule Mydia.Library.InboxTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library

  setup do
    lp = library_path_fixture()

    confident = orphaned_media_file_fixture(%{library_path_id: lp.id})
    unsure = orphaned_media_file_fixture(%{library_path_id: lp.id})
    unidentified = orphaned_media_file_fixture(%{library_path_id: lp.id})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: confident.id,
        rank: 0,
        provider_type: "tmdb",
        provider_id: "1",
        title: "Confident",
        media_type: "movie",
        confidence: 0.95
      })

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: unsure.id,
        rank: 0,
        provider_type: "tmdb",
        provider_id: "2",
        title: "Unsure",
        media_type: "movie",
        confidence: 0.3
      })

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: unidentified.id,
        rank: 0,
        attempts: 1,
        last_error: "no_match"
      })

    {:ok, lp: lp, confident: confident, unsure: unsure, unidentified: unidentified}
  end

  test "counts every unresolved file", %{lp: lp} do
    assert Library.count_inbox_files(library_path_id: lp.id) == 3
  end

  test "excludes a file once it has been linked", %{lp: lp, confident: confident} do
    # Explicitly a movie: library_path_fixture/0 defaults to type "movies", and
    # MediaFile.changeset validates that the item type matches the library type.
    item = media_item_fixture(%{type: "movie"})
    {:ok, _} = Library.update_media_file(confident, %{media_item_id: item.id})

    assert Library.count_inbox_files(library_path_id: lp.id) == 2
  end

  test "counts without loading", %{lp: lp} do
    assert Library.count_inbox_files(library_path_id: lp.id) == 3
    assert Library.count_inbox_files(library_path_id: lp.id, filter: :unidentified) == 1
    assert Library.count_inbox_files(library_path_id: lp.id, filter: :low_confidence) == 1
  end

  test "counts across every library when no library_path_id is given", %{lp: lp} do
    other_lp = library_path_fixture()
    other_file = orphaned_media_file_fixture(%{library_path_id: other_lp.id})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: other_file.id,
        rank: 0,
        attempts: 1,
        last_error: "no_match"
      })

    # No :library_path_id at all -- the review inbox (Task 10) shows one
    # queue across every library, matching how the run control panel
    # already treats "the import run" as a single global thing rather than
    # one per library path. Scoping to `lp` alone must still stay at 3, so
    # this proves the default is "every path", not a silent no-op filter.
    assert Library.count_inbox_files(library_path_id: lp.id) == 3
    assert Library.count_inbox_files() == 4
    assert Library.count_inbox_files(filter: :unidentified) == 2
  end

  describe "apply_batch_match/3" do
    test "stamps a season without blanking the match already on the file", %{
      confident: confident
    } do
      assert {:ok, %{updated: 1, failed: 0}} = Library.apply_batch_match([confident.id], nil, 3)

      # The merge, not an overwrite: a season-only batch edit that dropped the
      # title and provider would silently turn an identified file back into an
      # unidentified one.
      assert [candidate] = Library.list_match_candidates(confident.id)
      assert candidate.title == "Confident"
      assert candidate.provider_id == "1"
      assert candidate.parsed_info["season"] == 3
    end

    test "applies a chosen match over whatever the file already had", %{unidentified: file} do
      match = %{provider_id: "9001", title: "Selected Show", type: "tv_show"}

      assert {:ok, %{updated: 1, failed: 0}} = Library.apply_batch_match([file.id], match, 2)

      assert [candidate] = Library.list_match_candidates(file.id)
      assert candidate.title == "Selected Show"
      assert candidate.provider_id == "9001"
      assert candidate.media_type == "tv_show"
      assert candidate.confidence == 1.0
      assert candidate.parsed_info["season"] == 2
      # The batch edit is a fresh start for the file, so the failure that put
      # it in the inbox is cleared rather than left contradicting the match.
      assert is_nil(candidate.last_error)
    end

    test "counts a file that no longer exists as failed instead of writing it", %{
      lp: lp,
      confident: confident
    } do
      gone = orphaned_media_file_fixture(%{library_path_id: lp.id})
      Mydia.Repo.delete!(gone)

      match = %{provider_id: "9001", title: "Selected Show", type: "tv_show"}

      # The write for a vanished file cannot succeed -- media_file_id is a
      # foreign key -- so the only question is whether the caller is told. It
      # must not be silently folded into the success count.
      assert {:ok, %{updated: 1, failed: 1}} =
               Library.apply_batch_match([confident.id, gone.id], match, nil)

      assert [candidate] = Library.list_match_candidates(confident.id)
      assert candidate.title == "Selected Show"
    end
  end

  describe "list_unmatched_media_file_paths/3" do
    test "after_id keyset-pages past files already seen", %{lp: lp, unidentified: unidentified} do
      extra = orphaned_media_file_fixture(%{library_path_id: lp.id})

      full_ids =
        Library.list_unmatched_media_file_paths(lp.id, 50) |> Enum.map(&elem(&1, 0))

      assert Enum.sort(full_ids) == Enum.sort([unidentified.id, extra.id])

      [first_id | rest_ids] = full_ids

      # Jobs.ImportRun's match loop threads the last id of a processed chunk
      # through as the next chunk's :after_id, so this pins the query never
      # re-scanning (or re-returning) a row an earlier chunk already handed
      # off, regardless of how a chunk of more than one row is split.
      after_first_ids =
        Library.list_unmatched_media_file_paths(lp.id, 50, after_id: first_id)
        |> Enum.map(&elem(&1, 0))

      refute first_id in after_first_ids
      assert after_first_ids == rest_ids
    end

    test "a file with only a rank-1 candidate is still eligible, not excluded or duplicated", %{
      lp: lp
    } do
      # Regression: the join here did not constrain rank, so a rank-1-only
      # candidate (no rank-0 row) matched the join and its non-nil id excluded
      # the file entirely, silently stranding it with no parent and no way to
      # be retried. And a file with *both* a rank-0 and a rank-1 candidate
      # would fan out into two rows from the unconstrained join. Cover both.
      rank1_only = orphaned_media_file_fixture(%{library_path_id: lp.id})

      {:ok, _} =
        Library.upsert_match_candidate(%{
          media_file_id: rank1_only.id,
          rank: 1,
          provider_type: "tmdb",
          provider_id: "42",
          title: "Second guess",
          media_type: "movie",
          confidence: 0.4
        })

      both_ranks = orphaned_media_file_fixture(%{library_path_id: lp.id})

      {:ok, _} =
        Library.upsert_match_candidate(%{
          media_file_id: both_ranks.id,
          rank: 0,
          attempts: 1,
          last_error: "no_match"
        })

      {:ok, _} =
        Library.upsert_match_candidate(%{
          media_file_id: both_ranks.id,
          rank: 1,
          provider_type: "tmdb",
          provider_id: "43",
          title: "Second guess",
          media_type: "movie",
          confidence: 0.4
        })

      results = Library.list_unmatched_media_file_paths(lp.id, 50)
      ids = Enum.map(results, &elem(&1, 0))

      assert rank1_only.id in ids
      assert both_ranks.id in ids
      assert Enum.count(ids, &(&1 == both_ranks.id)) == 1
    end

    test "logs the files it drops for having no resolvable location", %{lp: lp} do
      # A row with no relative_path resolves to a nil absolute path. The
      # rejection runs after the SQL LIMIT, so a chunk made only of these comes
      # back empty and Jobs.ImportRun reads that as "matching is finished" --
      # the files never get a candidate, never reach the inbox, and the run
      # still reports success. Written past the changeset because
      # scan_changeset requires the column; the rows this guards against
      # predate it.
      stranded = orphaned_media_file_fixture(%{library_path_id: lp.id})

      {1, _} =
        Mydia.Repo.update_all(
          from(f in Mydia.Library.MediaFile, where: f.id == ^stranded.id),
          set: [relative_path: nil]
        )

      # Not asserting the whole result is `[]`: the shared setup's
      # `unidentified` fixture also carries a failed (no-`provider_id`)
      # candidate with no `next_retry_at`, which is legitimately eligible
      # here (see `Library.list_unmatched_media_file_paths/2`'s moduledoc on
      # a NULL retry time meaning "eligible"). What this test pins is that
      # `stranded` specifically -- the one with no resolvable path -- never
      # comes back, and that its exclusion is logged.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          paths = Library.list_unmatched_media_file_paths(lp.id, 50)
          refute Enum.any?(paths, fn {id, _path} -> id == stranded.id end)
        end)

      assert log =~ stranded.id
    end
  end

  describe "count_files_without_parent_or_candidate/1" do
    test "does not count a file whose failure candidate is past its retry window", %{lp: lp} do
      file = orphaned_media_file_fixture(%{library_path_id: lp.id})

      past = DateTime.utc_now() |> DateTime.add(-300, :second) |> DateTime.truncate(:second)

      {:ok, _} =
        Library.upsert_match_candidate(%{
          media_file_id: file.id,
          rank: 0,
          attempts: 1,
          last_error: "no_match",
          next_retry_at: past
        })

      # This file is eligible for another match attempt --
      # list_unmatched_media_file_paths/3 selects it, asserted below -- but it
      # already satisfies FileIngest's progress contract: it has a rank-0
      # candidate. Retry-eligibility and contract-violation are different
      # conditions. This is the regression guard for conflating them: an
      # implementation that shared list_unmatched_media_file_paths/3's
      # time-sensitive predicate (as an earlier version of this function did)
      # wrongly counts this file the moment its backoff expires, regardless
      # of how long ago that candidate was actually written.
      assert Library.count_files_without_parent_or_candidate(lp.id) == 0

      # Confirms the fixture actually exercises the retry-eligible state this
      # test is about, not one the broader query would also have excluded.
      assert Enum.any?(Library.list_unmatched_media_file_paths(lp.id, 50), fn {id, _path} ->
               id == file.id
             end)
    end

    test "counts a file with no candidate row at all", %{lp: lp} do
      file = orphaned_media_file_fixture(%{library_path_id: lp.id})

      assert Library.count_files_without_parent_or_candidate(lp.id) == 1
      assert Library.list_file_ids_without_parent_or_candidate(lp.id, 5) == [file.id]
    end

    test "counts a file that has only a rank-1 candidate as a contract violation", %{lp: lp} do
      # Regression: the join here did not constrain rank, so a rank-1-only
      # candidate matched it and the file was wrongly reported as healthy --
      # it has no parent and no rank-0 candidate to retry, exactly the
      # condition this function exists to surface.
      file = orphaned_media_file_fixture(%{library_path_id: lp.id})

      {:ok, _} =
        Library.upsert_match_candidate(%{
          media_file_id: file.id,
          rank: 1,
          provider_type: "tmdb",
          provider_id: "42",
          title: "Second guess",
          media_type: "movie",
          confidence: 0.4
        })

      assert Library.count_files_without_parent_or_candidate(lp.id) == 1
      assert Library.list_file_ids_without_parent_or_candidate(lp.id, 5) == [file.id]
    end
  end
end
