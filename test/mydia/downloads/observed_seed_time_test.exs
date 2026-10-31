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

    test "a gap longer than the cap credits nothing, so downtime is not counted" do
      entry = ObservedSeedTime.step(nil, true, @t0)
      assert ObservedSeedTime.step(entry, true, at(360))["seconds"] == 360

      after_gap = ObservedSeedTime.step(entry, true, at(361))
      assert after_gap["seconds"] == 0
      assert ObservedSeedTime.step(after_gap, true, at(481))["seconds"] == 120
    end

    test "an out-of-order pass credits nothing and keeps the later timestamp" do
      entry = ObservedSeedTime.step(ObservedSeedTime.step(nil, true, @t0), true, at(120))
      assert entry["seconds"] == 120

      # An overlapping pass that started earlier writes after the later one.
      late = ObservedSeedTime.step(entry, true, at(60))
      assert late == entry

      # The next pass credits only the time since the latest one: no double credit.
      assert ObservedSeedTime.step(late, true, at(240))["seconds"] == 240
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

    test "keeps metadata another writer added after the row was polled" do
      download = download_fixture(%{metadata: %{"tracker_terms" => @terms}})
      polled = row(download, %{})

      {:ok, _} =
        Mydia.Downloads.update_download(download, %{
          metadata: Map.put(download.metadata, "other_writer", true)
        })

      :ok = ObservedSeedTime.record([polled], @t0)

      assert metadata(download)["other_writer"] == true
      assert %{"seconds" => 0} = metadata(download)["observed_seeding"]
    end

    test "a stale snapshot of a seeding torrent does not count as seeding" do
      download = download_fixture(%{metadata: %{"tracker_terms" => @terms}})

      :ok = ObservedSeedTime.record([row(download, %{status_as_of: @t0})], @t0)

      refute Map.has_key?(metadata(download), "observed_seeding")
    end

    test "a failing row does not skip the rows after it" do
      download = download_fixture(%{metadata: %{"tracker_terms" => @terms}})

      failing = %{
        id: nil,
        status: "seeding",
        seeding_time: nil,
        metadata: %{"tracker_terms" => @terms}
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = ObservedSeedTime.record([failing, row(download, %{})], @t0)
        end)

      assert log =~ "Recording observed seed time failed"
      assert %{"seconds" => 0, "last_seen_at" => _} = metadata(download)["observed_seeding"]
    end

    test "a failure is logged and does not raise" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   ObservedSeedTime.record(
                     [
                       %{
                         id: nil,
                         status: "seeding",
                         seeding_time: nil,
                         metadata: %{"tracker_terms" => @terms}
                       }
                     ],
                     @t0
                   )
        end)

      assert log =~ "Recording observed seed time failed"
    end

    test "does not start counting for a torrent that is not seeding" do
      download = download_fixture(%{metadata: %{"tracker_terms" => @terms}})

      :ok = ObservedSeedTime.record([row(download, %{status: "paused"})], @t0)

      refute Map.has_key?(metadata(download), "observed_seeding")
    end
  end
end
