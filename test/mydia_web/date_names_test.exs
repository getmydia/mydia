defmodule MydiaWeb.DateNamesTest do
  use ExUnit.Case, async: true

  alias MydiaWeb.DateNames

  @months ~w(January February March April May June July August September October November December)
  @month_abbrs ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  @weekdays ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
  @weekday_abbrs ~w(Mon Tue Wed Thu Fri Sat Sun)

  setup do
    Gettext.put_locale(MydiaWeb.Gettext, "en")
    :ok
  end

  test "full names in English for a known date" do
    assert Calendar.strftime(~D[2026-10-24], "%A %d %B", DateNames.strftime_opts()) ==
             "Saturday 24 October"
  end

  test "month names match the English names exactly" do
    for {name, month} <- Enum.with_index(@months, 1) do
      date = Date.new!(2026, month, 1)
      assert Calendar.strftime(date, "%B", DateNames.strftime_opts()) == name

      assert Calendar.strftime(date, "%B", DateNames.strftime_opts()) ==
               Calendar.strftime(date, "%B")
    end
  end

  test "abbreviated month names match exactly" do
    for {name, month} <- Enum.with_index(@month_abbrs, 1) do
      date = Date.new!(2026, month, 1)
      assert Calendar.strftime(date, "%b", DateNames.strftime_opts()) == name

      assert Calendar.strftime(date, "%b", DateNames.strftime_opts()) ==
               Calendar.strftime(date, "%b")
    end
  end

  test "weekday names match the English names exactly" do
    # 2026-10-19 is a Monday.
    for {name, offset} <- Enum.with_index(@weekdays) do
      date = Date.add(~D[2026-10-19], offset)
      assert Calendar.strftime(date, "%A", DateNames.strftime_opts()) == name

      assert Calendar.strftime(date, "%A", DateNames.strftime_opts()) ==
               Calendar.strftime(date, "%A")
    end
  end

  test "abbreviated weekday names match exactly" do
    for {name, offset} <- Enum.with_index(@weekday_abbrs) do
      date = Date.add(~D[2026-10-19], offset)
      assert Calendar.strftime(date, "%a", DateNames.strftime_opts()) == name

      assert Calendar.strftime(date, "%a", DateNames.strftime_opts()) ==
               Calendar.strftime(date, "%a")
    end
  end
end
