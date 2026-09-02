defmodule Mydia.Jobs.ErrorLoggerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mydia.Jobs.ErrorLogger

  setup do
    _ = ErrorLogger.detach()
    :ok = ErrorLogger.attach()
    on_exit(fn -> ErrorLogger.detach() end)
    :ok
  end

  test "logs the worker, attempt and reason for a failed job" do
    job = %Oban.Job{
      id: 554_560,
      worker: "Mydia.Jobs.TVShowSearch",
      args: %{"mode" => "show"},
      attempt: 3,
      max_attempts: 3
    }

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:oban, :job, :exception],
          %{duration: 1_000},
          %{
            job: job,
            kind: :error,
            reason: %ArgumentError{message: ~s(invalid scheme "magnet")},
            stacktrace: []
          }
        )
      end)

    assert log =~ "Mydia.Jobs.TVShowSearch"
    assert log =~ "3/3"
    assert log =~ "invalid scheme"
  end
end
