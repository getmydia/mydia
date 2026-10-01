defmodule Mydia.Jobs.BroadcasterTest do
  # async: false: these events land in the application's own StatusTracker,
  # which every other test shares.
  use Mydia.DataCase, async: false

  alias Mydia.Jobs.Broadcaster
  alias Mydia.Jobs.StatusTracker

  @job %Oban.Job{
    id: 771_203,
    worker: "Mydia.Jobs.LibraryScanner",
    queue: "default",
    args: %{},
    attempt: 1,
    max_attempts: 3
  }

  # :sys.get_state/1 is a call, so it also waits for the casts ahead of it.
  defp tracked?, do: Map.has_key?(:sys.get_state(StatusTracker).jobs, @job.id)

  setup do
    on_exit(fn -> StatusTracker.job_finished(@job) end)
    :ok
  end

  test "a start event registers the job with the tracker" do
    Broadcaster.handle_event([:oban, :job, :start], %{}, %{job: @job}, nil)

    assert tracked?()
  end

  test "a stop event removes it" do
    Broadcaster.handle_event([:oban, :job, :start], %{}, %{job: @job}, nil)
    Broadcaster.handle_event([:oban, :job, :stop], %{duration: 1}, %{job: @job}, nil)

    refute tracked?()
  end

  test "an exception event removes it" do
    Broadcaster.handle_event([:oban, :job, :start], %{}, %{job: @job}, nil)

    Broadcaster.handle_event(
      [:oban, :job, :exception],
      %{duration: 1},
      %{job: @job, kind: :error, reason: %RuntimeError{message: "boom"}, stacktrace: []},
      nil
    )

    refute tracked?()
  end

  test "a start event does not broadcast" do
    Broadcaster.subscribe()

    Broadcaster.handle_event([:oban, :job, :start], %{}, %{job: @job}, nil)
    Broadcaster.handle_event([:oban, :job, :stop], %{duration: 1}, %{job: @job}, nil)

    refute_receive {:jobs_status_changed, _}, 100
  end
end
