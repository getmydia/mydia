defmodule Mydia.Library.DatabaseHealthCheckTest do
  use Mydia.DataCase

  alias Mydia.Library.DatabaseHealthCheck
  alias Mydia.Library.MediaFile
  alias Mydia.Settings.LibraryPath

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
               missing_library_path: 0,
               total_issues: 0
             } = DatabaseHealthCheck.detect_issues()
    end

    test "aggregates all issue types correctly" do
      # One file missing library_path
      Repo.insert!(%MediaFile{
        relative_path: "orphaned/path.mkv",
        library_path_id: nil,
        size: 1_000_000_000
      })

      issues = DatabaseHealthCheck.detect_issues()

      assert issues.missing_library_path == 1
      assert issues.total_issues == 1
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

  ## Private Helpers

  defp create_library_path(type) do
    path =
      case type do
        :movies -> "/test/movies/#{System.unique_integer([:positive])}"
        :series -> "/test/series/#{System.unique_integer([:positive])}"
        :mixed -> "/test/mixed/#{System.unique_integer([:positive])}"
        :music -> "/test/music/#{System.unique_integer([:positive])}"
        :books -> "/test/books/#{System.unique_integer([:positive])}"
        :adult -> "/test/adult/#{System.unique_integer([:positive])}"
      end

    {:ok, library_path} =
      %LibraryPath{}
      |> LibraryPath.changeset(%{
        path: path,
        type: type,
        monitored: true
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
