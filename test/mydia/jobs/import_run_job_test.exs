defmodule Mydia.Jobs.ImportRunJobTest do
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library
  alias Mydia.Jobs.ImportRun, as: ImportRunJob

  setup do
    dir = Path.join(System.tmp_dir!(), "import_run_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "Season 01"))

    for ep <- 1..3 do
      path =
        Path.join([dir, "Season 01", "Bluey.S01E0#{ep}.mkv"])

      File.write!(path, "x")
    end

    on_exit(fn -> File.rm_rf!(dir) end)

    library_path = library_path_fixture(%{path: dir, type: "series"})
    user = user_fixture()

    {:ok, run} =
      Library.create_import_run(%{
        library_path_id: library_path.id,
        user_id: user.id,
        mode: :review
      })

    {:ok, dir: dir, library_path: library_path, run: run}
  end

  describe "phase 1: scanning" do
    test "commits a media_file row for every discovered file", %{run: run, library_path: lp} do
      assert :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      files = Library.list_media_files(library_path_id: lp.id)
      assert length(files) == 3
    end

    test "records the discovered count on the run", %{run: run} do
      :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      assert Library.get_import_run(run.id).files_discovered == 3
    end

    test "is idempotent, so a resumed run creates no duplicates", %{run: run, library_path: lp} do
      :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))
      :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      assert length(Library.list_media_files(library_path_id: lp.id)) == 3
    end

    test "stops when a stop was requested", %{run: run} do
      {:ok, _} = Library.request_import_run_stop(Library.get_import_run(run.id))

      assert :stopped = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))
    end
  end

  describe "list_unmatched_media_file_paths/2" do
    test "returns files with no candidate and no parent", %{run: run, library_path: lp} do
      :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      assert length(Library.list_unmatched_media_file_paths(lp.id, 100)) == 3
    end

    test "excludes a file that already carries a candidate", %{run: run, library_path: lp} do
      :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      [{file_id, _path} | _] = Library.list_unmatched_media_file_paths(lp.id, 100)

      {:ok, _} =
        Library.upsert_match_candidate(%{media_file_id: file_id, rank: 0, attempts: 1})

      assert length(Library.list_unmatched_media_file_paths(lp.id, 100)) == 2
    end
  end
end
