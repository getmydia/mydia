defmodule Mydia.Indexers.CardigannTemplateLoggingTest do
  # Split out of cardigann_template_test.exs so it can run without async.
  #
  # config/test.exs runs the suite at :warning, where the Logger.info/2 call
  # under test is skipped outright and capture_log's :level option cannot
  # bring it back, so the level has to be raised globally. The old test inside
  # an async module captured "" and accepted that, which meant it could only
  # ever fail: capture_log sees every process's output, and on the PostgreSQL
  # job other modules' warnings landed in the capture.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mydia.Indexers.CardigannTemplate

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)
  end

  test "logs info on parse error" do
    log =
      capture_log(fn ->
        CardigannTemplate.render("{{ .incomplete", %{})
      end)

    assert log =~ "Template parse failed"
  end
end
