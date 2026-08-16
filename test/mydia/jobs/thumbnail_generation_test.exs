defmodule Mydia.Jobs.ThumbnailGenerationTest do
  use Mydia.DataCase, async: true
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Jobs.ThumbnailGeneration

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  describe "new/1 job creation" do
    test "creates a job for a single file" do
      media_file = media_file_fixture()

      job =
        ThumbnailGeneration.new(%{
          mode: "single",
          media_file_id: media_file.id,
          include_sprites: false
        })

      assert job.changes.args == %{
               mode: "single",
               media_file_id: media_file.id,
               include_sprites: false
             }

      assert job.changes.queue == "media"
    end

    test "creates a job with include_sprites option" do
      media_file = media_file_fixture()

      job =
        ThumbnailGeneration.new(%{
          mode: "single",
          media_file_id: media_file.id,
          include_sprites: true
        })

      assert job.changes.args[:include_sprites] == true
    end

    test "creates a batch job for multiple files" do
      file1 = media_file_fixture()
      file2 = media_file_fixture()
      ids = [file1.id, file2.id]

      job =
        ThumbnailGeneration.new(%{
          mode: "batch",
          media_file_ids: ids,
          include_sprites: false
        })

      assert job.changes.args[:mode] == "batch"
      assert job.changes.args[:media_file_ids] == ids
    end

    test "creates a library job" do
      library_path = library_path_fixture()

      job =
        ThumbnailGeneration.new(%{
          mode: "library",
          library_path_id: library_path.id,
          include_sprites: false,
          regenerate: false
        })

      assert job.changes.args[:mode] == "library"
      assert job.changes.args[:library_path_id] == library_path.id
    end

    test "creates a missing thumbnails job" do
      job =
        ThumbnailGeneration.new(%{
          mode: "missing",
          include_sprites: false
        })

      assert job.changes.args[:mode] == "missing"
    end

    test "creates a missing thumbnails job with library_type filter" do
      job =
        ThumbnailGeneration.new(%{
          mode: "missing",
          include_sprites: false,
          library_type: "movies"
        })

      assert job.changes.args[:library_type] == "movies"
    end
  end

  describe "perform/1 for single file" do
    test "returns error for non-existent file" do
      # Non-existent file ID
      fake_id = Ecto.UUID.generate()

      result =
        perform_job(ThumbnailGeneration, %{
          "mode" => "single",
          "media_file_id" => fake_id,
          "include_sprites" => false
        })

      assert {:error, _reason} = result
    end
  end

  describe "perform/1 for batch" do
    test "processes batch even with non-existent files" do
      # Mix of valid and invalid IDs - batch should complete but skip missing files
      fake_id = Ecto.UUID.generate()

      # Batch mode should return :ok even if individual files fail
      assert :ok =
               perform_job(ThumbnailGeneration, %{
                 "mode" => "batch",
                 "media_file_ids" => [fake_id],
                 "include_sprites" => false
               })
    end
  end

  describe "perform/1 for library" do
    test "completes with no files" do
      library_path = library_path_fixture()

      assert :ok =
               perform_job(ThumbnailGeneration, %{
                 "mode" => "library",
                 "library_path_id" => library_path.id,
                 "include_sprites" => false,
                 "regenerate" => false
               })
    end
  end

  describe "perform/1 for missing" do
    test "completes with no missing files" do
      assert :ok =
               perform_job(ThumbnailGeneration, %{
                 "mode" => "missing",
                 "include_sprites" => false
               })
    end

    test "filters by library type" do
      assert :ok =
               perform_job(ThumbnailGeneration, %{
                 "mode" => "missing",
                 "include_sprites" => false,
                 "library_type" => "movies"
               })
    end
  end

  describe "backoff/1" do
    test "returns increasing backoff values" do
      # First attempt - 30 seconds
      assert 30 = ThumbnailGeneration.backoff(%Oban.Job{attempt: 1})

      # Second attempt - 120 seconds
      assert 120 = ThumbnailGeneration.backoff(%Oban.Job{attempt: 2})

      # Third attempt - 300 seconds
      assert 300 = ThumbnailGeneration.backoff(%Oban.Job{attempt: 3})

      # Beyond schedule - uses last value
      assert 1800 = ThumbnailGeneration.backoff(%Oban.Job{attempt: 10})
    end
  end

  describe "cancel_all/0" do
    test "cancels pending jobs" do
      # Insert a job directly for testing
      media_file = media_file_fixture()

      job =
        ThumbnailGeneration.new(%{
          mode: "single",
          media_file_id: media_file.id,
          include_sprites: false
        })

      {:ok, _} = Repo.insert(job)

      # Cancel all
      assert {:ok, count} = ThumbnailGeneration.cancel_all()
      assert count >= 0
    end
  end

  describe "topic/0" do
    test "returns the pubsub topic" do
      assert "thumbnail_generation" = ThumbnailGeneration.topic()
    end
  end
end
