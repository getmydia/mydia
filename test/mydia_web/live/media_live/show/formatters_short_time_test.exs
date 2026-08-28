defmodule MydiaWeb.MediaLive.Show.FormattersShortTimeTest do
  @moduledoc """
  The rail puts the relative time on the same baseline as the event title in a
  20rem column. "3 hours ago" wraps there, and the wrap is what made each row
  156px tall, which in turn forced the rail's inner scrollbar.
  """

  use ExUnit.Case, async: true

  import MydiaWeb.MediaLive.Show.Formatters, only: [format_relative_time_short: 1]

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  test "under a minute reads now" do
    assert format_relative_time_short(ago(30)) == "now"
  end

  test "minutes" do
    assert format_relative_time_short(ago(300)) == "5m"
  end

  test "hours" do
    assert format_relative_time_short(ago(3 * 3600)) == "3h"
  end

  test "days" do
    assert format_relative_time_short(ago(2 * 86_400)) == "2d"
  end

  test "months" do
    assert format_relative_time_short(ago(7 * 2_592_000)) == "7mo"
  end

  test "years" do
    assert format_relative_time_short(ago(2 * 31_536_000)) == "2y"
  end

  test "never emits a unit longer than two characters" do
    # The time sits in a `shrink-0` cell next to a `truncate` title, so a long
    # unit steals width from the title rather than wrapping.
    for seconds <- [30, 300, 3 * 3600, 2 * 86_400, 7 * 2_592_000, 2 * 31_536_000] do
      formatted = format_relative_time_short(ago(seconds))
      assert String.length(formatted) <= 5, "#{formatted} is too wide for the rail"
    end
  end
end
