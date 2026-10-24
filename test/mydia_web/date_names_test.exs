defmodule MydiaWeb.DateNamesTest do
  use ExUnit.Case, async: true

  alias MydiaWeb.DateNames

  setup do
    Gettext.put_locale(MydiaWeb.Gettext, "en")
    :ok
  end

  test "full names in English" do
    assert Calendar.strftime(~D[2026-10-24], "%A %d %B", DateNames.strftime_opts()) ==
             "Saturday 24 October"
  end

  test "abbreviated names in English" do
    assert Calendar.strftime(~D[2026-03-02], "%a %b", DateNames.strftime_opts()) == "Mon Mar"
  end

  test "every month and weekday resolves" do
    for m <- 1..12 do
      date = Date.new!(2026, m, 1)
      assert Calendar.strftime(date, "%B %b", DateNames.strftime_opts()) =~ ~r/\w+ \w+/
    end

    for d <- 1..7 do
      date = Date.add(~D[2026-10-19], d - 1)
      assert Calendar.strftime(date, "%A %a", DateNames.strftime_opts()) =~ ~r/\w+ \w+/
    end
  end
end
