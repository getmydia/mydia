defmodule Mydia.Jobs.StatusTrackerTest do
  # async: false for two reasons. Every tracker broadcasts on the one shared
  # "jobs:status" topic, so concurrent tests would read each other's messages.
  # And the reconcile tests need the tracker process to see this test's
  # sandbox connection, which DataCase only shares when the test is not async.
  use Mydia.DataCase, async: false

  alias Mydia.Jobs.Broadcaster
  alias Mydia.Jobs.StatusTracker

  @show_after_ms 50
  @min_visible_ms 200

  setup do
    Broadcaster.subscribe()
    :ok
  end

  defp start_tracker(opts \\ []) do
    name = :"status_tracker_#{System.unique_integer([:positive])}"

    opts =
      Keyword.merge(
        [
          name: name,
          show_after_ms: @show_after_ms,
          min_visible_ms: @min_visible_ms,
          reconcile_ms: 60_000
        ],
        opts
      )

    start_supervised!({StatusTracker, opts})
    name
  end

  defp job(id), do: %Oban.Job{id: id, worker: "Mydia.Jobs.LibraryScanner"}

  defp insert_executing_job do
    %{}
    |> Oban.Job.new(worker: Mydia.Jobs.LibraryScanner, queue: :default)
    |> Ecto.Changeset.change(state: "executing", attempted_at: DateTime.utc_now())
    |> Repo.insert!()
  end

  test "a job that finishes before the delay is never shown" do
    tracker = start_tracker()

    StatusTracker.job_started(tracker, job(1))
    StatusTracker.job_finished(tracker, job(1))

    refute_receive {:jobs_status_changed, _}, @show_after_ms * 3
    assert StatusTracker.visible_jobs(tracker) == []
  end

  test "a job that outlives the delay is shown" do
    tracker = start_tracker()

    StatusTracker.job_started(tracker, job(1))
    assert StatusTracker.visible_jobs(tracker) == []

    assert_receive {:jobs_status_changed, [%{id: 1, worker_name: "Library scanner"}]}, 500

    assert [%{id: 1, worker: "Mydia.Jobs.LibraryScanner", attempted_at: %DateTime{}}] =
             StatusTracker.visible_jobs(tracker)
  end

  test "a job that ends right after being shown is held for the minimum time" do
    tracker = start_tracker()

    StatusTracker.job_started(tracker, job(1))
    assert_receive {:jobs_status_changed, [%{id: 1}]}, 500

    StatusTracker.job_finished(tracker, job(1))

    refute_receive {:jobs_status_changed, []}, div(@min_visible_ms, 2)
    assert [%{id: 1}] = StatusTracker.visible_jobs(tracker)

    assert_receive {:jobs_status_changed, []}, 500
    assert StatusTracker.visible_jobs(tracker) == []
  end

  test "overlapping jobs never empty the list between them" do
    tracker = start_tracker()

    StatusTracker.job_started(tracker, job(1))
    assert_receive {:jobs_status_changed, [%{id: 1}]}, 500

    StatusTracker.job_started(tracker, job(2))
    assert_receive {:jobs_status_changed, [%{id: 1}, %{id: 2}]}, 500

    StatusTracker.job_finished(tracker, job(1))
    assert_receive {:jobs_status_changed, [%{id: 2}]}, 500
    refute_received {:jobs_status_changed, []}

    StatusTracker.job_finished(tracker, job(2))
    assert_receive {:jobs_status_changed, []}, 500
  end

  test "a job crossing the delay during a hold replaces the held list" do
    tracker = start_tracker()

    StatusTracker.job_started(tracker, job(1))
    assert_receive {:jobs_status_changed, [%{id: 1}]}, 500

    StatusTracker.job_started(tracker, job(2))
    StatusTracker.job_finished(tracker, job(1))

    assert_receive {:jobs_status_changed, [%{id: 2}]}, 500
    refute_received {:jobs_status_changed, []}
  end

  test "reconcile drops a tracked job that is no longer executing in the database" do
    tracker = start_tracker(reconcile_ms: 100)

    # No oban_jobs row has this id: its stop event was lost.
    StatusTracker.job_started(tracker, job(987_654_321))
    assert_receive {:jobs_status_changed, [%{id: 987_654_321}]}, 500

    assert_receive {:jobs_status_changed, []}, 1_000
  end

  test "reconcile keeps a tracked job that is still executing" do
    tracker = start_tracker(reconcile_ms: 100)
    row = insert_executing_job()

    StatusTracker.job_started(tracker, job(row.id))
    assert_receive {:jobs_status_changed, [%{id: id}]}, 500
    assert id == row.id

    refute_receive {:jobs_status_changed, []}, 400
  end

  test "visible_jobs/1 is empty when the tracker is not running" do
    assert StatusTracker.visible_jobs(:status_tracker_that_does_not_exist) == []
  end
end
