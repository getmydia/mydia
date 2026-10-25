defmodule MydiaWeb.DateNames do
  @moduledoc """
  Translated month and weekday names for `Calendar.strftime/3`.

  Pass `strftime_opts/0` as the third argument so `%B`, `%b`, `%A` and `%a`
  follow the current Gettext locale:

      Calendar.strftime(date, "%B %Y", MydiaWeb.DateNames.strftime_opts())

  The patterns themselves are translatable too (day-first in Spanish and
  Portuguese), through `month_year/1`, `weekday_month_day/1`, `short_date/1`
  and `short_date_unpadded/1`.
  """

  use Gettext, backend: MydiaWeb.Gettext

  @pattern_comment "strftime pattern: %B month, %b short month, %d day, %-d day without padding, %Y year, %A weekday, %a short weekday. Reorder or add words, keep the directives."

  @doc "Options for `Calendar.strftime/3` that translate month and weekday names."
  def strftime_opts do
    [
      month_names: &month_name/1,
      abbreviated_month_names: &abbreviated_month_name/1,
      day_of_week_names: &day_of_week_name/1,
      abbreviated_day_of_week_names: &abbreviated_day_of_week_name/1
    ]
  end

  @doc "Month and year heading, `October 2026`."
  def month_year(date) do
    gettext_comment(@pattern_comment)
    format(date, pgettext("date format", "%B %Y"))
  end

  @doc "Weekday with month and day, `Saturday, October 24`."
  def weekday_month_day(date) do
    gettext_comment(@pattern_comment)
    format(date, pgettext("date format", "%A, %B %-d"))
  end

  @doc "Short date with a zero-padded day, `Oct 04, 2026`."
  def short_date(date) do
    gettext_comment(@pattern_comment)
    format(date, pgettext("date format", "%b %d, %Y"))
  end

  @doc "Short date without day padding, `Oct 4, 2026`."
  def short_date_unpadded(date) do
    gettext_comment(@pattern_comment)
    format(date, pgettext("date format", "%b %-d, %Y"))
  end

  defp format(date, pattern), do: Calendar.strftime(date, pattern, strftime_opts())

  defp month_name(1), do: pgettext("month", "January")
  defp month_name(2), do: pgettext("month", "February")
  defp month_name(3), do: pgettext("month", "March")
  defp month_name(4), do: pgettext("month", "April")
  defp month_name(5), do: pgettext("month", "May")
  defp month_name(6), do: pgettext("month", "June")
  defp month_name(7), do: pgettext("month", "July")
  defp month_name(8), do: pgettext("month", "August")
  defp month_name(9), do: pgettext("month", "September")
  defp month_name(10), do: pgettext("month", "October")
  defp month_name(11), do: pgettext("month", "November")
  defp month_name(12), do: pgettext("month", "December")

  defp abbreviated_month_name(1), do: pgettext("month abbreviation", "Jan")
  defp abbreviated_month_name(2), do: pgettext("month abbreviation", "Feb")
  defp abbreviated_month_name(3), do: pgettext("month abbreviation", "Mar")
  defp abbreviated_month_name(4), do: pgettext("month abbreviation", "Apr")
  defp abbreviated_month_name(5), do: pgettext("month abbreviation", "May")
  defp abbreviated_month_name(6), do: pgettext("month abbreviation", "Jun")
  defp abbreviated_month_name(7), do: pgettext("month abbreviation", "Jul")
  defp abbreviated_month_name(8), do: pgettext("month abbreviation", "Aug")
  defp abbreviated_month_name(9), do: pgettext("month abbreviation", "Sep")
  defp abbreviated_month_name(10), do: pgettext("month abbreviation", "Oct")
  defp abbreviated_month_name(11), do: pgettext("month abbreviation", "Nov")
  defp abbreviated_month_name(12), do: pgettext("month abbreviation", "Dec")

  defp day_of_week_name(1), do: pgettext("weekday", "Monday")
  defp day_of_week_name(2), do: pgettext("weekday", "Tuesday")
  defp day_of_week_name(3), do: pgettext("weekday", "Wednesday")
  defp day_of_week_name(4), do: pgettext("weekday", "Thursday")
  defp day_of_week_name(5), do: pgettext("weekday", "Friday")
  defp day_of_week_name(6), do: pgettext("weekday", "Saturday")
  defp day_of_week_name(7), do: pgettext("weekday", "Sunday")

  defp abbreviated_day_of_week_name(1), do: pgettext("weekday abbreviation", "Mon")
  defp abbreviated_day_of_week_name(2), do: pgettext("weekday abbreviation", "Tue")
  defp abbreviated_day_of_week_name(3), do: pgettext("weekday abbreviation", "Wed")
  defp abbreviated_day_of_week_name(4), do: pgettext("weekday abbreviation", "Thu")
  defp abbreviated_day_of_week_name(5), do: pgettext("weekday abbreviation", "Fri")
  defp abbreviated_day_of_week_name(6), do: pgettext("weekday abbreviation", "Sat")
  defp abbreviated_day_of_week_name(7), do: pgettext("weekday abbreviation", "Sun")
end
