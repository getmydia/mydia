defmodule Mydia.Jobs.ImportRunCreatesImportGroupsTest do
  @moduledoc """
  Regression coverage for the whole-branch review's Critical 1: nothing in
  production ever called `ImportGroups.upsert_for_library/2` except the
  one-time backfill migration
  (`priv/repo/migrations/20260817143638_backfill_import_groups.exs`). Every
  real import run wrote `MatchCandidate` rows exactly as before and never
  touched `import_groups`, so the review page -- which reads only
  `import_groups` -- showed "Nothing to review" no matter how large the
  inbox grew, on a fresh install permanently.

  Deliberately drives the whole coordinator through `perform/1` (the actual
  Oban entry point), not `run_scan_phase/2` and `run_match_phase/2` called
  by hand the way most other coordinator tests do. Calling the phases
  directly is exactly what let this gap ship unnoticed: every per-phase test
  already passed, because the phases themselves were never the problem --
  the missing call between them and `finish/2` was.
  """
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MetadataStub
  import Mydia.SettingsFixtures

  alias Mydia.ImportGroups
  alias Mydia.Jobs.ImportRun, as: ImportRunJob
  alias Mydia.Library
  alias Mydia.MetadataStubProvider

  setup :setup_metadata_stub

  defp library_with(type, files) do
    dir =
      Path.join(System.tmp_dir!(), "import_groups_e2e_#{System.unique_integer([:positive])}")

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

  test "a real scan + match run through Jobs.ImportRun populates import_groups for the newly matched files" do
    title = MetadataStubProvider.movie_title()
    lp = library_with("movies", ["#{title} (1999).mkv"])

    {:ok, run} =
      Library.create_import_run(%{
        library_path_id: lp.id,
        user_id: user_fixture().id,
        # Review mode: the match phase caches the relay's candidate instead
        # of linking it, so the file stays unresolved and is exactly what
        # ImportGroups.upsert_for_library/2 groups -- an unattended run
        # would link a confident movie match immediately, leaving nothing
        # unresolved to prove the grouping step ran at all.
        mode: :review
      })

    assert :ok = perform!(run)
    assert Library.get_import_run(run.id).status == :done

    # This is the review page's own read path (ImportGroups.page/2 is what
    # MydiaWeb.ImportMediaLive.Index.load_groups/1 calls), not a raw query
    # against import_groups -- the gap this test guards against is specifically
    # that page returning nothing.
    {groups, cursor} = ImportGroups.page(lp.id)

    assert [group] = groups
    assert cursor == nil
    assert group.file_count == 1
    assert group.unresolved_count == 1
    assert group.import_run_id == run.id
    assert group.suggested_title == title
    assert group.provider_id != nil
  end

  test "a stopped run leaves import_groups untouched" do
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

    {groups, _cursor} = ImportGroups.page(lp.id)
    assert groups == []
  end

  test "a second run over the same library refreshes groups instead of duplicating them" do
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

    {groups, _cursor} = ImportGroups.page(lp.id)

    # Still one group -- upsert_for_library/2 recomputes the existing row by
    # its cluster key rather than inserting a second one -- but stamped with
    # the run that most recently touched it.
    assert [group] = groups
    assert group.import_run_id == second_run.id
  end
end
