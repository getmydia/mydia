defmodule Mydia.CrashReporter.TowerReporterTest do
  use Mydia.DataCase, async: false

  alias Mydia.CrashReporter.{Queue, Throttle, TowerReporter}

  setup do
    # Inject a high-cap throttle so mapping tests are never throttled, and so we
    # never touch the application-wide singleton's shared state.
    name = :"reporter_throttle_#{System.unique_integer([:positive])}"
    start_supervised!({Throttle, name: name, max: 1000, window_ms: 60_000})
    Application.put_env(:mydia, :crash_reporter_throttle, name)

    # Opt-in must be visible to the async reporting Task (a separate process).
    # DataCase (shared sandbox) lets that Task query config_settings safely;
    # the env var remains the source of truth when no UI setting row exists.
    # Point the relay at an unreachable address so the background queue
    # processor can never POST to the real relay during the test.
    original_enabled = System.get_env("CRASH_REPORTING_ENABLED")
    System.put_env("CRASH_REPORTING_ENABLED", "true")
    original_relay = System.get_env("METADATA_RELAY_URL")
    System.put_env("METADATA_RELAY_URL", "http://127.0.0.1:1")
    Queue.clear_all()

    on_exit(fn ->
      Application.delete_env(:mydia, :crash_reporter_throttle)

      case original_enabled do
        nil -> System.delete_env("CRASH_REPORTING_ENABLED")
        val -> System.put_env("CRASH_REPORTING_ENABLED", val)
      end

      case original_relay do
        nil -> System.delete_env("METADATA_RELAY_URL")
        url -> System.put_env("METADATA_RELAY_URL", url)
      end

      Queue.clear_all()
    end)

    :ok
  end

  @synthetic_stack [
    {Mydia.Synthetic, :boom, 1, [file: ~c"lib/mydia/synthetic.ex", line: 42]}
  ]

  test "an :error event is reported with the exception type, message, and crash site" do
    event(
      kind: :error,
      reason: %RuntimeError{message: "boom"},
      stacktrace: @synthetic_stack,
      metadata: %{request_id: "req-abc"}
    )
    |> TowerReporter.report_event()

    report = wait_for_report()

    assert report.error_type == "RuntimeError"
    assert report.error_message =~ "boom"
    assert report.metadata.file == "lib/mydia/synthetic.ex"
    assert report.metadata.line == 42
    assert report.metadata.function == "boom/1"
    assert report.metadata.module == "Mydia.Synthetic"
    assert report.metadata.request_id == "req-abc"
  end

  test "an :exit event gets a distinct type and formatted message" do
    event(kind: :exit, reason: :killed, stacktrace: [])
    |> TowerReporter.report_event()

    report = wait_for_report()

    assert report.error_type == "Mydia.CrashReporter.ExitError"
    assert report.error_message =~ "(exit)"
    assert report.error_message =~ "killed"
  end

  test "a :throw event gets a distinct type and formatted message" do
    event(kind: :throw, reason: {:not_found, 7}, stacktrace: [])
    |> TowerReporter.report_event()

    report = wait_for_report()

    assert report.error_type == "Mydia.CrashReporter.ThrowError"
    assert report.error_message =~ "(throw)"
  end

  test "a :message event is never forwarded" do
    assert :ok ==
             event(kind: :message, reason: "just a log line", stacktrace: nil)
             |> TowerReporter.report_event()

    refute wait_until(fn -> Queue.count() >= 1 end, 300)
    assert Queue.count() == 0
  end

  test "non-JSON-encodable event metadata still yields an encodable report" do
    # Tower metadata can carry pids/structs; the reporter must not forward them.
    event(
      kind: :error,
      reason: %RuntimeError{message: "x"},
      stacktrace: @synthetic_stack,
      metadata: %{process: %{pid: self()}, conn: %URI{}}
    )
    |> TowerReporter.report_event()

    report = wait_for_report()

    assert is_binary(Jason.encode!(report))
  end

  test "reports beyond the throttle cap are dropped" do
    name = :"deny_throttle_#{System.unique_integer([:positive])}"
    start_supervised!({Throttle, name: name, max: 1, window_ms: 60_000})
    Application.put_env(:mydia, :crash_reporter_throttle, name)

    # Consume the only grant in the window.
    assert Throttle.allow?(name)

    event(kind: :error, reason: %RuntimeError{message: "dropped"}, stacktrace: @synthetic_stack)
    |> TowerReporter.report_event()

    refute wait_until(fn -> Queue.count() >= 1 end, 300)
    assert Queue.count() == 0
  end

  test "the queued report carries exactly the relay payload key set" do
    event(kind: :error, reason: %RuntimeError{message: "shape"}, stacktrace: @synthetic_stack)
    |> TowerReporter.report_event()

    report = wait_for_report()

    assert MapSet.new(Map.keys(report)) ==
             MapSet.new([
               :error_type,
               :error_message,
               :stacktrace,
               :version,
               :elixir_version,
               :otp_version,
               :environment,
               :occurred_at,
               :metadata
             ])
  end

  defp event(attrs), do: struct(Tower.Event, Keyword.put_new(attrs, :metadata, %{}))

  defp wait_for_report do
    assert wait_until(fn -> Queue.count() >= 1 end)
    [%{report: report} | _] = Queue.list_all()
    report
  end

  defp wait_until(fun, deadline_ms \\ 2_000, step_ms \\ 25)
  defp wait_until(_fun, deadline_ms, _step) when deadline_ms <= 0, do: false

  defp wait_until(fun, deadline_ms, step_ms) do
    if fun.() do
      true
    else
      Process.sleep(step_ms)
      wait_until(fun, deadline_ms - step_ms, step_ms)
    end
  end
end
