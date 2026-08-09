defmodule Mydia.CrashReporter.ReportResilienceTest do
  use ExUnit.Case, async: false

  alias Mydia.CrashReporter
  alias Mydia.CrashReporter.Queue

  # REGRESSION: TowerReporter spawns a Task that calls CrashReporter.report/3 →
  # enabled?/0 → config_settings. Under Postgres CI that Task collides with a
  # concurrent test's SQL-sandbox owner; when the owner has already stopped,
  # DBConnection raises an EXIT (not an exception). `rescue` alone did not catch
  # it, so the Task died before Queue.enqueue/1 — flaking TowerReporterTest on
  # master (CI runs 31301699784, 30970448718, …).
  setup do
    original_enabled = System.get_env("CRASH_REPORTING_ENABLED")
    System.put_env("CRASH_REPORTING_ENABLED", "true")
    original_relay = System.get_env("METADATA_RELAY_URL")
    System.put_env("METADATA_RELAY_URL", "http://127.0.0.1:1")
    original_lookup = Application.get_env(:mydia, :crash_reporter_ui_setting_fun)
    Queue.clear_all()

    on_exit(fn ->
      case original_enabled do
        nil -> System.delete_env("CRASH_REPORTING_ENABLED")
        val -> System.put_env("CRASH_REPORTING_ENABLED", val)
      end

      case original_relay do
        nil -> System.delete_env("METADATA_RELAY_URL")
        url -> System.put_env("METADATA_RELAY_URL", url)
      end

      if original_lookup do
        Application.put_env(:mydia, :crash_reporter_ui_setting_fun, original_lookup)
      else
        Application.delete_env(:mydia, :crash_reporter_ui_setting_fun)
      end

      Queue.clear_all()
    end)

    :ok
  end

  test "enabled?/0 falls back to the env var when the settings lookup exits" do
    Application.put_env(:mydia, :crash_reporter_ui_setting_fun, fn -> exit(:owner_exited) end)

    assert CrashReporter.enabled?() == true
  end

  test "report/3 still enqueues when the settings lookup exits" do
    Application.put_env(:mydia, :crash_reporter_ui_setting_fun, fn -> exit(:owner_exited) end)

    assert :ok =
             CrashReporter.report(%RuntimeError{message: "owner-exited boom"}, [], %{
               request_id: "resilience"
             })

    assert wait_until(fn -> Queue.count() >= 1 end)

    [%{report: report} | _] = Queue.list_all()
    assert report.error_type == "RuntimeError"
    assert report.error_message =~ "owner-exited boom"
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
