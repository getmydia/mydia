defmodule Mydia.Library.DatabaseHealthCheckTest do
  use Mydia.DataCase

  import Mydia.MediaFixtures

  alias Mydia.Library.DatabaseHealthCheck
  alias Mydia.Library.MediaFile

  describe "count_files_missing_library_path/0" do
    test "returns 0 when no media files exist" do
      assert DatabaseHealthCheck.count_files_missing_library_path() == 0
    end

    test "returns 0 when all files have library_path_id" do
      media_file_fixture()

      assert DatabaseHealthCheck.count_files_missing_library_path() == 0
    end

    test "counts files with relative_path but missing library_path_id" do
      # Directly insert a malformed media file record. It still needs a
      # parent -- `media_files_has_parent` is a DB-level CHECK constraint
      # that applies regardless of library_path_id, so this only isolates the
      # missing-library-path condition, not a parentless one.
      movie = media_item_fixture(%{type: "movie"})

      Repo.insert!(%MediaFile{
        relative_path: "some/path.mkv",
        library_path_id: nil,
        media_item_id: movie.id,
        size: 1_000_000_000
      })

      assert DatabaseHealthCheck.count_files_missing_library_path() == 1
    end
  end

  describe "detect_issues/0" do
    test "returns zero counts when no issues exist" do
      assert %{missing_library_path: 0, total_issues: 0} = DatabaseHealthCheck.detect_issues()
    end

    test "aggregates the missing-library-path issue count" do
      movie = media_item_fixture(%{type: "movie"})

      # Two files missing library_path
      Repo.insert!(%MediaFile{
        relative_path: "orphaned/path-1.mkv",
        library_path_id: nil,
        media_item_id: movie.id,
        size: 1_000_000_000
      })

      Repo.insert!(%MediaFile{
        relative_path: "orphaned/path-2.mkv",
        library_path_id: nil,
        media_item_id: movie.id,
        size: 1_000_000_000
      })

      issues = DatabaseHealthCheck.detect_issues()

      assert issues.missing_library_path == 2
      assert issues.total_issues == 2
    end
  end

  describe "run/0" do
    test "returns :ok when auto-repair is disabled" do
      # Auto-repair is disabled in test.exs by default
      assert DatabaseHealthCheck.run() == :ok
    end

    test "returns :ok when no issues detected (with auto-repair temporarily enabled)" do
      # Temporarily enable auto-repair for this test
      original = Application.get_env(:mydia, :database_auto_repair, true)
      Application.put_env(:mydia, :database_auto_repair, true)

      on_exit(fn ->
        Application.put_env(:mydia, :database_auto_repair, original)
      end)

      assert DatabaseHealthCheck.run() == :ok
    end

    test "returns :ok and does not crash on exception" do
      # The run/0 function should always return :ok to not block startup
      assert DatabaseHealthCheck.run() == :ok
    end
  end

  describe "run/0 boot repair scan" do
    # This scan runs on every boot, and self-hosted restarts cluster because
    # everyone pulls a new image at the same time, so it must be jittered rather
    # than fired immediately at the shared metadata relay. It regressed to an
    # immediate insert once and nothing covered it. The manual Scan Library path
    # is pinned as "available" in test/mydia/library_scan_trigger_test.exs; this
    # is the other half of that contract.
    test "queues the repair scan for the future rather than running it immediately" do
      enable_auto_repair!(threshold: 1)
      movie = media_item_fixture(%{type: "movie"})

      Repo.insert!(%MediaFile{
        relative_path: "missing-library-path.mkv",
        library_path_id: nil,
        media_item_id: movie.id,
        size: 1_000_000_000
      })

      assert DatabaseHealthCheck.run() == :ok

      job = Repo.one!(from(j in Oban.Job, where: j.worker == "Mydia.Jobs.LibraryScanner"))

      assert job.args == %{}
      assert job.state == "scheduled"
      assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) == :gt
      assert DateTime.diff(job.scheduled_at, DateTime.utc_now(), :second) <= 1800
    end
  end

  ## Private Helpers

  defp enable_auto_repair!(opts) do
    original_enabled = Application.get_env(:mydia, :database_auto_repair)
    original_threshold = Application.get_env(:mydia, :database_auto_repair_threshold)

    Application.put_env(:mydia, :database_auto_repair, true)
    Application.put_env(:mydia, :database_auto_repair_threshold, Keyword.fetch!(opts, :threshold))

    on_exit(fn ->
      restore_app_env(:database_auto_repair, original_enabled)
      restore_app_env(:database_auto_repair_threshold, original_threshold)
    end)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:mydia, key)
  defp restore_app_env(key, value), do: Application.put_env(:mydia, key, value)
end
