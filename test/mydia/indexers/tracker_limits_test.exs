defmodule Mydia.Indexers.TrackerLimitsTest do
  use Mydia.DataCase, async: false

  import Mydia.DownloadsFixtures

  alias Mydia.Downloads.Download
  alias Mydia.Indexers.{Adapter, RateLimiter, SearchResult, TrackerLimits}
  alias Mydia.Settings.TrackerRuleConfigs

  defp result(indexer, title) do
    %SearchResult{
      title: title,
      download_url: "magnet:?xt=urn:btih:#{:erlang.phash2({indexer, title})}",
      indexer: indexer,
      size: 1_000,
      seeders: 10,
      leechers: 0
    }
  end

  defp unique_tracker, do: "Velvet Lantern #{System.unique_integer([:positive])}"

  describe "RateLimiter rolling windows" do
    test "reserves slots inside the window and refuses at the limit" do
      key = {:test_window, System.unique_integer()}

      assert {:ok, 0} = RateLimiter.check_window(key, 2, 60_000)
      assert :ok = RateLimiter.reserve_window(key, 2, 60_000)
      assert :ok = RateLimiter.reserve_window(key, 2, 60_000)
      assert {:error, :limited, 2} = RateLimiter.reserve_window(key, 2, 60_000)
      # A refused reservation takes no slot.
      assert {:ok, 2} = RateLimiter.check_window(key, 3, 60_000)
    end

    test "slots older than the window no longer count" do
      key = {:test_window, System.unique_integer()}
      :ok = RateLimiter.reserve_window(key, 1, 60_000)
      Process.sleep(30)

      assert {:ok, 0} = RateLimiter.check_window(key, 1, 10)
    end
  end

  describe "guard_query/2" do
    test "searches without a rule" do
      assert {:ok, []} = TrackerLimits.guard_query(%{name: unique_tracker()}, fn -> {:ok, []} end)
    end

    test "searches under the cap and refuses at it without searching" do
      tracker = unique_tracker()
      {:ok, _} = TrackerRuleConfigs.create(%{tracker: tracker, query_limit: 2})
      config = %{name: String.upcase(tracker)}

      assert {:ok, :first} = TrackerLimits.guard_query(config, fn -> {:ok, :first} end)
      assert {:error, _} = TrackerLimits.guard_query(config, fn -> {:error, :down} end)

      assert {:error, %Adapter.Error{type: :rate_limited, message: message}} =
               TrackerLimits.guard_query(config, fn -> flunk("searched past the cap") end)

      assert message == "daily query limit reached (2/2)"
    end

    test "concurrent searches never take more than the last slot" do
      tracker = unique_tracker()
      {:ok, _} = TrackerRuleConfigs.create(%{tracker: tracker, query_limit: 3})
      config = %{name: tracker}

      # One serial search takes a slot, so two remain for the racers.
      assert {:ok, :ran} = TrackerLimits.guard_query(config, fn -> {:ok, :ran} end)

      # Racers may all back off (losers free their own slot), so only the
      # upper bound is an invariant.
      raced =
        1..19
        |> Enum.map(fn _ ->
          Task.async(fn -> TrackerLimits.guard_query(config, fn -> {:ok, :ran} end) end)
        end)
        |> Task.await_many()
        |> Enum.count(&(&1 == {:ok, :ran}))

      assert raced <= 2
    end

    test "a zero limit blocks every search" do
      tracker = unique_tracker()
      {:ok, _} = TrackerRuleConfigs.create(%{tracker: tracker, query_limit: 0})

      assert {:error, %Adapter.Error{type: :rate_limited}} =
               TrackerLimits.guard_query(%{name: tracker}, fn -> flunk("searched") end)
    end
  end

  describe "grab caps" do
    test "count grabs per tracker over the last 24 hours, ignoring case" do
      {:ok, _} = TrackerRuleConfigs.create(%{tracker: "Copper Owl", grab_limit: 2})
      download_fixture(%{indexer: "Copper Owl"})
      download_fixture(%{indexer: "copper owl"})

      old = download_fixture(%{indexer: "Copper Owl"})

      day_ago =
        DateTime.add(DateTime.utc_now(), -25 * 3600, :second) |> DateTime.truncate(:second)

      Repo.update_all(from(d in Download, where: d.id == ^old.id), set: [inserted_at: day_ago])

      assert TrackerLimits.grab_counts()["copper owl"] == 2
      assert TrackerLimits.grab_caps() == %{"copper owl" => {2, 2}}
    end

    test "a tracker under its cap or without one is not capped" do
      {:ok, _} = TrackerRuleConfigs.create(%{tracker: "Copper Owl", grab_limit: 3})
      download_fixture(%{indexer: "Copper Owl"})
      download_fixture(%{indexer: "Quiet Harbor"})

      assert TrackerLimits.grab_caps() == %{}
    end

    test "drop_capped/2 drops a capped tracker only for background searches" do
      {:ok, _} = TrackerRuleConfigs.create(%{tracker: "Copper Owl", grab_limit: 1})
      download_fixture(%{indexer: "Copper Owl"})

      capped = result("Copper Owl", "Invented.Feature.2021.1080p")
      other = result("Quiet Harbor", "Invented.Feature.2021.720p")

      assert TrackerLimits.drop_capped([capped, other], skip_capped_trackers: true) == [other]
      assert TrackerLimits.drop_capped([capped, other], []) == [capped, other]
    end
  end
end
