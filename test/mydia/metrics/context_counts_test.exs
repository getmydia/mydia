defmodule Mydia.Metrics.ContextCountsTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.DownloadsFixtures

  alias Mydia.{Downloads, Jobs, Library, Media, Repo}

  describe "Media.episode_state_counts/0" do
    test "classifies episodes the way EpisodeStatus does, split by monitored" do
      show = media_item_fixture(%{type: "tv_show", title: "The Lanterns of Vell"})
      today = Date.utc_today()

      downloaded = episode_fixture(%{media_item_id: show.id, air_date: Date.add(today, -10)})
      media_file_fixture(%{episode_id: downloaded.id})

      episode_fixture(%{media_item_id: show.id, air_date: Date.add(today, -3)})
      episode_fixture(%{media_item_id: show.id, air_date: Date.add(today, -2), monitored: false})
      episode_fixture(%{media_item_id: show.id, air_date: Date.add(today, 5)})
      episode_fixture(%{media_item_id: show.id, air_date: nil})

      assert Media.episode_state_counts() == %{
               {"downloaded", true} => 1,
               {"missing", true} => 1,
               {"missing", false} => 1,
               {"upcoming", true} => 1,
               {"tba", true} => 1
             }
    end

    test "a trashed file does not make its episode downloaded" do
      show = media_item_fixture(%{type: "tv_show", title: "Harbor of Glass"})
      episode = episode_fixture(%{media_item_id: show.id, air_date: ~D[2020-01-01]})
      media_file = media_file_fixture(%{episode_id: episode.id})
      {:ok, _} = Library.trash_media_file(media_file)

      assert Media.episode_state_counts() == %{{"missing", true} => 1}
    end
  end

  describe "Library.media_file_count/0" do
    test "counts non-trashed files" do
      media_file_fixture()
      trashed = media_file_fixture()
      {:ok, _} = Library.trash_media_file(trashed)

      assert Library.media_file_count() == 1
    end
  end

  describe "Downloads.count_by_state/0" do
    test "derives state from completed_at, imported_at and error_message" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      download_fixture()
      download_fixture(%{error_message: "tracker said no"})
      download_fixture(%{completed_at: now})
      download_fixture(%{completed_at: now, imported_at: now})

      assert Downloads.count_by_state() == %{active: 1, failed: 1, awaiting_import: 1}
    end

    test "returns zeros for an empty table" do
      assert Downloads.count_by_state() == %{active: 0, failed: 0, awaiting_import: 0}
    end
  end

  describe "Jobs.count_by_queue_and_state/0" do
    test "groups pending jobs by queue and state and ignores finished ones" do
      insert_job("default", "available")
      insert_job("default", "available")
      insert_job("media", "executing")
      insert_job("media", "retryable")
      insert_job("media", "completed")
      insert_job("search", "discarded")

      assert Jobs.count_by_queue_and_state() == %{
               {"default", "available"} => 2,
               {"media", "executing"} => 1,
               {"media", "retryable"} => 1
             }
    end
  end

  defp insert_job(queue, state) do
    %{}
    |> Oban.Job.new(worker: "Mydia.Metrics.FakeWorker", queue: queue)
    |> Ecto.Changeset.put_change(:state, state)
    |> Repo.insert!()
  end
end
