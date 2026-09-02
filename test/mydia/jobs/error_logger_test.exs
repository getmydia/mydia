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

  @job %Oban.Job{
    id: 554_560,
    worker: "Mydia.Jobs.TVShowSearch",
    args: %{"mode" => "show"},
    attempt: 3,
    max_attempts: 3
  }

  @event_metadata %{
    job: @job,
    kind: :error,
    reason: %ArgumentError{message: ~s(invalid scheme "magnet")},
    stacktrace: []
  }

  test "attach/0 wires the handler to real Oban telemetry dispatch" do
    log =
      capture_log(fn ->
        :telemetry.execute([:oban, :job, :exception], %{duration: 1_000}, @event_metadata)
      end)

    # Mydia.CrashReporter.TowerReporter also listens on this event and dumps
    # the raw metadata (worker name included) into its own warning line, so
    # this only proves attach/0 reaches handle_event/4 through the real
    # telemetry pipeline. It does not prove where the failure reason ends up;
    # see the test below for that.
    assert log =~ "Mydia.Jobs.TVShowSearch"
    assert log =~ "3/3"
  end

  test "the failure reason is in the log message, not only in metadata" do
    # Calling handle_event/4 directly, instead of going through
    # :telemetry.execute/3, isolates this module's own log line.
    # Mydia.Jobs.Broadcaster and Mydia.CrashReporter.TowerReporter both also
    # attach to [:oban, :job, :exception]; going through the real dispatch
    # here would mix their output into the capture. Tower in particular logs
    # a raw inspect of the full event metadata (reason included) as its own
    # message text, which previously made `log =~ "invalid scheme"` pass
    # against this module's OLD code even though that code never put the
    # reason anywhere but an unwhitelisted :oban_error metadata key, which
    # config/config.exs and config/dev.exs never render. This test proves
    # only what this module's own handler writes.
    log =
      capture_log(fn ->
        ErrorLogger.handle_event(
          [:oban, :job, :exception],
          %{duration: 1_000},
          @event_metadata,
          nil
        )
      end)

    # The default formatter is "$time $metadata[$level] $message\n", so
    # everything after "[error] " is this line's :message, and everything
    # before it is :time plus whatever :metadata keys are on the app's
    # whitelist (config/config.exs, config/dev.exs). None of this module's
    # oban_* keys are on that whitelist, so if the reason only reached
    # Logger via metadata, it would not appear past this split.
    [_prefix, message] = String.split(log, "[error] ", parts: 2)

    assert message =~ "invalid scheme"
  end
end
