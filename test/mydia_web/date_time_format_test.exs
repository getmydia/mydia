defmodule MydiaWeb.DateTimeFormatTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]

  alias Mydia.TimeDisplay
  alias MydiaWeb.DateTimeFormat

  @rome24 %TimeDisplay{time_zone: "Europe/Rome", clock: :h24}
  @rome12 %TimeDisplay{time_zone: "Europe/Rome", clock: :h12}
  # 12:58 UTC on 2026-10-22 is 14:58 CEST (UTC+2).
  @summer ~U[2026-10-22 12:58:07Z]
  # 12:58 UTC on 2026-10-26 is 13:58 CET (UTC+1), after the October change.
  @winter ~U[2026-10-26 12:58:07Z]

  describe "format/3" do
    test "every preset on a 24-hour clock" do
      assert DateTimeFormat.format(@summer, :date, @rome24) == "Oct 22, 2026"
      assert DateTimeFormat.format(@summer, :month_day, @rome24) == "Oct 22"
      assert DateTimeFormat.format(@summer, :time, @rome24) == "14:58"
      assert DateTimeFormat.format(@summer, :time_seconds, @rome24) == "14:58:07"
      assert DateTimeFormat.format(@summer, :datetime, @rome24) == "Oct 22, 2026, 14:58"

      assert DateTimeFormat.format(@summer, :datetime_full, @rome24) ==
               "Oct 22, 2026, 14:58:07 CEST"
    end

    test "12-hour clock has no leading zero" do
      assert DateTimeFormat.format(@summer, :time, @rome12) == "2:58 PM"
      assert DateTimeFormat.format(@summer, :time_seconds, @rome12) == "2:58:07 PM"
      assert DateTimeFormat.format(@summer, :datetime, @rome12) == "Oct 22, 2026, 2:58 PM"
    end

    test "daylight saving time is applied per instant" do
      assert DateTimeFormat.format(@winter, :time, @rome24) == "13:58"
      assert DateTimeFormat.format(@winter, :datetime_full, @rome24) =~ "CET"
    end

    test "shifting can move the calendar date" do
      late = ~U[2026-10-22 23:30:00Z]
      assert DateTimeFormat.format(late, :date, @rome24) == "Oct 23, 2026"
    end

    test "NaiveDateTime is treated as UTC" do
      assert DateTimeFormat.format(~N[2026-10-22 12:58:07], :time, @rome24) == "14:58"
    end

    test "Date is never shifted and rejects time presets" do
      assert DateTimeFormat.format(~D[2026-10-22], :date, @rome24) == "Oct 22, 2026"

      assert_raise ArgumentError, fn ->
        DateTimeFormat.format(~D[2026-10-22], :time, @rome24)
      end
    end

    test "nil renders a dash" do
      assert DateTimeFormat.format(nil, :datetime, @rome24) == "—"
    end
  end

  describe "local_time/1" do
    test "renders a <time> with the UTC instant and a full title" do
      assigns = %{at: @summer, display: @rome24}

      html =
        rendered_to_string(~H"""
        <DateTimeFormat.local_time at={@at} format={:time} display={@display} />
        """)

      assert html =~ ~s(datetime="2026-10-22T12:58:07Z")
      assert html =~ ~s(title="Oct 22, 2026, 14:58:07 CEST")
      assert html =~ ">14:58</time>"
    end
  end
end
