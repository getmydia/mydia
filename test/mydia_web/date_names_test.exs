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

  describe "translated date patterns" do
    setup do
      on_exit(fn -> Gettext.put_locale(MydiaWeb.Gettext, "en") end)
    end

    test "English keeps the original order" do
      assert DateNames.month_year(~D[2026-10-24]) == "October 2026"
      assert DateNames.weekday_month_day(~D[2026-10-24]) == "Saturday, October 24"
      assert DateNames.short_date(~D[2026-03-04]) == "Mar 04, 2026"
      assert DateNames.short_date_unpadded(~D[2026-03-04]) == "Mar 4, 2026"
    end

    test "Spanish puts the day first with lowercase month names" do
      Gettext.put_locale(MydiaWeb.Gettext, "es")
      assert DateNames.month_year(~D[2026-10-24]) == "octubre de 2026"
      assert DateNames.weekday_month_day(~D[2026-10-24]) == "sábado, 24 de octubre"
      assert DateNames.short_date(~D[2026-03-04]) == "04 mar 2026"
      assert DateNames.short_date_unpadded(~D[2026-03-04]) == "4 mar 2026"
    end

    test "Portuguese puts the day first with lowercase month names" do
      Gettext.put_locale(MydiaWeb.Gettext, "pt_BR")
      assert DateNames.month_year(~D[2026-10-24]) == "outubro de 2026"
      assert DateNames.weekday_month_day(~D[2026-10-24]) == "sábado, 24 de outubro"
      assert DateNames.short_date_unpadded(~D[2026-03-04]) == "4 de mar de 2026"
    end
  end
end
