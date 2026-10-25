defmodule MydiaWeb.RelativeTime do
  @moduledoc """
  Translated fuzzy relative times for past and future instants, such as
  "5 minutes ago", "just now" and "in 2 hours".

  Replaces `Timex.from_now/1`, whose phrases are translated with Timex's own
  catalog rather than Mydia's. Granularity is one unit: seconds are folded into
  "just now" when past, and a month is 30 days and a year is 365.
  """

  use Gettext, backend: MydiaWeb.Gettext

  @minute 60
  @hour 3_600
  @day 86_400
  @month 30 * @day
  @year 365 * @day

  @doc """
  The relative phrase for `datetime` as seen from `now` (default: the current
  time). Naive datetimes are read as UTC.
  """
  @spec from_now(DateTime.t() | NaiveDateTime.t(), DateTime.t()) :: String.t()
  def from_now(datetime, now \\ DateTime.utc_now())

  def from_now(%NaiveDateTime{} = naive, now),
    do: naive |> DateTime.from_naive!("Etc/UTC") |> from_now(now)

  def from_now(%DateTime{} = datetime, %DateTime{} = now) do
    diff = DateTime.diff(datetime, now, :second)

    if diff > 0, do: future(diff), else: past(-diff)
  end

  defp past(seconds) when seconds < @minute, do: gettext("just now")

  defp past(seconds) when seconds < @hour,
    do: ngettext("%{count} minute ago", "%{count} minutes ago", div(seconds, @minute))

  defp past(seconds) when seconds < @day,
    do: ngettext("%{count} hour ago", "%{count} hours ago", div(seconds, @hour))

  defp past(seconds) when seconds < @month,
    do: ngettext("%{count} day ago", "%{count} days ago", div(seconds, @day))

  defp past(seconds) when seconds < @year,
    do: ngettext("%{count} month ago", "%{count} months ago", div(seconds, @month))

  defp past(seconds),
    do: ngettext("%{count} year ago", "%{count} years ago", div(seconds, @year))

  defp future(seconds) when seconds < @minute,
    do: ngettext("in %{count} second", "in %{count} seconds", seconds)

  defp future(seconds) when seconds < @hour,
    do: ngettext("in %{count} minute", "in %{count} minutes", div(seconds, @minute))

  defp future(seconds) when seconds < @day,
    do: ngettext("in %{count} hour", "in %{count} hours", div(seconds, @hour))

  defp future(seconds) when seconds < @month,
    do: ngettext("in %{count} day", "in %{count} days", div(seconds, @day))

  defp future(seconds) when seconds < @year,
    do: ngettext("in %{count} month", "in %{count} months", div(seconds, @month))

  defp future(seconds),
    do: ngettext("in %{count} year", "in %{count} years", div(seconds, @year))
end
