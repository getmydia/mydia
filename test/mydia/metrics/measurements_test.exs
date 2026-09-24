defmodule Mydia.Metrics.MeasurementsTest do
  use Mydia.DataCase, async: false

  import ExUnit.CaptureLog
  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Metrics.Measurements

  setup do
    test_pid = self()
    handler = "measurements-test-#{System.unique_integer([:positive])}"

    events =
      for event <-
            ~w(vm_memory vm_run_queue vm_processes uptime build_info library_items library_episodes
               library_media_files library_size downloads download_client_up oban_jobs
               hls_sessions direct_play_sessions)a,
          do: [:mydia, :metrics, event]

    :telemetry.attach_many(
      handler,
      events,
      fn [:mydia, :metrics, event], measurements, meta, _ ->
        send(test_pid, {:metric, event, measurements.value, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "vm/0 emits memory by kind, run queue, process count and uptime" do
    Measurements.vm()

    for kind <- ~w(total processes binary ets atom) do
      assert_received {:metric, :vm_memory, bytes, %{kind: ^kind}} when bytes > 0
    end

    assert_received {:metric, :vm_run_queue, _, %{}}
    assert_received {:metric, :vm_processes, count, %{}} when count > 0
    assert_received {:metric, :uptime, _, %{}}
  end

  test "build_info/0 emits 1 labelled with the version" do
    Measurements.build_info()
    version = Mydia.System.app_version()
    assert_received {:metric, :build_info, 1, %{version: ^version}}
  end

  test "library/0 emits item, episode, file and size gauges, zero-filled" do
    media_item_fixture(%{type: "movie", title: "Quiet Meridian"})
    show = media_item_fixture(%{type: "tv_show", title: "The Salt Orchard"})
    episode_fixture(%{media_item_id: show.id, air_date: ~D[2020-01-01]})

    Measurements.library()

    assert_received {:metric, :library_items, 1, %{type: "movie"}}
    assert_received {:metric, :library_items, 1, %{type: "tv_show"}}
    assert_received {:metric, :library_episodes, 1, %{state: "missing", monitored: "true"}}
    assert_received {:metric, :library_episodes, 0, %{state: "downloaded", monitored: "true"}}
    assert_received {:metric, :library_media_files, 0, %{}}
    assert_received {:metric, :library_size, 0, %{}}
  end

  test "downloads/0 emits every derived state" do
    download_fixture()
    Measurements.downloads()

    assert_received {:metric, :downloads, 1, %{state: "active"}}
    assert_received {:metric, :downloads, 0, %{state: "failed"}}
    assert_received {:metric, :downloads, 0, %{state: "awaiting_import"}}
  end

  test "oban/0 zero-fills every configured queue and pending state" do
    # config/test.exs sets `queues: false`, so nothing is statically
    # configured here; insert a job so `default` has something to zero-fill
    # around, and assert its count directly.
    %{}
    |> Oban.Job.new(worker: "Mydia.Metrics.FakeWorker", queue: "default")
    |> Repo.insert!()

    Measurements.oban()

    assert_received {:metric, :oban_jobs, 1, %{queue: "default", state: "available"}}
    assert_received {:metric, :oban_jobs, 0, %{queue: "default", state: "retryable"}}
  end

  test "streaming/0 emits all four session gauges" do
    Measurements.streaming()

    assert_received {:metric, :hls_sessions, _, %{mode: "copy"}}
    assert_received {:metric, :hls_sessions, _, %{mode: "transcode"}}
    assert_received {:metric, :direct_play_sessions, _, %{kind: "direct"}}
    assert_received {:metric, :direct_play_sessions, _, %{kind: "remux"}}
  end

  test "download_clients/0 runs without a configured client" do
    assert Measurements.download_clients() == :ok
  end

  test "a failing family logs a warning and returns :ok instead of raising" do
    log =
      capture_log(fn ->
        assert Measurements.safely(:broken, fn -> raise "boom" end) == :ok
      end)

    assert log =~ "metrics measurement broken failed"
  end
end
