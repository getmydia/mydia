defmodule MydiaWeb.DateTimeFormat do
  @moduledoc """
  The one place the web UI turns a timestamp into text.

  `DateTime` and `NaiveDateTime` (stored as UTC) are shifted into the viewer's
  `Mydia.TimeDisplay` zone first. `Date` values are calendar dates and are
  formatted as they are. Every LiveView in the authenticated sessions has
  `@time_display`; pass it down as `display={@time_display}`.

  `test/mydia_web/no_raw_time_formatting_test.exs` fails if a time-of-day
  `Calendar.strftime` appears anywhere else under `lib/mydia_web`.
  """

  use Phoenix.Component

  alias Mydia.TimeDisplay

  @type preset :: :date | :month_day | :time | :time_seconds | :datetime | :datetime_full

  @date_presets [:date, :month_day]

  @spec format(DateTime.t() | NaiveDateTime.t() | Date.t() | nil, preset(), TimeDisplay.t()) ::
          String.t()
  def format(nil, _preset, _display), do: "—"

  def format(%Date{} = date, preset, _display) when preset in @date_presets,
    do: Calendar.strftime(date, pattern(preset, :h24))

  def format(%Date{}, preset, _display),
    do: raise(ArgumentError, "a Date has no time of day to format as #{inspect(preset)}")

  def format(%NaiveDateTime{} = naive, preset, display),
    do: naive |> DateTime.from_naive!("Etc/UTC") |> format(preset, display)

  def format(%DateTime{} = dt, preset, %TimeDisplay{} = display),
    do: dt |> shift(display.time_zone) |> Calendar.strftime(pattern(preset, display.clock))

  # A zone that validated once can still fail to shift if tzdata changes under
  # a running node; show UTC rather than raising inside a template.
  defp shift(dt, zone) do
    case DateTime.shift_zone(dt, zone) do
      {:ok, shifted} -> shifted
      {:error, _} -> DateTime.shift_zone!(dt, "Etc/UTC")
    end
  end

  defp pattern(:date, _), do: "%b %-d, %Y"
  defp pattern(:month_day, _), do: "%b %-d"
  defp pattern(:time, clock), do: time(clock)
  defp pattern(:time_seconds, :h24), do: "%H:%M:%S"
  defp pattern(:time_seconds, :h12), do: "%-I:%M:%S %p"
  defp pattern(:datetime, clock), do: "%b %-d, %Y, " <> time(clock)

  defp pattern(:datetime_full, clock),
    do: "%b %-d, %Y, " <> pattern(:time_seconds, clock) <> " %Z"

  defp time(:h24), do: "%H:%M"
  defp time(:h12), do: "%-I:%M %p"

  @doc """
  A `<time>` element: the formatted text, the UTC instant in `datetime`, and
  the full date, time and zone in `title` for hover.
  """
  attr :at, :any, required: true, doc: "a DateTime, NaiveDateTime, or nil"
  attr :format, :atom, default: :datetime
  attr :display, TimeDisplay, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  def local_time(%{at: nil} = assigns) do
    ~H"""
    <span class={@class} {@rest}>—</span>
    """
  end

  def local_time(assigns) do
    ~H"""
    <time
      datetime={iso8601(@at)}
      title={format(@at, :datetime_full, @display)}
      class={@class}
      {@rest}
    >{format(@at, @format, @display)}</time>
    """
  end

  defp iso8601(%NaiveDateTime{} = naive),
    do: naive |> DateTime.from_naive!("Etc/UTC") |> iso8601()

  defp iso8601(%DateTime{} = dt),
    do: dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()
end
