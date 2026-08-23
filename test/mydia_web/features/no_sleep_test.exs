defmodule MydiaWeb.Features.NoSleepTest do
  @moduledoc """
  Feature tests must synchronize, not sleep.

  Wallaby's `Query` assertions already retry until `:max_wait_time`
  (`Wallaby.Browser.retry/2`), so a sleep in a feature test is almost always
  a misunderstanding rather than a necessity. Before this guard the suite
  carried 10 of them, including a flat 3s in `wait_for_liveview/1` across 37
  call sites.

  For state Wallaby genuinely cannot observe, such as a database write a
  LiveView performs after the browser returns, use
  `MydiaWeb.FeatureCase.eventually/2`.

  Deliberately not tagged `:feature`: this needs no browser, so it runs in
  the default suite where a regression is caught immediately rather than
  only in the E2E job.
  """

  use ExUnit.Case, async: true

  @features_dir "test/mydia_web/features"

  test "no feature test calls :timer.sleep" do
    offenders =
      @features_dir
      |> Path.join("**/*.exs")
      |> Path.wildcard()
      |> Enum.reject(&String.ends_with?(&1, "no_sleep_test.exs"))
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _n} -> String.contains?(line, ":timer.sleep") end)
        |> Enum.map(fn {line, n} -> "#{path}:#{n}: #{String.trim(line)}" end)
      end)

    assert offenders == [],
           """
           Feature tests must synchronize rather than sleep.

           #{Enum.join(offenders, "\n")}

           Wallaby's Query assertions retry until :max_wait_time, so assert on
           the DOM state that proves the operation finished. For database state
           the browser cannot expose, use MydiaWeb.FeatureCase.eventually/2.
           """
  end

  test "the feature case support files do not sleep either" do
    offenders =
      ["test/support/feature_case.ex" | Path.wildcard("test/support/feature_case/**/*.ex")]
      |> Enum.filter(&String.contains?(File.read!(&1), ":timer.sleep"))

    assert offenders == [],
           "#{Enum.join(offenders, ", ")} must not sleep; eventually/2 and eval_js/3 " <>
             "use Process.sleep/1 deliberately"
  end
end
