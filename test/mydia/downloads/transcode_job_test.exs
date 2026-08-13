defmodule Mydia.Downloads.TranscodeJobTest do
  use Mydia.DataCase

  alias Mydia.Downloads
  alias Mydia.Downloads.TranscodeJob

  describe "transcode_job schema" do
    setup do
      library = insert(:library_path, type: :movies)
      media_item = insert(:media_item, type: "movie")

      media_file =
        insert(:media_file,
          media_item: media_item,
          library_path: library,
          relative_path: "movie.mkv",
          size: 1_000_000_000
        )

      %{media_file: media_file}
    end

    test "changeset validates required fields" do
      changeset = TranscodeJob.changeset(%TranscodeJob{}, %{})

      refute changeset.valid?
      assert :media_file_id in Keyword.keys(changeset.errors)
      assert :status in Keyword.keys(changeset.errors)
    end

    test "changeset accepts valid attributes", %{media_file: media_file} do
      changeset =
        TranscodeJob.changeset(%TranscodeJob{}, %{
          media_file_id: media_file.id,
          resolution: "1080p",
          status: "pending",
          progress: 0.0
        })

      assert changeset.valid?
    end

    test "changeset validates status inclusion", %{media_file: media_file} do
      changeset =
        TranscodeJob.changeset(%TranscodeJob{}, %{
          media_file_id: media_file.id,
          resolution: "1080p",
          status: "invalid_status"
        })

      refute changeset.valid?
      assert :status in Keyword.keys(changeset.errors)
    end

    test "changeset validates resolution inclusion", %{media_file: media_file} do
      changeset =
        TranscodeJob.changeset(%TranscodeJob{}, %{
          media_file_id: media_file.id,
          resolution: "4k",
          status: "pending"
        })

      refute changeset.valid?
      assert :resolution in Keyword.keys(changeset.errors)
    end

    test "changeset validates progress range", %{media_file: media_file} do
      invalid_changeset =
        TranscodeJob.changeset(%TranscodeJob{}, %{
          media_file_id: media_file.id,
          resolution: "720p",
          status: "transcoding",
          progress: 1.5
        })

      refute invalid_changeset.valid?
      assert :progress in Keyword.keys(invalid_changeset.errors)

      valid_changeset =
        TranscodeJob.changeset(%TranscodeJob{}, %{
          media_file_id: media_file.id,
          resolution: "720p",
          status: "transcoding",
          progress: 0.75
        })

      assert valid_changeset.valid?
    end

    test "changeset validates file_size is positive", %{media_file: media_file} do
      invalid_changeset =
        TranscodeJob.changeset(%TranscodeJob{}, %{
          media_file_id: media_file.id,
          resolution: "480p",
          status: "ready",
          file_size: 0
        })

      refute invalid_changeset.valid?
      assert :file_size in Keyword.keys(invalid_changeset.errors)
    end
  end

  describe "Downloads.get_or_create_job/2" do
    setup do
      library = insert(:library_path, type: :movies)
      media_item = insert(:media_item, type: "movie")

      media_file =
        insert(:media_file,
          media_item: media_item,
          library_path: library,
          relative_path: "movie.mkv",
          size: 1_000_000_000
        )

      %{media_file: media_file}
    end

    test "creates a new job when none exists", %{media_file: media_file} do
      assert {:ok, job} = Downloads.get_or_create_job(media_file.id, "1080p")

      assert job.media_file_id == media_file.id
      assert job.resolution == "1080p"
      assert job.status == "pending"
      assert job.progress == 0.0
    end

    test "returns existing job when one exists", %{media_file: media_file} do
      {:ok, first_job} = Downloads.get_or_create_job(media_file.id, "720p")
      {:ok, second_job} = Downloads.get_or_create_job(media_file.id, "720p")

      assert first_job.id == second_job.id
    end

    test "creates separate jobs for different resolutions", %{media_file: media_file} do
      {:ok, job_1080p} = Downloads.get_or_create_job(media_file.id, "1080p")
      {:ok, job_720p} = Downloads.get_or_create_job(media_file.id, "720p")

      assert job_1080p.id != job_720p.id
      assert job_1080p.resolution == "1080p"
      assert job_720p.resolution == "720p"
    end
  end

  describe "Downloads.get_cached_transcode/2" do
    setup do
      library = insert(:library_path, type: :movies)
      media_item = insert(:media_item, type: "movie")

      media_file =
        insert(:media_file,
          media_item: media_item,
          library_path: library,
          relative_path: "movie.mkv",
          size: 1_000_000_000
        )

      %{media_file: media_file}
    end

    test "returns nil when no job exists", %{media_file: media_file} do
      assert Downloads.get_cached_transcode(media_file.id, "1080p") == nil
    end

    test "returns nil when job is not ready", %{media_file: media_file} do
      {:ok, _job} = Downloads.get_or_create_job(media_file.id, "1080p")

      assert Downloads.get_cached_transcode(media_file.id, "1080p") == nil
    end

    test "returns job when status is ready", %{media_file: media_file} do
      {:ok, job} = Downloads.get_or_create_job(media_file.id, "720p")

      {:ok, _updated_job} =
        Downloads.complete_job(job, "/path/to/output.mp4", 500_000_000)

      cached = Downloads.get_cached_transcode(media_file.id, "720p")
      assert cached != nil
      assert cached.status == "ready"
      assert cached.output_path == "/path/to/output.mp4"
    end
  end

  describe "Downloads.update_job_progress/2" do
    setup do
      library = insert(:library_path, type: :movies)
      media_item = insert(:media_item, type: "movie")

      media_file =
        insert(:media_file,
          media_item: media_item,
          library_path: library,
          relative_path: "movie.mkv",
          size: 1_000_000_000
        )

      {:ok, job} = Downloads.get_or_create_job(media_file.id, "1080p")

      %{job: job}
    end

    test "updates progress and sets status to transcoding", %{job: job} do
      {:ok, updated_job} = Downloads.update_job_progress(job, 0.5)

      assert updated_job.progress == 0.5
      assert updated_job.status == "transcoding"
    end

    test "sets started_at on first progress update", %{job: job} do
      assert job.started_at == nil

      {:ok, updated_job} = Downloads.update_job_progress(job, 0.25)

      assert updated_job.started_at != nil
    end

    test "does not update started_at on subsequent updates", %{job: job} do
      {:ok, job_with_start} = Downloads.update_job_progress(job, 0.25)
      started_at = job_with_start.started_at

      # Small delay to ensure time would be different
      Process.sleep(10)

      {:ok, updated_job} = Downloads.update_job_progress(job_with_start, 0.75)

      assert DateTime.compare(updated_job.started_at, started_at) == :eq
    end
  end

  describe "Downloads.complete_job/3" do
    setup do
      library = insert(:library_path, type: :movies)
      media_item = insert(:media_item, type: "movie")

      media_file =
        insert(:media_file,
          media_item: media_item,
          library_path: library,
          relative_path: "movie.mkv",
          size: 1_000_000_000
        )

      {:ok, job} = Downloads.get_or_create_job(media_file.id, "720p")

      %{job: job}
    end

    test "marks job as ready and sets completion fields", %{job: job} do
      output_path = "/path/to/transcode.mp4"
      file_size = 750_000_000

      {:ok, completed_job} = Downloads.complete_job(job, output_path, file_size)

      assert completed_job.status == "ready"
      assert completed_job.progress == 1.0
      assert completed_job.output_path == output_path
      assert completed_job.file_size == file_size
      assert completed_job.completed_at != nil
      assert completed_job.last_accessed_at != nil
    end
  end

  describe "Downloads.fail_job/2" do
    setup do
      library = insert(:library_path, type: :movies)
      media_item = insert(:media_item, type: "movie")

      media_file =
        insert(:media_file,
          media_item: media_item,
          library_path: library,
          relative_path: "movie.mkv",
          size: 1_000_000_000
        )

      {:ok, job} = Downloads.get_or_create_job(media_file.id, "480p")

      %{job: job}
    end

    test "marks job as failed and stores error message", %{job: job} do
      error_message = "FFmpeg exited with code 1"

      {:ok, failed_job} = Downloads.fail_job(job, error_message)

      assert failed_job.status == "failed"
      assert failed_job.error == error_message
    end
  end

  describe "Downloads.touch_last_accessed/1" do
    setup do
      library = insert(:library_path, type: :movies)
      media_item = insert(:media_item, type: "movie")

      media_file =
        insert(:media_file,
          media_item: media_item,
          library_path: library,
          relative_path: "movie.mkv",
          size: 1_000_000_000
        )

      {:ok, job} = Downloads.get_or_create_job(media_file.id, "1080p")
      {:ok, job} = Downloads.complete_job(job, "/path/to/file.mp4", 1_000_000)

      %{job: job}
    end

    test "updates last_accessed_at timestamp", %{job: job} do
      original_accessed = job.last_accessed_at

      # Ensure we get a different second by waiting
      :timer.sleep(1100)

      {:ok, touched_job} = Downloads.touch_last_accessed(job)

      assert DateTime.compare(touched_job.last_accessed_at, original_accessed) == :gt
    end
  end

  describe "Downloads.cancel_transcode_job/1" do
    setup do
      library = insert(:library_path, type: :movies)
      media_item = insert(:media_item, type: "movie")

      media_file =
        insert(:media_file,
          media_item: media_item,
          library_path: library,
          relative_path: "movie.mkv",
          size: 1_000_000_000
        )

      {:ok, job} = Downloads.get_or_create_job(media_file.id, "720p")

      %{job: job, media_file: media_file}
    end

    test "deletes the job from database", %{job: job, media_file: media_file} do
      {:ok, _deleted_job} = Downloads.cancel_transcode_job(job)

      assert Downloads.get_cached_transcode(media_file.id, "720p") == nil
    end
  end

  describe "Downloads.cancel_transcode_job/1 output file cleanup" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "mydia-cancel-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      library = insert(:library_path, type: :movies, path: tmp_dir)
      media_item = insert(:media_item, type: "movie")

      media_file =
        insert(:media_file,
          media_item: media_item,
          library_path: library,
          relative_path: "movie.mkv",
          size: 1_000_000_000
        )

      source_path = Path.join(tmp_dir, "movie.mkv")
      File.write!(source_path, "source bytes")

      %{media_file: media_file, source_path: source_path, tmp_dir: tmp_dir}
    end

    test "keeps the source file when the job output is the media file itself", %{
      media_file: media_file,
      source_path: source_path
    } do
      # An "original" download transcodes nothing, so complete_job/3 records the
      # library file itself as the output.
      {:ok, job} = Downloads.get_or_create_job(media_file.id, "original")
      {:ok, job} = Downloads.complete_job(job, source_path, 12)

      {:ok, _cancelled} = Downloads.cancel_transcode_job(job)

      assert File.exists?(source_path)
      assert Repo.get(TranscodeJob, job.id) == nil
    end

    test "removes a transcoded artifact that is not the source file", %{
      media_file: media_file,
      tmp_dir: tmp_dir
    } do
      artifact_path = Path.join(tmp_dir, "transcode-720p.mp4")
      File.write!(artifact_path, "transcoded bytes")

      {:ok, job} = Downloads.get_or_create_job(media_file.id, "720p")
      {:ok, job} = Downloads.complete_job(job, artifact_path, 12)

      {:ok, _cancelled} = Downloads.cancel_transcode_job(job)

      refute File.exists?(artifact_path)
    end
  end

  describe "unique constraint" do
    setup do
      library = insert(:library_path, type: :movies)
      media_item = insert(:media_item, type: "movie")

      media_file =
        insert(:media_file,
          media_item: media_item,
          library_path: library,
          relative_path: "movie.mkv",
          size: 1_000_000_000
        )

      %{media_file: media_file}
    end

    test "prevents duplicate jobs for same file and resolution", %{media_file: media_file} do
      # Insert first job
      changeset1 =
        TranscodeJob.changeset(%TranscodeJob{}, %{
          media_file_id: media_file.id,
          resolution: "1080p",
          status: "pending"
        })

      {:ok, _job1} = Repo.insert(changeset1)

      # Try to insert duplicate job
      changeset2 =
        TranscodeJob.changeset(%TranscodeJob{}, %{
          media_file_id: media_file.id,
          resolution: "1080p",
          status: "pending"
        })

      assert {:error, changeset} = Repo.insert(changeset2)
      assert :media_file_id in Keyword.keys(changeset.errors)
    end
  end
end
