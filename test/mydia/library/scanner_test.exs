defmodule Mydia.Library.ScannerTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.Scanner

  @moduletag :tmp_dir

  describe "scan/2" do
    test "scans directory and finds video files", %{tmp_dir: tmp_dir} do
      # Create test structure
      File.write!(Path.join(tmp_dir, "movie1.mkv"), "fake video content")
      File.write!(Path.join(tmp_dir, "movie2.mp4"), "fake video content")
      File.write!(Path.join(tmp_dir, "readme.txt"), "not a video")

      {:ok, result} = Scanner.scan(tmp_dir)

      assert length(result.files) == 2
      assert result.total_count == 2
      assert Enum.any?(result.files, &String.ends_with?(&1.path, "movie1.mkv"))
      assert Enum.any?(result.files, &String.ends_with?(&1.path, "movie2.mp4"))
    end

    test "extracts file metadata correctly", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "test.mkv")
      content = String.duplicate("x", 1024)
      File.write!(file_path, content)

      {:ok, result} = Scanner.scan(tmp_dir)

      assert [file] = result.files
      assert file.path == file_path
      assert file.size == 1024
      assert file.filename == "test.mkv"
      assert file.extension == ".mkv"
      assert file.directory == tmp_dir
      assert %DateTime{} = file.modified_at
    end

    test "scans subdirectories recursively by default", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "movies")
      File.mkdir_p!(subdir)

      File.write!(Path.join(tmp_dir, "root.mkv"), "video")
      File.write!(Path.join(subdir, "sub.mkv"), "video")

      {:ok, result} = Scanner.scan(tmp_dir)

      assert length(result.files) == 2
      assert Enum.any?(result.files, &String.ends_with?(&1.path, "root.mkv"))
      assert Enum.any?(result.files, &String.ends_with?(&1.path, "sub.mkv"))
    end

    test "does not scan subdirectories when recursive is false", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "movies")
      File.mkdir_p!(subdir)

      File.write!(Path.join(tmp_dir, "root.mkv"), "video")
      File.write!(Path.join(subdir, "sub.mkv"), "video")

      {:ok, result} = Scanner.scan(tmp_dir, recursive: false)

      assert length(result.files) == 1
      assert Enum.any?(result.files, &String.ends_with?(&1.path, "root.mkv"))
    end

    test "detects various video file extensions", %{tmp_dir: tmp_dir} do
      extensions = [".mkv", ".mp4", ".avi", ".mov", ".wmv", ".flv", ".webm"]

      for ext <- extensions do
        File.write!(Path.join(tmp_dir, "video#{ext}"), "content")
      end

      {:ok, result} = Scanner.scan(tmp_dir)

      assert length(result.files) == length(extensions)
    end

    test "ignores non-video files", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "movie.mkv"), "video")
      File.write!(Path.join(tmp_dir, "readme.txt"), "text")
      File.write!(Path.join(tmp_dir, "image.jpg"), "image")
      File.write!(Path.join(tmp_dir, "subtitle.srt"), "subtitle")

      {:ok, result} = Scanner.scan(tmp_dir)

      assert length(result.files) == 1
      assert result.files |> hd() |> Map.get(:path) |> String.ends_with?("movie.mkv")
    end

    test "handles custom video extensions", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "video.mkv"), "video")
      File.write!(Path.join(tmp_dir, "video.custom"), "video")

      {:ok, result} = Scanner.scan(tmp_dir, video_extensions: [".custom"])

      assert length(result.files) == 1
      assert result.files |> hd() |> Map.get(:path) |> String.ends_with?("video.custom")
    end

    test "returns error for non-existent directory" do
      assert {:error, :not_found} = Scanner.scan("/nonexistent/path")
    end

    test "returns error when path is not a directory", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "file.txt")
      File.write!(file_path, "content")

      assert {:error, :not_directory} = Scanner.scan(file_path)
    end

    test "follows symlinks to directories", %{tmp_dir: tmp_dir} do
      real_dir = Path.join(tmp_dir, "real")
      link_dir = Path.join(tmp_dir, "link")
      File.mkdir_p!(real_dir)

      File.write!(Path.join(real_dir, "movie.mkv"), "video")
      File.ln_s!(real_dir, link_dir)

      {:ok, result} = Scanner.scan(tmp_dir)

      # Should find the file through the symlink (and potentially the real path)
      assert length(result.files) >= 1
      assert Enum.any?(result.files, &String.contains?(&1.path, "movie.mkv"))
    end

    test "follows symlinks to files", %{tmp_dir: tmp_dir} do
      real_file = Path.join(tmp_dir, "real.mkv")
      link_file = Path.join(tmp_dir, "link.mkv")
      File.write!(real_file, "video")
      File.ln_s!(real_file, link_file)

      {:ok, result} = Scanner.scan(tmp_dir)

      # Should find both the real file and the symlink
      assert length(result.files) == 2
    end

    test "calculates total size correctly", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file1.mkv"), String.duplicate("x", 1000))
      File.write!(Path.join(tmp_dir, "file2.mkv"), String.duplicate("x", 2000))

      {:ok, result} = Scanner.scan(tmp_dir)

      assert result.total_size == 3000
    end

    @tag :skip
    test "handles permission errors gracefully", %{tmp_dir: tmp_dir} do
      # Skip this test as permission changes may not work in Docker containers
      restricted_dir = Path.join(tmp_dir, "restricted")
      File.mkdir_p!(restricted_dir)
      File.write!(Path.join(restricted_dir, "movie.mkv"), "video")

      # Change permissions to make directory unreadable
      File.chmod!(restricted_dir, 0o000)

      {:ok, result} = Scanner.scan(tmp_dir)

      # Restore permissions for cleanup
      File.chmod!(restricted_dir, 0o755)

      # Should complete scan but log errors
      assert length(result.errors) > 0
      assert Enum.any?(result.errors, &(&1.type == :directory_read_error))
    end

    test "reports progress during scanning", %{tmp_dir: tmp_dir} do
      # Create enough files to trigger progress callback (every 100 files)
      for i <- 1..250 do
        File.write!(Path.join(tmp_dir, "movie#{i}.mkv"), "video")
      end

      progress_callback = fn count ->
        send(self(), {:progress, count})
      end

      {:ok, _result} = Scanner.scan(tmp_dir, progress_callback: progress_callback)

      # Should receive progress updates at 100 and 200
      assert_received {:progress, 100}
      assert_received {:progress, 200}
    end

    test "is case-insensitive for file extensions", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "movie1.MKV"), "video")
      File.write!(Path.join(tmp_dir, "movie2.Mp4"), "video")
      File.write!(Path.join(tmp_dir, "movie3.AVI"), "video")

      {:ok, result} = Scanner.scan(tmp_dir)

      assert length(result.files) == 3
    end
  end

  describe "scan_multiple/2" do
    test "scans multiple directories", %{tmp_dir: tmp_dir} do
      dir1 = Path.join(tmp_dir, "dir1")
      dir2 = Path.join(tmp_dir, "dir2")
      File.mkdir_p!(dir1)
      File.mkdir_p!(dir2)

      File.write!(Path.join(dir1, "movie1.mkv"), "video")
      File.write!(Path.join(dir2, "movie2.mkv"), "video")

      {:ok, result} = Scanner.scan_multiple([dir1, dir2])

      assert length(result.files) == 2
      assert result.total_count == 2
      assert length(result.scans) == 2
    end

    test "combines results from all directories", %{tmp_dir: tmp_dir} do
      dir1 = Path.join(tmp_dir, "dir1")
      dir2 = Path.join(tmp_dir, "dir2")
      File.mkdir_p!(dir1)
      File.mkdir_p!(dir2)

      File.write!(Path.join(dir1, "movie1.mkv"), String.duplicate("x", 1000))
      File.write!(Path.join(dir2, "movie2.mkv"), String.duplicate("x", 2000))

      {:ok, result} = Scanner.scan_multiple([dir1, dir2])

      assert result.total_size == 3000
      assert result.total_count == 2
    end

    test "continues scanning even if one directory fails", %{tmp_dir: tmp_dir} do
      valid_dir = Path.join(tmp_dir, "valid")
      File.mkdir_p!(valid_dir)
      File.write!(Path.join(valid_dir, "movie.mkv"), "video")

      invalid_dir = "/nonexistent/path"

      {:ok, result} = Scanner.scan_multiple([valid_dir, invalid_dir])

      assert length(result.scans) == 2
      assert Enum.any?(result.scans, &(&1[:error] != nil))
      assert length(result.files) == 1
    end
  end

  describe "detect_changes/2" do
    test "detects new files" do
      scan_result = %{
        files: [
          %{path: "/media/movie1.mkv", size: 1000, modified_at: ~U[2024-01-01 12:00:00Z]},
          %{path: "/media/movie2.mkv", size: 2000, modified_at: ~U[2024-01-01 12:00:00Z]}
        ]
      }

      existing_files = [
        %{path: "/media/movie1.mkv", size: 1000, updated_at: ~U[2024-01-01 12:00:00Z]}
      ]

      changes = Scanner.detect_changes(scan_result, existing_files)

      assert length(changes.new_files) == 1
      assert hd(changes.new_files).path == "/media/movie2.mkv"
    end

    test "detects deleted files" do
      scan_result = %{
        files: [
          %{path: "/media/movie1.mkv", size: 1000, modified_at: ~U[2024-01-01 12:00:00Z]}
        ]
      }

      existing_files = [
        %{path: "/media/movie1.mkv", size: 1000, updated_at: ~U[2024-01-01 12:00:00Z]},
        %{path: "/media/movie2.mkv", size: 2000, updated_at: ~U[2024-01-01 12:00:00Z]}
      ]

      changes = Scanner.detect_changes(scan_result, existing_files)

      assert length(changes.deleted_files) == 1
      assert hd(changes.deleted_files).path == "/media/movie2.mkv"
    end

    test "detects modified files by size change" do
      scan_result = %{
        files: [
          %{path: "/media/movie1.mkv", size: 2000, modified_at: ~U[2024-01-01 12:00:00Z]}
        ]
      }

      existing_files = [
        %{
          path: "/media/movie1.mkv",
          size: 1000,
          updated_at: ~U[2024-01-01 11:00:00Z],
          verified_at: nil
        }
      ]

      changes = Scanner.detect_changes(scan_result, existing_files)

      assert length(changes.modified_files) == 1
      assert hd(changes.modified_files).path == "/media/movie1.mkv"
    end

    test "detects modified files by timestamp" do
      scan_result = %{
        files: [
          %{path: "/media/movie1.mkv", size: 1000, modified_at: ~U[2024-01-02 12:00:00Z]}
        ]
      }

      existing_files = [
        %{
          path: "/media/movie1.mkv",
          size: 1000,
          updated_at: ~U[2024-01-01 11:00:00Z],
          verified_at: ~U[2024-01-01 12:00:00Z]
        }
      ]

      changes = Scanner.detect_changes(scan_result, existing_files)

      assert length(changes.modified_files) == 1
    end

    test "returns empty changes when nothing changed" do
      files = [
        %{
          path: "/media/movie1.mkv",
          size: 1000,
          modified_at: ~U[2024-01-01 11:00:00Z],
          updated_at: ~U[2024-01-01 11:00:00Z]
        }
      ]

      scan_result = %{files: files}
      existing_files = files

      changes = Scanner.detect_changes(scan_result, existing_files)

      assert changes.new_files == []
      assert changes.deleted_files == []
      assert changes.modified_files == []
    end
  end
end
