defmodule MydiaWeb.NoRawTimeFormattingTest do
  @moduledoc """
  Time-of-day formatting goes through MydiaWeb.DateTimeFormat so it honours the
  viewer's time zone and clock. Date-only formats (no %H %I %M %S %p) are fine.

  The scan reads whole files, so a call whose format string sits on a later
  line is caught as well.
  """
  use ExUnit.Case, async: true

  @allowed ["lib/mydia_web/date_time_format.ex"]
  @time_directive ~r/%[-_0^#]?[HIklMSpPrRTXcsU]/

  # `Calendar.strftime(` followed by its arguments (one level of nested parens
  # allowed, e.g. `hd(batch).inserted_at`) up to the first string literal.
  @call ~r/Calendar\.strftime\((?:[^()"]|\([^()]*\))*?"([^"]*)"/s

  test "no Calendar.strftime with a time-of-day format outside DateTimeFormat" do
    offenders =
      Path.wildcard("lib/mydia_web/**/*.{ex,heex}")
      |> Enum.reject(&(&1 in @allowed))
      |> Enum.flat_map(&offenders_in/1)

    assert offenders == [], """
    Format times with MydiaWeb.DateTimeFormat.format/3 or <.local_time>:

    #{Enum.join(offenders, "\n")}
    """
  end

  defp offenders_in(path) do
    text = File.read!(path)

    @call
    |> Regex.scan(text, return: :index)
    |> Enum.flat_map(fn [{start, len}, {fmt_start, fmt_len}] ->
      format = binary_part(text, fmt_start, fmt_len)

      if Regex.match?(@time_directive, format) do
        line = text |> binary_part(0, start) |> String.split("\n") |> length()
        snippet = text |> binary_part(start, len) |> String.replace(~r/\s+/, " ")
        ["#{path}:#{line}: #{snippet}"]
      else
        []
      end
    end)
  end
end
