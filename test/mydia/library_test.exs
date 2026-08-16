defmodule Mydia.LibraryTest do
  use Mydia.DataCase

  import Ecto.Query, only: [from: 2]

  alias Mydia.Library
  alias Mydia.Library.MediaFile

  import Mydia.SettingsFixtures

  describe "delete_media_file/2" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "mydia_del_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)
      %{library_path: library_path_fixture(%{path: tmp, type: "movies"})}
    end

    defp scanned_file(library_path, rel, contents) do
      File.write!(Path.join(library_path.path, rel), contents)

      {:ok, file} =
        Library.create_scanned_media_file(%{
          relative_path: rel,
          library_path_id: library_path.id,
          size: byte_size(contents)
        })

      Mydia.Repo.preload(file, :library_path)
    end

    test "with delete_files: true removes the file from disk and the record", %{
      library_path: lp
    } do
      file = scanned_file(lp, "movie.mkv", "data")
      abs = MediaFile.absolute_path(file)
      assert File.exists?(abs)

      assert {:ok, %MediaFile{}} = Library.delete_media_file(file, delete_files: true)
      refute File.exists?(abs)
      refute Mydia.Repo.get(MediaFile, file.id)
    end

    test "with delete_files: false (default) keeps the file on disk", %{library_path: lp} do
      file = scanned_file(lp, "keep.mkv", "data")
      abs = MediaFile.absolute_path(file)

      assert {:ok, %MediaFile{}} = Library.delete_media_file(file)
      assert File.exists?(abs)
      refute Mydia.Repo.get(MediaFile, file.id)
    end

    test "reports file-removal failure but still deletes the record", %{library_path: lp} do
      # A directory at the media path makes File.rm fail reliably regardless of
      # which user the test runs as (a read-only dir would not stop root).
      rel = "as_dir.mkv"
      File.mkdir_p!(Path.join(lp.path, rel))

      {:ok, file} =
        Library.create_scanned_media_file(%{
          relative_path: rel,
          library_path_id: lp.id,
          size: 1
        })

      file = Mydia.Repo.preload(file, :library_path)

      assert {:ok, %MediaFile{}, :file_delete_failed} =
               Library.delete_media_file(file, delete_files: true)

      refute Mydia.Repo.get(MediaFile, file.id)
    end

    test "treats an already-missing file as success", %{library_path: lp} do
      file = scanned_file(lp, "gone.mkv", "data")
      File.rm!(MediaFile.absolute_path(file))

      assert {:ok, %MediaFile{}} = Library.delete_media_file(file, delete_files: true)
      refute Mydia.Repo.get(MediaFile, file.id)
    end
  end

  describe "list_media_files/1 with library_path_type filter" do
    test "filters media files by library path type" do
      # Create library paths of different types
      movies_path = library_path_fixture(%{path: "/movies", type: "movies"})
      series_path = library_path_fixture(%{path: "/series", type: "series"})

      # Create media files in each library
      {:ok, movies_file} =
        Library.create_scanned_media_file(%{
          relative_path: "movie.mp4",
          library_path_id: movies_path.id,
          size: 1_000_000
        })

      {:ok, series_file} =
        Library.create_scanned_media_file(%{
          relative_path: "video.mp4",
          library_path_id: series_path.id,
          size: 2_000_000
        })

      # Filter by series type
      series_files = Library.list_media_files(library_path_type: :series)
      assert length(series_files) == 1
      assert hd(series_files).id == series_file.id

      # Filter by movies type
      movie_files = Library.list_media_files(library_path_type: :movies)
      assert length(movie_files) == 1
      assert hd(movie_files).id == movies_file.id
    end

    test "returns empty list when no files match type" do
      # Create a library path of one type
      movies_path = library_path_fixture(%{path: "/movies2", type: "movies"})

      {:ok, _movies_file} =
        Library.create_scanned_media_file(%{
          relative_path: "movie2.mp4",
          library_path_id: movies_path.id,
          size: 1_000_000
        })

      # Query for a different type
      series_files = Library.list_media_files(library_path_type: :series)
      assert Enum.empty?(series_files)
    end

    test "can combine library_path_type with preload" do
      series_path = library_path_fixture(%{path: "/series2", type: "series"})

      {:ok, _series_file} =
        Library.create_scanned_media_file(%{
          relative_path: "video2.mp4",
          library_path_id: series_path.id,
          size: 2_000_000
        })

      files = Library.list_media_files(library_path_type: :series, preload: [:library_path])
      assert length(files) == 1
      assert hd(files).library_path.type == :series
    end
  end

  describe "update_media_file_scan/2" do
    test "updates orphaned media file without validation errors" do
      library_path = library_path_fixture(%{type: "movies"})

      # Create an orphaned file (no media_item_id or episode_id)
      {:ok, media_file} =
        Library.create_scanned_media_file(%{
          relative_path: "orphaned/file.mp4",
          library_path_id: library_path.id,
          size: 1_000_000
        })

      assert is_nil(media_file.media_item_id)
      assert is_nil(media_file.episode_id)

      # Update using scan function should succeed
      {:ok, updated} =
        Library.update_media_file_scan(media_file, %{
          size: 2_000_000,
          verified_at: DateTime.utc_now()
        })

      assert updated.size == 2_000_000
      assert updated.verified_at != nil
    end

    test "regular update_media_file fails on orphaned files" do
      library_path = library_path_fixture(%{type: "movies"})

      # Create an orphaned file
      {:ok, media_file} =
        Library.create_scanned_media_file(%{
          relative_path: "orphaned/file2.mp4",
          library_path_id: library_path.id,
          size: 1_000_000
        })

      # Regular update should fail due to missing parent
      {:error, changeset} =
        Library.update_media_file(media_file, %{
          size: 2_000_000,
          verified_at: DateTime.utc_now()
        })

      assert %{media_item_id: ["either media_item_id or episode_id must be set"]} =
               errors_on(changeset)
    end
  end

  describe "list_media_ids_in_library_path/1" do
    test "returns unique media item IDs from files in library path" do
      unique_path = "/media/movies_#{System.unique_integer([:positive])}"
      library_path = library_path_fixture(%{path: unique_path, type: "movies"})

      # Create a media item
      {:ok, media_item} =
        Mydia.Media.create_media_item(%{
          type: "movie",
          title: "Test Movie",
          year: 2024
        })

      # Create media files for this media item
      {:ok, _file1} =
        Library.create_media_file(%{
          relative_path: "Test Movie/movie.mp4",
          library_path_id: library_path.id,
          media_item_id: media_item.id,
          size: 1_000_000
        })

      {:ok, _file2} =
        Library.create_media_file(%{
          relative_path: "Test Movie/movie.srt",
          library_path_id: library_path.id,
          media_item_id: media_item.id,
          size: 50_000
        })

      # Get media IDs for this library path
      media_ids = Library.list_media_ids_in_library_path(library_path)

      # Should return the media item ID once (not duplicated)
      assert length(media_ids) == 1
      assert hd(media_ids) == media_item.id
    end

    test "returns empty list when no files in library path" do
      unique_path = "/media/empty_#{System.unique_integer([:positive])}"
      library_path = library_path_fixture(%{path: unique_path, type: "movies"})

      media_ids = Library.list_media_ids_in_library_path(library_path)

      assert media_ids == []
    end

    test "excludes files without media_item_id" do
      unique_path = "/media/orphaned_#{System.unique_integer([:positive])}"
      library_path = library_path_fixture(%{path: unique_path, type: "movies"})

      # Create orphaned file (no media_item_id)
      {:ok, _orphaned_file} =
        Library.create_scanned_media_file(%{
          relative_path: "orphaned.mp4",
          library_path_id: library_path.id,
          size: 1_000_000
        })

      media_ids = Library.list_media_ids_in_library_path(library_path)

      assert media_ids == []
    end
  end

  describe "trash_media_file/1" do
    test "sets trashed_at timestamp" do
      library_path = library_path_fixture(%{type: "movies"})

      {:ok, media_file} =
        Library.create_scanned_media_file(%{
          relative_path: "trash_test.mp4",
          library_path_id: library_path.id,
          size: 1_000_000
        })

      assert is_nil(media_file.trashed_at)

      {:ok, trashed} = Library.trash_media_file(media_file)
      assert not is_nil(trashed.trashed_at)
    end
  end

  describe "restore_media_file/1" do
    test "clears trashed_at timestamp" do
      library_path = library_path_fixture(%{type: "movies"})

      {:ok, media_file} =
        Library.create_scanned_media_file(%{
          relative_path: "restore_test.mp4",
          library_path_id: library_path.id,
          size: 1_000_000
        })

      {:ok, trashed} = Library.trash_media_file(media_file)
      assert not is_nil(trashed.trashed_at)

      {:ok, restored} = Library.restore_media_file(trashed)
      assert is_nil(restored.trashed_at)
    end
  end

  describe "list_media_files/1 with trashed files" do
    test "excludes trashed files by default" do
      library_path =
        library_path_fixture(%{
          path: "/trash_filter_#{System.unique_integer([:positive])}",
          type: "movies"
        })

      {:ok, file1} =
        Library.create_scanned_media_file(%{
          relative_path: "active.mp4",
          library_path_id: library_path.id,
          size: 1_000_000
        })

      {:ok, file2} =
        Library.create_scanned_media_file(%{
          relative_path: "trashed.mp4",
          library_path_id: library_path.id,
          size: 2_000_000
        })

      {:ok, _trashed} = Library.trash_media_file(file2)

      files = Library.list_media_files(library_path_id: library_path.id)
      assert length(files) == 1
      assert hd(files).id == file1.id
    end

    test "includes trashed files when include_trashed: true" do
      library_path =
        library_path_fixture(%{
          path: "/trash_include_#{System.unique_integer([:positive])}",
          type: "movies"
        })

      {:ok, _file1} =
        Library.create_scanned_media_file(%{
          relative_path: "active2.mp4",
          library_path_id: library_path.id,
          size: 1_000_000
        })

      {:ok, file2} =
        Library.create_scanned_media_file(%{
          relative_path: "trashed2.mp4",
          library_path_id: library_path.id,
          size: 2_000_000
        })

      {:ok, _trashed} = Library.trash_media_file(file2)

      files = Library.list_media_files(library_path_id: library_path.id, include_trashed: true)
      assert length(files) == 2
    end
  end

  describe "purge_old_trashed_media_files/1" do
    test "only deletes files trashed beyond retention period" do
      library_path =
        library_path_fixture(%{
          path: "/purge_test_#{System.unique_integer([:positive])}",
          type: "movies"
        })

      # Create two files
      {:ok, old_file} =
        Library.create_scanned_media_file(%{
          relative_path: "old_trashed.mp4",
          library_path_id: library_path.id,
          size: 1_000_000
        })

      {:ok, recent_file} =
        Library.create_scanned_media_file(%{
          relative_path: "recent_trashed.mp4",
          library_path_id: library_path.id,
          size: 2_000_000
        })

      # Trash both files
      {:ok, _} = Library.trash_media_file(old_file)
      {:ok, _} = Library.trash_media_file(recent_file)

      # Manually backdate the old file's trashed_at to 31 days ago
      old_trashed_at = DateTime.utc_now() |> DateTime.add(-31, :day) |> DateTime.truncate(:second)

      old_file
      |> Ecto.Changeset.change(trashed_at: old_trashed_at)
      |> Mydia.Repo.update!()

      # Purge with 30 day retention
      {:ok, count} = Library.purge_old_trashed_media_files(30)
      assert count == 1

      # Old file should be gone, recent file should still exist
      assert is_nil(Library.get_media_file(old_file.id))
      assert not is_nil(Library.get_media_file(recent_file.id))
    end

    test "does not delete non-trashed files" do
      library_path =
        library_path_fixture(%{
          path: "/purge_safe_#{System.unique_integer([:positive])}",
          type: "movies"
        })

      {:ok, active_file} =
        Library.create_scanned_media_file(%{
          relative_path: "active_purge.mp4",
          library_path_id: library_path.id,
          size: 1_000_000
        })

      {:ok, count} = Library.purge_old_trashed_media_files(0)
      assert count == 0

      assert not is_nil(Library.get_media_file(active_file.id))
    end
  end

  describe "get_media_file_by_relative_path/3 with trashed files" do
    test "excludes trashed files by default" do
      library_path =
        library_path_fixture(%{
          path: "/rel_path_trash_#{System.unique_integer([:positive])}",
          type: "movies"
        })

      {:ok, media_file} =
        Library.create_scanned_media_file(%{
          relative_path: "trashable.mp4",
          library_path_id: library_path.id,
          size: 1_000_000
        })

      {:ok, _trashed} = Library.trash_media_file(media_file)

      assert is_nil(Library.get_media_file_by_relative_path(library_path.id, "trashable.mp4"))
    end

    test "includes trashed files when include_trashed: true" do
      library_path =
        library_path_fixture(%{
          path: "/rel_path_include_#{System.unique_integer([:positive])}",
          type: "movies"
        })

      {:ok, media_file} =
        Library.create_scanned_media_file(%{
          relative_path: "trashable2.mp4",
          library_path_id: library_path.id,
          size: 1_000_000
        })

      {:ok, _trashed} = Library.trash_media_file(media_file)

      found =
        Library.get_media_file_by_relative_path(library_path.id, "trashable2.mp4",
          include_trashed: true
        )

      assert not is_nil(found)
      assert found.id == media_file.id
    end
  end

  describe "total_storage_bytes/0 with trashed files" do
    test "excludes trashed files from total" do
      library_path =
        library_path_fixture(%{
          path: "/storage_trash_#{System.unique_integer([:positive])}",
          type: "movies"
        })

      {:ok, _active} =
        Library.create_scanned_media_file(%{
          relative_path: "counted.mp4",
          library_path_id: library_path.id,
          size: 500
        })

      {:ok, trashable} =
        Library.create_scanned_media_file(%{
          relative_path: "not_counted.mp4",
          library_path_id: library_path.id,
          size: 300
        })

      total_before = Library.total_storage_bytes()

      {:ok, _} = Library.trash_media_file(trashable)

      total_after = Library.total_storage_bytes()
      assert total_after == total_before - 300
    end
  end

  describe "apply_analysis/2" do
    alias Mydia.Library.MediaFile
    alias Mydia.Library.Structs.FileAnalysisResult
    alias Mydia.Library.Structs.FileMetadata
    alias Mydia.Repo

    setup do
      library_path = library_path_fixture(%{path: "/apply-analysis", type: "movies"})

      {:ok, media_file} =
        Library.create_scanned_media_file(%{
          relative_path: "subject.mkv",
          library_path_id: library_path.id,
          size: 1_500_000
        })

      result = %FileAnalysisResult{
        resolution: "1080p",
        width: 1920,
        height: 1080,
        codec: "H.264 (High)",
        audio_codec: "AAC Stereo",
        bitrate: 8_000_000,
        hdr_format: nil,
        size: 2_147_483_648,
        duration: 5400.5,
        container: "mkv"
      }

      %{media_file: media_file, result: result}
    end

    test "success path populates tech metadata, analyzed_at, and clears last_analysis_error",
         %{media_file: media_file, result: result} do
      assert :ok = Library.apply_analysis(media_file, {:ok, result})

      reloaded = Repo.get!(MediaFile, media_file.id)

      assert reloaded.codec == "h264"
      assert reloaded.audio_codec == "aac"
      assert reloaded.resolution == "1080p"
      assert reloaded.bitrate == 8_000_000
      assert is_nil(reloaded.hdr_format)
      assert reloaded.size == 2_147_483_648

      # audio_codec_raw keeps the analyzer's own string, which the
      # audio_codec column above has already lost the channel layout from
      # ("AAC Stereo" -> "aac"). Mydia.Upgrades.Attrs reads it to recover
      # audio_channels and the Atmos/E-AC3 distinction, so asserting the
      # *production* write here is what stops that being silently dropped.
      assert %FileMetadata{
               container: "mkv",
               duration: 5400.5,
               width: 1920,
               height: 1080,
               audio_codec_raw: "AAC Stereo"
             } = reloaded.metadata

      assert %DateTime{} = reloaded.analyzed_at
      assert reloaded.last_analysis_error == nil
    end

    test "second concurrent writer returns :already_analyzed and does not overwrite",
         %{media_file: media_file, result: result} do
      assert :ok = Library.apply_analysis(media_file, {:ok, result})
      reloaded = Repo.get!(MediaFile, media_file.id)
      analyzed_at = reloaded.analyzed_at

      different_result = %FileAnalysisResult{result | codec: "HEVC"}
      assert :already_analyzed = Library.apply_analysis(media_file, {:ok, different_result})

      final = Repo.get!(MediaFile, media_file.id)
      assert final.codec == "h264"
      assert final.analyzed_at == analyzed_at
    end

    test "failure path bumps analysis_attempts and records last_analysis_error",
         %{media_file: media_file} do
      assert {:error, :ffprobe_timeout} =
               Library.apply_analysis(media_file, {:error, :ffprobe_timeout})

      reloaded = Repo.get!(MediaFile, media_file.id)
      assert reloaded.analysis_attempts == 1
      assert reloaded.last_analysis_error == ":ffprobe_timeout"
      assert is_nil(reloaded.analyzed_at)
      assert is_nil(reloaded.codec)
    end

    test "failure path truncates long analysis errors", %{media_file: media_file} do
      long_reason = String.duplicate("ffprobe stderr ", 300)

      assert {:error, ^long_reason} = Library.apply_analysis(media_file, {:error, long_reason})

      reloaded = Repo.get!(MediaFile, media_file.id)
      assert reloaded.analysis_attempts == 1
      assert String.length(reloaded.last_analysis_error) == 2048
      assert String.starts_with?(long_reason, reloaded.last_analysis_error)
    end

    test "three consecutive failures leave analysis_attempts at 3",
         %{media_file: media_file} do
      for _ <- 1..3 do
        assert {:error, :ffprobe_failed} =
                 Library.apply_analysis(media_file, {:error, :ffprobe_failed})
      end

      reloaded = Repo.get!(MediaFile, media_file.id)
      assert reloaded.analysis_attempts == 3
      assert reloaded.last_analysis_error == ":ffprobe_failed"
    end

    test "success path leaves existing size untouched when result.size is nil",
         %{media_file: media_file, result: result} do
      no_size_result = %FileAnalysisResult{result | size: nil}

      assert :ok = Library.apply_analysis(media_file, {:ok, no_size_result})

      reloaded = Repo.get!(MediaFile, media_file.id)
      assert reloaded.size == 1_500_000
      assert reloaded.codec == "h264"
    end

    test "merges into existing FileMetadata without clobbering unrelated fields",
         %{media_file: media_file, result: result} do
      preset_metadata = %FileMetadata{
        width: 1920,
        height: 1080,
        source: "trusted-release"
      }

      Repo.update_all(
        from(mf in MediaFile, where: mf.id == ^media_file.id),
        set: [metadata: preset_metadata]
      )

      assert :ok = Library.apply_analysis(media_file, {:ok, result})

      reloaded = Repo.get!(MediaFile, media_file.id)
      assert reloaded.metadata.width == 1920
      assert reloaded.metadata.height == 1080
      assert reloaded.metadata.source == "trusted-release"
      assert reloaded.metadata.container == "mkv"
      assert reloaded.metadata.duration == 5400.5
    end
  end

  describe "create_scanned_media_file/1 (U4 import path)" do
    alias Mydia.Library.MediaFile

    test "leaves tech-metadata columns nil and analysis state at zero" do
      library_path = library_path_fixture(%{path: "/u4-import", type: "movies"})

      {:ok, media_file} =
        Library.create_scanned_media_file(%{
          relative_path: "Untouched.mkv",
          library_path_id: library_path.id,
          size: 1_000_000
        })

      assert is_nil(media_file.codec)
      assert is_nil(media_file.resolution)
      assert is_nil(media_file.bitrate)
      assert is_nil(media_file.audio_codec)
      assert is_nil(media_file.hdr_format)
      assert is_nil(media_file.analyzed_at)
      assert media_file.analysis_attempts == 0
    end

    test "does not enqueue any Oban jobs as a side effect" do
      library_path = library_path_fixture(%{path: "/u4-no-jobs", type: "movies"})

      before_count = Mydia.Repo.aggregate(Oban.Job, :count)

      {:ok, _media_file} =
        Library.create_scanned_media_file(%{
          relative_path: "NoJobs.mkv",
          library_path_id: library_path.id,
          size: 1_000_000
        })

      after_count = Mydia.Repo.aggregate(Oban.Job, :count)
      assert before_count == after_count
    end

    test "remains fast across many rows (no per-file ffprobe)" do
      library_path = library_path_fixture(%{path: "/u4-fast", type: "movies"})

      {elapsed_us, _} =
        :timer.tc(fn ->
          for i <- 1..50 do
            {:ok, _} =
              Library.create_scanned_media_file(%{
                relative_path: "Fast/file_#{i}.mkv",
                library_path_id: library_path.id,
                size: 1_000_000
              })
          end
        end)

      # 50 inserts should easily complete in well under 5 seconds; if inline
      # ffprobe ever returns, this assertion will fail loudly.
      assert elapsed_us < 5_000_000,
             "expected 50 imports under 5s, took #{elapsed_us / 1_000}ms"

      assert Mydia.Repo.aggregate(
               from(mf in MediaFile, where: mf.library_path_id == ^library_path.id),
               :count
             ) == 50
    end
  end

  describe "refresh_file_metadata/1 (U4 operator retry)" do
    alias Mydia.Library.MediaFile
    alias Mydia.Library.Structs.FileAnalysisResult
    alias Mydia.Repo

    setup do
      on_exit(fn ->
        Application.delete_env(:mydia, :ffprobe_path)
        Application.delete_env(:mydia, :ffprobe_timeout_ms)
      end)

      :ok
    end

    test "returns {:error, :file_not_found} when the file is missing on disk" do
      library_path = library_path_fixture(%{path: "/u4-missing", type: "movies"})

      {:ok, media_file} =
        Library.create_scanned_media_file(%{
          relative_path: "missing.mkv",
          library_path_id: library_path.id,
          size: 1_000_000
        })

      media_file = Repo.preload(media_file, :library_path)
      assert {:error, :file_not_found} = Library.refresh_file_metadata(media_file)
    end

    test "returns {:error, :path_not_resolved} when library_path is nil" do
      library_path = library_path_fixture(%{path: "/u4-resolve", type: "movies"})

      {:ok, media_file} =
        Library.create_scanned_media_file(%{
          relative_path: "stub.mkv",
          library_path_id: library_path.id,
          size: 1_000_000
        })

      # Force absolute_path/1 to return nil
      detached = %{media_file | library_path: nil, relative_path: nil}
      assert {:error, :path_not_resolved} = Library.refresh_file_metadata(detached)
    end

    test "success path resets analysis_attempts, populates analyzed_at, and sets verified_at" do
      target = Path.join(System.tmp_dir!(), "u4_refresh_ok_#{:rand.uniform(1_000_000)}.mkv")
      File.write!(target, "fake content")

      shim_json =
        ~s({"streams":[{"codec_type":"video","codec_name":"h264","width":1920,"height":1080,"bit_rate":"8000000"},{"codec_type":"audio","codec_name":"aac"}],"format":{"duration":"5400.5","format_name":"matroska,webm","size":"#{File.stat!(target).size}","bit_rate":"8000000"}})

      shim = write_shim_returning(shim_json)

      try do
        Application.put_env(:mydia, :ffprobe_path, shim)

        library_path = library_path_fixture(%{path: Path.dirname(target), type: "movies"})

        {:ok, media_file} =
          Library.create_scanned_media_file(%{
            relative_path: Path.basename(target),
            library_path_id: library_path.id,
            size: File.stat!(target).size
          })

        # Drive the row to a "retry exhausted" state to prove refresh clears it
        Repo.update_all(
          from(mf in MediaFile, where: mf.id == ^media_file.id),
          set: [analysis_attempts: 3, last_analysis_error: ":ffprobe_timeout"]
        )

        media_file = Repo.preload(media_file, :library_path)

        assert {:ok, %MediaFile{} = refreshed} = Library.refresh_file_metadata(media_file)

        assert refreshed.codec == "h264"
        assert refreshed.audio_codec == "aac"
        assert refreshed.resolution == "1080p"
        assert %DateTime{} = refreshed.analyzed_at
        assert %DateTime{} = refreshed.verified_at
        assert refreshed.analysis_attempts == 0
        assert is_nil(refreshed.last_analysis_error)
      after
        File.rm(shim)
        File.rm(target)
      end
    end

    test "failure path bumps analysis_attempts and surfaces the error" do
      target = Path.join(System.tmp_dir!(), "u4_refresh_fail_#{:rand.uniform(1_000_000)}.mkv")
      File.write!(target, "fake content")

      shim = write_shim_returning(:exit_nonzero)

      try do
        Application.put_env(:mydia, :ffprobe_path, shim)

        library_path = library_path_fixture(%{path: Path.dirname(target), type: "movies"})

        {:ok, media_file} =
          Library.create_scanned_media_file(%{
            relative_path: Path.basename(target),
            library_path_id: library_path.id,
            size: File.stat!(target).size
          })

        media_file = Repo.preload(media_file, :library_path)

        assert {:error, :ffprobe_failed} = Library.refresh_file_metadata(media_file)

        reloaded = Repo.get!(MediaFile, media_file.id)
        # reset_analysis_state runs before ffprobe, then failure bumps from 0 to 1
        assert reloaded.analysis_attempts == 1
        assert reloaded.last_analysis_error == ":ffprobe_failed"
        assert is_nil(reloaded.analyzed_at)
      after
        File.rm(shim)
        File.rm(target)
      end
    end
  end

  describe "reset_analysis_state/1" do
    alias Mydia.Library.MediaFile
    alias Mydia.Library.Structs.FileAnalysisResult
    alias Mydia.Repo

    test "clears analyzed_at, analysis_attempts, and last_analysis_error" do
      library_path = library_path_fixture(%{path: "/reset-analysis", type: "movies"})

      {:ok, media_file} =
        Library.create_scanned_media_file(%{
          relative_path: "subject.mkv",
          library_path_id: library_path.id,
          size: 1_500_000
        })

      # Drive the row to "analyzed, then a stale failure arrives" state. With
      # the failure-path guard, the stale failure no longer bumps attempts on
      # an already-analyzed row — but reset_analysis_state still needs to
      # clear all three fields cleanly.
      assert :ok =
               Library.apply_analysis(media_file, {:ok, %FileAnalysisResult{codec: "H.264"}})

      # Force a non-zero attempts/error state directly so we have something
      # to reset.
      Repo.update_all(
        from(mf in MediaFile, where: mf.id == ^media_file.id),
        set: [analysis_attempts: 2, last_analysis_error: ":ffprobe_failed"]
      )

      reloaded = Repo.get!(MediaFile, media_file.id)
      assert reloaded.analyzed_at
      assert reloaded.analysis_attempts == 2
      assert reloaded.last_analysis_error == ":ffprobe_failed"

      assert :ok = Library.reset_analysis_state(reloaded)

      reset = Repo.get!(MediaFile, media_file.id)
      assert is_nil(reset.analyzed_at)
      assert reset.analysis_attempts == 0
      assert is_nil(reset.last_analysis_error)
    end

    test "returns {:error, :not_found} when the row no longer exists" do
      library_path = library_path_fixture(%{path: "/reset-missing", type: "movies"})

      {:ok, media_file} =
        Library.create_scanned_media_file(%{
          relative_path: "vanished.mkv",
          library_path_id: library_path.id,
          size: 1_500_000
        })

      Repo.delete!(media_file)

      assert {:error, :not_found} = Library.reset_analysis_state(media_file)
    end
  end

  describe "apply_analysis_failure on already-analyzed rows" do
    alias Mydia.Library.MediaFile
    alias Mydia.Library.Structs.FileAnalysisResult
    alias Mydia.Repo

    test "does not bump analysis_attempts after analyzed_at is set" do
      library_path = library_path_fixture(%{path: "/stale-failure", type: "movies"})

      {:ok, media_file} =
        Library.create_scanned_media_file(%{
          relative_path: "subject.mkv",
          library_path_id: library_path.id,
          size: 1_500_000
        })

      assert :ok =
               Library.apply_analysis(media_file, {:ok, %FileAnalysisResult{codec: "H.264"}})

      # A stale failure arriving after analyzed_at is set must not flip the
      # row back into "needs another attempt" territory.
      Library.apply_analysis(media_file, {:error, :ffprobe_failed})

      reloaded = Repo.get!(MediaFile, media_file.id)
      assert reloaded.analyzed_at
      assert reloaded.analysis_attempts == 0
      assert is_nil(reloaded.last_analysis_error)
    end
  end

  defp write_shim_returning(:exit_nonzero) do
    path = Path.join(System.tmp_dir!(), "ffprobe_fail_#{:rand.uniform(10_000_000)}.sh")
    File.write!(path, "#!/bin/sh\necho 'shim failure' >&2\nexit 1\n")
    File.chmod!(path, 0o755)
    path
  end

  defp write_shim_returning(json) when is_binary(json) do
    path = Path.join(System.tmp_dir!(), "ffprobe_ok_#{:rand.uniform(10_000_000)}.sh")
    escaped = String.replace(json, "'", "'\\''")
    File.write!(path, "#!/bin/sh\nprintf '%s' '#{escaped}'\n")
    File.chmod!(path, 0o755)
    path
  end

  describe "list_media_files_for_download/1" do
    test "locates files by imported_from_download_id, excluding recycled client ids" do
      lib = library_path_fixture(%{type: "movies"})
      movie = Mydia.MediaFixtures.media_item_fixture(%{type: "movie"})

      download_id = Ecto.UUID.generate()
      other_download_id = Ecto.UUID.generate()

      {:ok, ours} =
        Library.create_media_file(%{
          relative_path: "ours.mkv",
          library_path_id: lib.id,
          media_item_id: movie.id,
          size: 100,
          metadata: %{
            "imported_from_download_id" => download_id,
            "download_client" => "qbit",
            "download_client_id" => "7"
          }
        })

      # Same recycled client id, different download — must NOT be returned.
      {:ok, _recycled} =
        Library.create_media_file(%{
          relative_path: "recycled.mkv",
          library_path_id: lib.id,
          media_item_id: movie.id,
          size: 100,
          metadata: %{
            "imported_from_download_id" => other_download_id,
            "download_client" => "qbit",
            "download_client_id" => "7"
          }
        })

      download = %Mydia.Downloads.Download{id: download_id}
      result = Library.list_media_files_for_download(download)

      assert Enum.map(result, & &1.id) == [ours.id]
    end

    test "excludes trashed files" do
      lib = library_path_fixture(%{type: "movies"})
      movie = Mydia.MediaFixtures.media_item_fixture(%{type: "movie"})
      download_id = Ecto.UUID.generate()

      {:ok, _trashed} =
        Library.create_media_file(%{
          relative_path: "trashed.mkv",
          library_path_id: lib.id,
          media_item_id: movie.id,
          size: 100,
          trashed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          metadata: %{"imported_from_download_id" => download_id}
        })

      download = %Mydia.Downloads.Download{id: download_id}
      assert Library.list_media_files_for_download(download) == []
    end
  end

  describe "count_imported_files_by_download/1" do
    test "counts non-trashed files per download, omitting downloads with none" do
      lib = library_path_fixture(%{type: "movies"})
      movie = Mydia.MediaFixtures.media_item_fixture(%{type: "movie"})

      single = Ecto.UUID.generate()
      pack = Ecto.UUID.generate()
      none = Ecto.UUID.generate()

      {:ok, _} =
        Library.create_media_file(%{
          relative_path: "single.mkv",
          library_path_id: lib.id,
          media_item_id: movie.id,
          size: 100,
          metadata: %{"imported_from_download_id" => single}
        })

      for n <- 1..2 do
        {:ok, _} =
          Library.create_media_file(%{
            relative_path: "pack#{n}.mkv",
            library_path_id: lib.id,
            media_item_id: movie.id,
            size: 100,
            metadata: %{"imported_from_download_id" => pack}
          })
      end

      # A trashed file must not be counted.
      {:ok, _} =
        Library.create_media_file(%{
          relative_path: "pack-trashed.mkv",
          library_path_id: lib.id,
          media_item_id: movie.id,
          size: 100,
          trashed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          metadata: %{"imported_from_download_id" => pack}
        })

      counts = Library.count_imported_files_by_download([single, pack, none])

      assert counts[single] == 1
      assert counts[pack] == 2
      refute Map.has_key?(counts, none)
    end

    test "returns an empty map for an empty id list" do
      assert Library.count_imported_files_by_download([]) == %{}
    end
  end
end
