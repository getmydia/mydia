defmodule Mydia.Downloads.ObservedSeedTimeTest do
  use Mydia.DataCase, async: true

  import Mydia.DownloadsFixtures

  alias Mydia.Downloads.{Download, ObservedSeedTime}
  alias Mydia.Repo

  @t0 ~U[2031-05-10 12:00:00Z]
  @terms %{"private" => true, "minimum_seed_time" => 3 * 86_400}

  defp at(seconds), do: DateTime.add(@t0, seconds, :second)

  describe "step/3" do
    test "adds the time between two passes that both saw the torrent seeding" do
      first = ObservedSeedTime.step(nil, true, @t0)
      assert first["seconds"] == 0

      second = ObservedSeedTime.step(first, true, at(120))
      assert second["seconds"] == 120

      third = ObservedSeedTime.step(second, true, at(135))
      assert third["seconds"] == 135
    end

    test "caps one step so downtime is not counted" do
      entry = ObservedSeedTime.step(nil, true, @t0)
      assert ObservedSeedTime.step(entry, true, at(6 * 3600))["seconds"] == 360
    end

    test "a pass that sees the torrent not seeding keeps the total and stops the clock" do
      entry = ObservedSeedTime.step(ObservedSeedTime.step(nil, true, @t0), true, at(120))
      stopped = ObservedSeedTime.step(entry, false, at(240))

      assert stopped == %{"seconds" => 120, "last_seen_at" => nil}

      # Resuming starts a new interval rather than counting the paused time.
      resumed = ObservedSeedTime.step(stopped, true, at(10_000))
      assert resumed["seconds"] == 120
      assert ObservedSeedTime.step(resumed, true, at(10_120))["seconds"] == 240
    end
  end

  describe "seconds/1" do
    test "reads the total, or nil when Mydia never counted" do
      assert ObservedSeedTime.seconds(%{metadata: %{"observed_seeding" => %{"seconds" => 42}}}) ==
               42

      assert ObservedSeedTime.seconds(%{metadata: %{}}) == nil
      assert ObservedSeedTime.seconds(%{metadata: nil}) == nil
    end
  end

  describe "record/2" do
    defp row(download, attrs) do
      Map.merge(
        %{id: download.id, metadata: download.metadata, status: "seeding", seeding_time: nil},
        attrs
      )
    end

    defp metadata(download), do: Repo.get!(Download, download.id).metadata

    test "accumulates for a guarded download whose client reports no seed time" do
      download = download_fixture(%{metadata: %{"tracker_terms" => @terms, "quality" => "x"}})

      :ok = ObservedSeedTime.record([row(download, %{})], @t0)
      reloaded = Repo.get!(Download, download.id)

      :ok = ObservedSeedTime.record([row(reloaded, %{})], at(120))

      assert %{"seconds" => 120} = metadata(download)["observed_seeding"]
      assert metadata(download)["quality"] == "x"
      assert metadata(download)["tracker_terms"] == @terms
    end

    test "leaves rows alone when the client reports seed time or no goal applies" do
      reported = download_fixture(%{metadata: %{"tracker_terms" => @terms}})
      no_goal = download_fixture(%{metadata: %{}})

      :ok =
        ObservedSeedTime.record(
          [row(reported, %{seeding_time: 500}), row(no_goal, %{})],
          @t0
        )

      refute Map.has_key?(metadata(reported), "observed_seeding")
      refute Map.has_key?(metadata(no_goal), "observed_seeding")
    end

    test "does not start counting for a torrent that is not seeding" do
      download = download_fixture(%{metadata: %{"tracker_terms" => @terms}})

      :ok = ObservedSeedTime.record([row(download, %{status: "paused"})], @t0)

      refute Map.has_key?(metadata(download), "observed_seeding")
    end
  end
end
