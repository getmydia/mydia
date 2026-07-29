defmodule Mydia.Downloads.DownloadServiceTest do
  use Mydia.DataCase

  alias Mydia.Downloads.DownloadService
  alias Mydia.Downloads

  describe "get_options/2" do
    setup do
      library = insert(:library_path, type: :movies, path: "/movies")
      media_item = insert(:media_item, type: "movie")

      media_file =
        insert(:media_file,
          media_item: media_item,
          library_path: library,
          relative_path: "movie.mkv",
          size: 1_000_000_000,
          resolution: "1080p"
        )

      %{media_item: media_item, media_file: media_file}
    end

    test "returns options for a movie", %{media_item: media_item} do
      assert {:ok, options} = DownloadService.get_options("movie", media_item.id)

      assert is_list(options)
      assert options != []

      # Should include original
      original = Enum.find(options, &(&1.resolution == "original"))
      assert original != nil
      assert original.label == "Original"

      # Should include available resolutions
      resolutions = Enum.map(options, & &1.resolution)
      assert "original" in resolutions
    end

    test "returns error for non-existent movie" do
      assert {:error, :not_found} = DownloadService.get_options("movie", Ecto.UUID.generate())
    end

    test "returns error for invalid content type" do
      assert {:error, :not_found} = DownloadService.get_options("invalid", Ecto.UUID.generate())
    end
  end

  describe "get_options/2 for episodes" do
    setup do
      library = insert(:library_path, type: :series, path: "/series")
      media_item = insert(:media_item, type: "tv_show", title: "Test Show")

      episode =
        insert(:episode,
          media_item: media_item,
          season_number: 1,
          episode_number: 1,
          title: "Pilot"
        )

      media_file =
        insert(:media_file,
          media_item: media_item,
          episode: episode,
          library_path: library,
          relative_path: "Test Show/S01E01.mkv",
          size: 500_000_000,
          resolution: "720p"
        )

      %{episode: episode, media_file: media_file}
    end

    test "returns options for an episode", %{episode: episode} do
      assert {:ok, options} = DownloadService.get_options("episode", episode.id)

      assert is_list(options)
      assert options != []
    end

    test "returns error for non-existent episode" do
      assert {:error, :not_found} = DownloadService.get_options("episode", Ecto.UUID.generate())
    end
  end

  describe "prepare/3" do
    setup do
      library = insert(:library_path, type: :movies, path: "/movies")
      media_item = insert(:media_item, type: "movie")

      media_file =
        insert(:media_file,
          media_item: media_item,
          library_path: library,
          relative_path: "movie.mkv",
          size: 1_000_000_000,
          resolution: "1080p"
        )

      %{media_item: media_item, media_file: media_file}
    end

    @tag :requires_ffmpeg
    test "creates a transcode job for movie", %{media_item: media_item} do
      assert {:ok, job_info} = DownloadService.prepare("movie", media_item.id, "720p")

      assert is_binary(job_info.job_id)
      assert job_info.status in ["pending", "ready"]
      assert job_info.progress >= 0.0
    end

    @tag :requires_ffmpeg
    test "returns same job when called twice", %{media_item: media_item} do
      {:ok, first_job} = DownloadService.prepare("movie", media_item.id, "720p")
      {:ok, second_job} = DownloadService.prepare("movie", media_item.id, "720p")

      assert first_job.job_id == second_job.job_id
    end

    @tag :requires_ffmpeg
    test "creates separate jobs for different resolutions", %{media_item: media_item} do
      {:ok, job_720} = DownloadService.prepare("movie", media_item.id, "720p")
      {:ok, job_480} = DownloadService.prepare("movie", media_item.id, "480p")

      assert job_720.job_id != job_480.job_id
    end

    test "returns error for invalid resolution", %{media_item: media_item} do
      assert {:error, :invalid_resolution} =
               DownloadService.prepare("movie", media_item.id, "4k")
    end

    test "returns error for non-existent media" do
      assert {:error, :not_found} =
               DownloadService.prepare("movie", Ecto.UUID.generate(), "720p")
    end
  end

  describe "get_job_status/1" do
    setup do
      library = insert(:library_path, type: :movies, path: "/movies")
      media_item = insert(:media_item, type: "movie")

      media_file =
        insert(:media_file,
          media_item: media_item,
          library_path: library,
          relative_path: "movie.mkv",
          size: 1_000_000_000,
          resolution: "1080p"
        )

      {:ok, job} = Downloads.get_or_create_job(media_file.id, "720p")

      %{job: job}
    end

    test "returns status for existing job", %{job: job} do
      assert {:ok, job_info} = DownloadService.get_job_status(job.id)

      assert job_info.job_id == job.id
      assert job_info.status == "pending"
      assert job_info.progress == 0.0
    end

    test "returns updated progress after update", %{job: job} do
      Downloads.update_job_progress(job, 0.5)

      assert {:ok, job_info} = DownloadService.get_job_status(job.id)

      assert job_info.status == "transcoding"
      assert job_info.progress == 0.5
    end

    test "returns error for non-existent job" do
      assert {:error, :job_not_found} = DownloadService.get_job_status(Ecto.UUID.generate())
    end
  end

  describe "cancel_job/1" do
    setup do
      library = insert(:library_path, type: :movies, path: "/movies")
      media_item = insert(:media_item, type: "movie")

      media_file =
        insert(:media_file,
          media_item: media_item,
          library_path: library,
          relative_path: "movie.mkv",
          size: 1_000_000_000,
          resolution: "1080p"
        )

      {:ok, job} = Downloads.get_or_create_job(media_file.id, "720p")

      %{job: job}
    end

    test "cancels an existing job", %{job: job} do
      assert {:ok, :cancelled} = DownloadService.cancel_job(job.id)

      # Job should no longer exist
      assert {:error, :job_not_found} = DownloadService.get_job_status(job.id)
    end

    test "returns error for non-existent job" do
      assert {:error, :job_not_found} = DownloadService.cancel_job(Ecto.UUID.generate())
    end
  end

  describe "get_job/1" do
    setup do
      library = insert(:library_path, type: :movies, path: "/movies")
      media_item = insert(:media_item, type: "movie")

      media_file =
        insert(:media_file,
          media_item: media_item,
          library_path: library,
          relative_path: "movie.mkv",
          size: 1_000_000_000,
          resolution: "1080p"
        )

      {:ok, job} = Downloads.get_or_create_job(media_file.id, "720p")

      %{job: job}
    end

    test "returns job for existing id", %{job: job} do
      assert {:ok, fetched_job} = DownloadService.get_job(job.id)
      assert fetched_job.id == job.id
    end

    test "returns error for non-existent job" do
      assert {:error, :job_not_found} = DownloadService.get_job(Ecto.UUID.generate())
    end
  end

  describe "calculate_quality_options/1" do
    test "includes original option first" do
      media_file = %{id: Ecto.UUID.generate(), size: 1_000_000_000, resolution: "1080p"}

      options = DownloadService.calculate_quality_options(media_file)

      assert List.first(options).resolution == "original"
      assert List.first(options).estimated_size == 1_000_000_000
    end

    test "filters resolutions based on source" do
      # 720p source should not offer 1080p
      media_file = %{id: Ecto.UUID.generate(), size: 500_000_000, resolution: "720p"}

      options = DownloadService.calculate_quality_options(media_file)

      resolutions = Enum.map(options, & &1.resolution)
      refute "1080p" in resolutions
      assert "720p" in resolutions
      assert "480p" in resolutions
    end

    test "estimates file size based on resolution" do
      media_file = %{id: Ecto.UUID.generate(), size: 1_000_000_000, resolution: "1080p"}

      options = DownloadService.calculate_quality_options(media_file)

      # 720p should be smaller than 1080p
      option_1080 = Enum.find(options, &(&1.resolution == "1080p"))
      option_720 = Enum.find(options, &(&1.resolution == "720p"))

      assert option_720.estimated_size < option_1080.estimated_size
    end
  end

  describe "parse_resolution_height/1" do
    test "parses standard resolution strings" do
      assert DownloadService.parse_resolution_height("4K") == 2160
      assert DownloadService.parse_resolution_height("2160p") == 2160
      assert DownloadService.parse_resolution_height("1080p") == 1080
      assert DownloadService.parse_resolution_height("720p") == 720
      assert DownloadService.parse_resolution_height("480p") == 480
    end

    test "parses dimension strings" do
      assert DownloadService.parse_resolution_height("1920x1080") == 1080
      assert DownloadService.parse_resolution_height("1280x720") == 720
    end

    test "defaults to 1080 for unknown formats" do
      assert DownloadService.parse_resolution_height(nil) == 1080
      assert DownloadService.parse_resolution_height("unknown") == 1080
    end
  end

  describe "validate_resolution/1" do
    test "accepts valid resolutions" do
      assert {:ok, "original"} = DownloadService.validate_resolution("original")
      assert {:ok, "1080p"} = DownloadService.validate_resolution("1080p")
      assert {:ok, "720p"} = DownloadService.validate_resolution("720p")
      assert {:ok, "480p"} = DownloadService.validate_resolution("480p")
    end

    test "rejects invalid resolutions" do
      assert {:error, :invalid_resolution} = DownloadService.validate_resolution("4k")
      assert {:error, :invalid_resolution} = DownloadService.validate_resolution("360p")
      assert {:error, :invalid_resolution} = DownloadService.validate_resolution("invalid")
    end
  end

  describe "resolution_to_atom/1" do
    test "converts resolution strings to atoms" do
      assert DownloadService.resolution_to_atom("original") == :original
      assert DownloadService.resolution_to_atom("1080p") == :p1080
      assert DownloadService.resolution_to_atom("720p") == :p720
      assert DownloadService.resolution_to_atom("480p") == :p480
    end

    test "defaults to 720p for unknown values" do
      assert DownloadService.resolution_to_atom("unknown") == :p720
    end
  end
end
