defmodule Mydia.Jobs.LibraryScannerImportGroupsTest do
  @moduledoc """
  A scheduled scan writes `MatchCandidate` rows, but the `/import` inbox renders
  `ImportGroup` rows, and nothing built the second from the first unless a human
  started an import run. That is why a library could hold hundreds of matched
  orphans while `/import` said "Nothing to review".

  `upsert_for_library/2` is idempotent and preserves human decisions, so the
  scan can simply call it. The one thing it must not do is run while an import
  run is in flight: `write_group/4` does not strip `:import_run_id` from an
  existing row, so a rebuild with no run id would detach that run's own groups
  from it mid-run.
  """
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.ImportGroups
  alias Mydia.Jobs.LibraryScanner
  alias Mydia.Library
  alias Mydia.Library.MatchCandidate
  alias Mydia.Repo

  defp orphan_with_candidate(library_path, opts) do
    file =
      orphaned_media_file_fixture(%{
        library_path_id: library_path.id,
        relative_path: Keyword.fetch!(opts, :relative_path)
      })

    {:ok, _candidate} =
      Library.upsert_match_candidate(%{
        media_file_id: file.id,
        rank: 0,
        provider_type: "tmdb",
        provider_id: Keyword.fetch!(opts, :provider_id),
        title: Keyword.fetch!(opts, :title),
        year: 1999,
        media_type: "movie",
        confidence: Keyword.get(opts, :confidence, 0.95)
      })

    file
  end

  # `ImportGroup.changeset/2` refuses a `min_confidence` outside [0.0, 1.0]
  # via `validate_number/3`, and every real write path
  # (`Library.upsert_match_candidate/1`) runs `MatchCandidate.changeset/2`,
  # which enforces that same range on `confidence` before a row can ever be
  # written. So the only way to get an out-of-range value into the table at
  # all is to skip the module's own changeset, which is what this does: it
  # builds the insert with `Ecto.Changeset.change/2` directly instead of
  # `MatchCandidate.changeset/2`.
  defp orphan_with_out_of_range_confidence(library_path, opts) do
    file =
      orphaned_media_file_fixture(%{
        library_path_id: library_path.id,
        relative_path: Keyword.fetch!(opts, :relative_path)
      })

    %MatchCandidate{}
    |> Ecto.Changeset.change(%{
      media_file_id: file.id,
      rank: 0,
      provider_type: "tmdb",
      provider_id: Keyword.fetch!(opts, :provider_id),
      title: Keyword.fetch!(opts, :title),
      year: 1999,
      media_type: "movie",
      confidence: 5.0
    })
    |> Repo.insert!()

    file
  end

  test "an exception while rebuilding groups is caught and does not crash the scan" do
    # This is not a reproduction of the real failure mode described in the
    # code review finding (a genuine unique-constraint collision from a
    # rebuild racing a freshly started import run's own upsert on the same
    # cluster_key). That race needs two processes interleaved between
    # write_group/4's existence check and its insert, which is not
    # reproducible deterministically against the sandboxed test connection
    # (both sides would serialize onto the same connection and the race
    # window would never open).
    #
    # Instead this forces `ImportGroup.changeset/2`'s existing
    # `validate_number(:min_confidence, ...)` to fail by smuggling an
    # out-of-range confidence into `write_group/4`'s attrs (see
    # `orphan_with_out_of_range_confidence/2`). An invalid changeset makes
    # `Repo.insert_or_update/1` return `{:error, changeset}` without ever
    # touching the database, which is the exact same shape write_group/4's
    # hard match `{:ok, group} = Repo.insert_or_update()` fails on for a real
    # unique-constraint collision: both raise a MatchError from that one
    # line. So while the trigger is artificial, the exception this test
    # proves gets caught is the same MatchError the real race produces.
    library_path = library_path_fixture(%{type: "movies"})

    orphan_with_out_of_range_confidence(library_path,
      relative_path: "Broken (2000)/broken.2000.mkv",
      provider_id: "1",
      title: "Broken"
    )

    assert LibraryScanner.rebuild_import_groups(library_path) == :error
    assert ImportGroups.count_pending() == 0
  end

  test "a scan rebuild makes matched orphans visible as groups" do
    library_path = library_path_fixture(%{type: "movies"})

    orphan_with_candidate(library_path,
      relative_path: "The Matrix (1999)/The.Matrix.1999.mkv",
      provider_id: "603",
      title: "The Matrix"
    )

    assert ImportGroups.count_pending() == 0

    assert {:ok, %{groups: groups}} = LibraryScanner.rebuild_import_groups(library_path)
    assert groups >= 1
    assert ImportGroups.count_pending() > 0
  end

  test "an orphan with no candidate at all still gets a group" do
    # The left join in unresolved_base/1 is what makes this work. A file the
    # matcher has never resolved is exactly the file an operator most needs to
    # see, so it must not be filtered out for lacking a candidate.
    library_path = library_path_fixture(%{type: "movies"})

    orphaned_media_file_fixture(%{
      library_path_id: library_path.id,
      relative_path: "Unknown Thing/unknown.thing.mkv"
    })

    assert {:ok, %{groups: groups}} = LibraryScanner.rebuild_import_groups(library_path)
    assert groups >= 1
  end

  test "the rebuild is skipped while an import run is active" do
    library_path = library_path_fixture(%{type: "movies"})

    orphan_with_candidate(library_path,
      relative_path: "Heat (1995)/heat.1995.mkv",
      provider_id: "949",
      title: "Heat"
    )

    {:ok, _run} =
      Library.create_import_run(%{library_path_id: library_path.id, mode: :review})

    assert LibraryScanner.rebuild_import_groups(library_path) == :skipped
  end

  test "rebuilding twice is idempotent and does not duplicate groups" do
    library_path = library_path_fixture(%{type: "movies"})

    orphan_with_candidate(library_path,
      relative_path: "Alien (1979)/alien.1979.mkv",
      provider_id: "348",
      title: "Alien"
    )

    assert {:ok, %{groups: first}} = LibraryScanner.rebuild_import_groups(library_path)
    assert {:ok, %{groups: second}} = LibraryScanner.rebuild_import_groups(library_path)

    assert first == second
    assert ImportGroups.count_pending() == first
  end
end
