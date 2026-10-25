defmodule MydiaWeb.RelativeTimeTest do
  use ExUnit.Case, async: true

  alias MydiaWeb.RelativeTime

  @now ~U[2026-10-24 12:00:00Z]

  setup do
    Gettext.put_locale(MydiaWeb.Gettext, "en")
    :ok
  end

  defp past(seconds), do: RelativeTime.from_now(DateTime.add(@now, -seconds), @now)
  defp future(seconds), do: RelativeTime.from_now(DateTime.add(@now, seconds), @now)

  test "past boundaries" do
    assert past(0) == "just now"
    assert past(59) == "just now"
    assert past(60) == "1 minute ago"
    assert past(119) == "1 minute ago"
    assert past(120) == "2 minutes ago"
    assert past(3_599) == "59 minutes ago"
    assert past(3_600) == "1 hour ago"
    assert past(7_200) == "2 hours ago"
    assert past(86_399) == "23 hours ago"
    assert past(86_400) == "1 day ago"
    assert past(29 * 86_400) == "29 days ago"
    assert past(30 * 86_400) == "1 month ago"
    assert past(90 * 86_400) == "3 months ago"
    assert past(364 * 86_400) == "12 months ago"
    assert past(365 * 86_400) == "1 year ago"
    assert past(800 * 86_400) == "2 years ago"
  end

  test "future boundaries" do
    assert future(1) == "in 1 second"
    assert future(59) == "in 59 seconds"
    assert future(60) == "in 1 minute"
    assert future(3_599) == "in 59 minutes"
    assert future(3_600) == "in 1 hour"
    assert future(86_399) == "in 23 hours"
    assert future(86_400) == "in 1 day"
    assert future(30 * 86_400) == "in 1 month"
    assert future(365 * 86_400) == "in 1 year"
    assert future(800 * 86_400) == "in 2 years"
  end

  test "reads a naive datetime as UTC" do
    assert RelativeTime.from_now(~N[2026-10-24 11:55:00], @now) == "5 minutes ago"
  end

  test "defaults to the current time" do
    assert RelativeTime.from_now(DateTime.add(DateTime.utc_now(), -2 * 3_600)) == "2 hours ago"
  end
end
