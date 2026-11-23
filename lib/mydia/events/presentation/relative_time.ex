defmodule Mydia.Events.Presentation.RelativeTime do
  @moduledoc """
  "in 3 days"-style phrasing for the future timestamps event details carry
  (`next_eligible_at`, `grab_after`). Used by `Mydia.Events.Presentation`.
  """

  @doc "Phrases an ISO 8601 timestamp relative to now; \"unknown\" when absent."
  @spec describe(String.t() | nil) :: String.t()
  def describe(nil), do: "unknown"

  def describe(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} -> relative_future_time(dt)
      _ -> iso_string
    end
  end

  def describe(_), do: "unknown"

  defp relative_future_time(dt) do
    diff_seconds = DateTime.diff(dt, DateTime.utc_now())

    cond do
      diff_seconds <= 0 -> "now"
      diff_seconds < 60 -> "in #{pluralize_unit(diff_seconds, "second")}"
      diff_seconds < 3600 -> "in #{pluralize_unit(div(diff_seconds, 60), "minute")}"
      diff_seconds < 86_400 -> "in #{format_hours(diff_seconds / 3600)}"
      true -> "in #{pluralize_unit(div(diff_seconds, 86_400), "day")}"
    end
  end

  # Whole hours read better without the decimal ("in 2 hours", not "in 2.0
  # hours"), and one hour needs the singular. Fractional hours keep one place.
  defp format_hours(hours) do
    rounded = Float.round(hours, 1)

    if rounded == trunc(rounded) do
      pluralize_unit(trunc(rounded), "hour")
    else
      "#{rounded} hours"
    end
  end

  defp pluralize_unit(1, unit), do: "1 #{unit}"
  defp pluralize_unit(count, unit), do: "#{count} #{unit}s"
end
