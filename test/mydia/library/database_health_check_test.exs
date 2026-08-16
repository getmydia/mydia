defmodule Mydia.Library.DatabaseHealthCheckTest do
  use Mydia.DataCase

  alias Mydia.Library.DatabaseHealthCheck
  alias Mydia.Library.MediaFile
  alias Mydia.Settings.LibraryPath

  describe "count_orphaned_files/0" do
    test "returns 0 when no media files exist" do
      assert DatabaseHealthCheck.count_orphaned_files() == 0
    end

    test "returns 0 when all files in standard libraries have parent associations" do
      library_path = create_library_path(:movies)
      media_item = insert(:media_item, type: "movie")

      insert_media_file(library_path, media_item_id: media_item.id)

      assert DatabaseHealthCheck.count_orphaned_files() == 0
    end

    test "counts orphaned files in movies library" do
      library_path = create_library_path(:movies)

      # Insert orphaned file (no media_item_id, no episode_id)
      insert_media_file(library_path)

      assert DatabaseHealthCheck.count_orphaned_files() == 1
    end

    test "counts orphaned files in series library" do
      library_path = create_library_path(:series)

      insert_media_file(library_path)
      insert_media_file(library_path)

      assert DatabaseHealthCheck.count_orphaned_files() == 2
    end

    test "counts orphaned files in mixed library" do
      library_path = create_library_path(:mixed)

      insert_media_file(library_path)

      assert DatabaseHealthCheck.count_orphaned_files() == 1
    end

    # count_orphaned_files/0 filters on an explicit allow-list of "standard"
    # library types. The specialized types it used to exclude (music, books,
    # adult) are gone, so every surviving type must now be counted. Reading the
    # list off the schema means adding a library type later fails here rather
    # than silently dropping its orphans from the health check.
    test "counts orphans in every library type the schema allows" do
      types = Ecto.Enum.values(LibraryPath, :type)

      for type <- types do
        create_library_path(type) |> insert_media_file()
      end

      assert DatabaseHealthCheck.count_orphaned_files() == length(types)
    end

    # The repair this count triggers is a rescan, and a rescan only walks
    # monitored paths, so an orphan under an unmonitored one would be reported
    # on every boot forever. Library paths converted off the removed music,
    # books and adult types land here: :mixed and unmonitored.
    test "ignores orphans under an unmonitored library path" do
      create_library_path(:mixed, monitored: false) |> insert_media_file()

      assert DatabaseHealthCheck.count_orphaned_files() == 0
    end

    test "counts orphans only under the monitored path when both exist" do
      create_library_path(:movies) |> insert_media_file()
      create_library_path(:mixed, monitored: false) |> insert_media_file()

      assert DatabaseHealthCheck.count_orphaned_files() == 1
    end

    test "counts files with episode_id as not orphaned" do
      library_path = create_library_path(:series)
      tv_show = insert(:tv_show)
      episode = insert(:episode, media_item: tv_show)

      insert_media_file(library_path, episode_id: episode.id)

      assert DatabaseHealthCheck.count_orphaned_files() == 0
    end

    test "handles mixed libraries with some orphaned and some associated files" do
      library_path = create_library_path(:mixed)
      media_item = insert(:media_item, type: "movie")

      # Two orphaned files
      insert_media_file(library_path)
      insert_media_file(library_path)

      # One associated file
      insert_media_file(library_path, media_item_id: media_item.id)

      assert DatabaseHealthCheck.count_orphaned_files() == 2
    end
  end

  describe "count_files_missing_library_path/0" do
    test "returns 0 when no media files exist" do
      assert DatabaseHealthCheck.count_files_missing_library_path() == 0
    end

    test "returns 0 when all files have library_path_id" do
      library_path = create_library_path(:movies)

      insert_media_file(library_path)

      assert DatabaseHealthCheck.count_files_missing_library_path() == 0
    end

    test "counts files with relative_path but missing library_path_id" do
      # Directly insert a malformed media file record
      Repo.insert!(%MediaFile{
        relative_path: "some/path.mkv",
        library_path_id: nil,
        size: 1_000_000_000
      })

      assert DatabaseHealthCheck.count_files_missing_library_path() == 1
    end
  end

  describe "detect_issues/0" do
    test "returns zero counts when no issues exist" do
      assert %{
               orphaned_files: 0,
               missing_library_path: 0,
               total_issues: 0
             } = DatabaseHealthCheck.detect_issues()
    end

    test "aggregates all issue types correctly" do
      library_path = create_library_path(:movies)

      # Three orphaned files
      insert_media_file(library_path)
      insert_media_file(library_path)
      insert_media_file(library_path)

      # One file missing library_path
      Repo.insert!(%MediaFile{
        relative_path: "orphaned/path.mkv",
        library_path_id: nil,
        size: 1_000_000_000
      })

      issues = DatabaseHealthCheck.detect_issues()

      assert issues.orphaned_files == 3
      assert issues.missing_library_path == 1
      assert issues.total_issues == 4
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

      library_path = create_library_path(:movies)
      insert_media_file(library_path)

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

  defp create_library_path(type, opts \\ []) do
    path = "/test/#{type}/#{System.unique_integer([:positive])}"

    {:ok, library_path} =
      %LibraryPath{}
      |> LibraryPath.changeset(%{
        path: path,
        type: type,
        monitored: Keyword.get(opts, :monitored, true)
      })
      |> Repo.insert()

    library_path
  end

  defp insert_media_file(library_path, opts \\ []) do
    attrs = %{
      relative_path: "file_#{System.unique_integer([:positive])}.mkv",
      library_path_id: library_path.id,
      size: 1_000_000_000
    }

    attrs =
      if Keyword.has_key?(opts, :media_item_id) do
        Map.put(attrs, :media_item_id, Keyword.get(opts, :media_item_id))
      else
        attrs
      end

    attrs =
      if Keyword.has_key?(opts, :episode_id) do
        Map.put(attrs, :episode_id, Keyword.get(opts, :episode_id))
      else
        attrs
      end

    # Use scan_changeset to allow orphaned files
    {:ok, media_file} =
      %MediaFile{}
      |> MediaFile.scan_changeset(attrs)
      |> Repo.insert()

    media_file
  end
end
