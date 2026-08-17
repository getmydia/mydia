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

  test "lists every unresolved file with its candidate", %{lp: lp} do
    rows = Library.list_inbox_files(library_path_id: lp.id)

    assert length(rows) == 3
    assert Enum.all?(rows, &Map.has_key?(&1, :media_file))
  end

  test "excludes a file once it has been linked", %{lp: lp, confident: confident} do
    # Explicitly a movie: library_path_fixture/0 defaults to type "movies", and
    # MediaFile.changeset validates that the item type matches the library type.
    item = media_item_fixture(%{type: "movie"})
    {:ok, _} = Library.update_media_file(confident, %{media_item_id: item.id})

    assert length(Library.list_inbox_files(library_path_id: lp.id)) == 2
  end

  test "filters to unidentified files", %{lp: lp, unidentified: unidentified} do
    rows = Library.list_inbox_files(library_path_id: lp.id, filter: :unidentified)

    assert [row] = rows
    assert row.media_file.id == unidentified.id
  end

  test "filters to low confidence matches", %{lp: lp, unsure: unsure} do
    rows = Library.list_inbox_files(library_path_id: lp.id, filter: :low_confidence)

    assert [row] = rows
    assert row.media_file.id == unsure.id
  end

  test "orders titled candidates alphabetically with untitled (unidentified) ones last", %{
    lp: lp,
    confident: confident,
    unsure: unsure,
    unidentified: unidentified
  } do
    # `unidentified`'s candidate carries no title (see setup: file_ingest.ex's
    # record_failure/2 never sets one for a failed match either). SQLite sorts
    # NULL first in ASC; PostgreSQL sorts NULL last. Plain `asc: c.title` would
    # therefore put the untitled row first on SQLite and last on PostgreSQL --
    # the same data, a different shelf position, depending on which database
    # is running. `asc_nulls_last` pins it last on both.
    rows = Library.list_inbox_files(library_path_id: lp.id)

    assert Enum.map(rows, & &1.media_file.id) == [confident.id, unsure.id, unidentified.id]
  end

  test "paginates", %{lp: lp} do
    assert length(Library.list_inbox_files(library_path_id: lp.id, limit: 2)) == 2
    assert length(Library.list_inbox_files(library_path_id: lp.id, limit: 2, offset: 2)) == 1
  end

  test "counts without loading", %{lp: lp} do
    assert Library.count_inbox_files(library_path_id: lp.id) == 3
    assert Library.count_inbox_files(library_path_id: lp.id, filter: :unidentified) == 1
  end

  test "counts and lists across every library when no library_path_id is given", %{lp: lp} do
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

    all_ids = Library.list_inbox_files() |> Enum.map(& &1.media_file.id)
    assert other_file.id in all_ids
    assert length(all_ids) == 4
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

  describe "list_unmatched_media_file_paths/2" do
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
end
