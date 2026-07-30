defmodule Mydia.Jobs.MetadataRefreshTest do
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Events
  alias Mydia.Jobs.MetadataRefresh

  import Mydia.MediaFixtures

  describe "perform/1 - single media item" do
    test "returns error when media item does not exist" do
      fake_id = Ecto.UUID.generate()

      assert {:error, :not_found} =
               perform_job(MetadataRefresh, %{"media_item_id" => fake_id})
    end

    test "returns missing_provider_id when nothing resolves and recovery fails" do
      media_item =
        media_item_fixture(%{
          type: "movie",
          title: "Nonexistent Movie XYZ123",
          year: 2024,
          tmdb_id: nil
        })

      assert {:error, :missing_provider_id} =
               perform_job(MetadataRefresh, %{"media_item_id" => media_item.id})
    end
  end

  describe "run_all/1 - pass isolation" do
    test "one raising item does not abort the pass" do
      for n <- 1..3 do
        media_item_fixture(%{type: "movie", title: "Item #{n}", year: 2024})
      end

      attempted = :counters.new(1, [])

      raise_on_second = fn _media_item ->
        :counters.add(attempted, 1, 1)

        if :counters.get(attempted, 1) == 2 do
          raise "boom"
        end

        {:error, :relay_unavailable}
      end

      assert :ok = MetadataRefresh.run_all(raise_on_second)

      # All three were attempted: the raise was contained, not propagated.
      assert :counters.get(attempted, 1) == 3
    end

    test "emits a job_failed event carrying accurate counts" do
      for n <- 1..3 do
        media_item_fixture(%{type: "movie", title: "Item #{n}", year: 2024})
      end

      assert :ok = MetadataRefresh.run_all(fn _item -> {:error, :relay_unavailable} end)

      assert [event] = Events.list_events(category: "system", type: "job.failed")
      assert event.metadata["job_name"] == "metadata_refresh"
      assert event.metadata["total"] == 3
      assert event.metadata["succeeded"] == 0
      assert event.metadata["failed"] == 3
    end

    test "emits no event when every item succeeds" do
      item = media_item_fixture(%{type: "movie", title: "Fine", year: 2024})

      assert :ok = MetadataRefresh.run_all(fn _item -> {:ok, item} end)

      assert [] = Events.list_events(category: "system", type: "job.failed")
    end
  end
end
