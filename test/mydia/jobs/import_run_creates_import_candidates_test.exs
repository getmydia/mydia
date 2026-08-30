defmodule Mydia.Jobs.ImportRunCreatesImportCandidatesTest do
  @moduledoc """
  Regression coverage for the review page's read path after the candidate
  split.

  This file used to guard a materialization step
  (`ImportGroups.upsert_for_library/2`) that `Jobs.ImportRun` had to call
  once a run finished, because nothing else in production ever called it
  except a one-time backfill migration
  (`priv/repo/migrations/20260817143638_backfill_import_groups.exs`): every
  real import run wrote `MatchCandidate` rows and never touched
  `import_groups`, so the review page -- which read only `import_groups` --
  showed "Nothing to review" no matter how large the inbox grew, on a fresh
  install permanently.

  That materialization step is gone now. `run_scan_phase/2` and
  `run_match_phase/2` write durable `ImportCandidate` rows directly, and
  `Mydia.ImportCandidates.page/2` groups them at query time on every read --
  there is no separate rollup to keep in sync, so there is no analogous gap
  to leave unclosed. What this file still guards is the same underlying risk
  in its new shape: a real end-to-end run through `perform/1` has to leave
  something the review page's actual read path can show, not silently
  produce candidates a group query can't see.

  Deliberately drives the whole coordinator through `perform/1` (the actual
  Oban entry point), not `run_scan_phase/2` and `run_match_phase/2` called by
  hand the way most other coordinator tests do -- calling the phases directly
  is exactly what let the original gap ship unnoticed: every per-phase test
  already passed, because the phases themselves were never the problem, the
  missing call between them and the review page's read path was.
  """
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MetadataStub
  import Mydia.SettingsFixtures

  alias Mydia.ImportCandidates
  alias Mydia.Jobs.ImportRun, as: ImportRunJob
  alias Mydia.Library
  alias Mydia.MetadataStubProvider

  setup :setup_metadata_stub

  defp library_with(type, files) do
    dir =
      Path.join(System.tmp_dir!(), "import_candidates_e2e_#{System.unique_integer([:positive])}")

    Enum.each(files, fn relative ->
      full = Path.join(dir, relative)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, "x")
    end)

    on_exit(fn -> File.rm_rf!(dir) end)

    library_path_fixture(%{path: dir, type: type})
  end

  defp perform!(run) do
    ImportRunJob.perform(%Oban.Job{
      args: %{"import_run_id" => run.id},
      attempt: 1,
      max_attempts: 3
    })
  end

  test "a real scan + match run through Jobs.ImportRun leaves a reviewable candidate group" do
    title = MetadataStubProvider.movie_title()
    lp = library_with("movies", ["#{title} (1999).mkv"])

    {:ok, run} =
      Library.create_import_run(%{
        library_path_id: lp.id,
        user_id: user_fixture().id,
        # Review mode: the match phase caches the relay's match instead of
        # promoting it, so the candidate stays around for review -- exactly
        # what ImportCandidates.page/2 groups. An unattended run would
        # promote a confident movie match immediately, deleting the
        # candidate and leaving nothing behind to prove the review page's
        # read path works at all.
        mode: :review
      })

    assert :ok = perform!(run)
    assert Library.get_import_run(run.id).status == :done

    # This is the review page's own read path (ImportCandidates.page/2 is
    # what MydiaWeb.ImportMediaLive.Index.load_groups/1 calls), not a raw
    # query against import_candidates -- the gap this test guards against is
    # specifically that page returning nothing.
    {groups, cursor} = ImportCandidates.page(lp.id)

    assert [group] = groups
    assert cursor == nil
    assert group.file_count == 1
    assert group.suggested_title == title
    assert group.provider_id != nil
  end

  test "a stopped run leaves nothing to review" do
    title = MetadataStubProvider.movie_title()
    lp = library_with("movies", ["#{title} (1999).mkv"])

    {:ok, run} =
      Library.create_import_run(%{
        library_path_id: lp.id,
        user_id: user_fixture().id,
        mode: :review
      })

    {:ok, _} = Library.request_import_run_stop(run.id)

    assert :ok = perform!(run)
    assert Library.get_import_run(run.id).status == :stopped

    {groups, _cursor} = ImportCandidates.page(lp.id)
    assert groups == []
  end

  test "a second run over the same library does not duplicate the candidate group" do
    title = MetadataStubProvider.movie_title()
    lp = library_with("movies", ["#{title} (1999).mkv"])

    {:ok, first_run} =
      Library.create_import_run(%{
        library_path_id: lp.id,
        user_id: user_fixture().id,
        mode: :review
      })

    assert :ok = perform!(first_run)

    {:ok, second_run} =
      Library.create_import_run(%{
        library_path_id: lp.id,
        user_id: user_fixture().id,
        mode: :review
      })

    assert :ok = perform!(second_run)

    {groups, _cursor} = ImportCandidates.page(lp.id)

    # Still one group -- phase 1's upsert keyed on (library_path_id,
    # relative_path) revisits the same candidate row rather than creating a
    # second one, and phase 2 finds nothing outstanding to re-match once the
    # first run already recorded a match -- so the group is neither
    # duplicated nor disturbed by running the coordinator again.
    assert [group] = groups
    assert group.file_count == 1
  end
end
