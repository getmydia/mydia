defmodule MydiaWeb.DownloadsLive.Format do
  @moduledoc "Display formatting shared by the Downloads LiveView and its components."

  use Gettext, backend: MydiaWeb.Gettext

  alias MydiaWeb.DateTimeFormat

  def format_speed(nil), do: "—"

  def format_speed(bytes_per_second) when is_number(bytes_per_second) do
    cond do
      bytes_per_second >= 1_048_576 ->
        "#{Float.round(bytes_per_second / 1_048_576, 2)} MB/s"

      bytes_per_second >= 1024 ->
        "#{Float.round(bytes_per_second / 1024, 2)} KB/s"

      true ->
        "#{bytes_per_second} B/s"
    end
  end

  def format_eta(nil), do: "—"

  def format_eta(%DateTime{} = dt) do
    now = DateTime.utc_now()
    diff = DateTime.diff(dt, now, :second)

    format_eta_seconds(diff)
  end

  def format_eta(seconds) when is_integer(seconds), do: format_eta_seconds(seconds)

  defp format_eta_seconds(seconds) do
    cond do
      seconds < 0 -> pgettext("eta", "Now")
      seconds < 60 -> gettext("%{count}s", count: seconds)
      seconds < 3600 -> gettext("%{count}m", count: div(seconds, 60))
      seconds < 86400 -> gettext("%{count}h", count: div(seconds, 3600))
      true -> gettext("%{count}d", count: div(seconds, 86400))
    end
  end

  def format_ratio(nil), do: "0.00"
  def format_ratio(ratio) when is_float(ratio), do: Float.round(ratio, 2) |> to_string()
  def format_ratio(ratio) when is_integer(ratio), do: "#{ratio}.00"

  def format_relative_time(%DateTime{} = dt, %Mydia.TimeDisplay{} = display) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, dt, :second)

    cond do
      diff < 60 -> gettext("just now")
      diff < 3600 -> gettext("%{count}m ago", count: div(diff, 60))
      diff < 86400 -> gettext("%{count}h ago", count: div(diff, 3600))
      diff < 604_800 -> gettext("%{count}d ago", count: div(diff, 86400))
      true -> DateTimeFormat.format(dt, :month_day, display)
    end
  end

  def format_protocol(:nzb), do: "Usenet"
  def format_protocol(:torrent), do: "Torrent"
  def format_protocol("nzb"), do: "Usenet"
  def format_protocol("torrent"), do: "Torrent"
  def format_protocol(_), do: nil

  def format_next_retry(%DateTime{} = dt) do
    now = DateTime.utc_now()
    diff = DateTime.diff(dt, now, :second)

    cond do
      diff < 0 -> gettext("Retrying soon...")
      diff < 60 -> gettext("in %{count}s", count: diff)
      diff < 3600 -> gettext("in %{count}m", count: div(diff, 60))
      diff < 86400 -> gettext("in %{count}h", count: div(diff, 3600))
      true -> gettext("in %{count}d", count: div(diff, 86400))
    end
  end

  @doc "Absolute timestamp in the viewer's display zone, for a tooltip next to a relative time."
  @spec format_absolute_time(DateTime.t(), Mydia.TimeDisplay.t()) :: String.t()
  def format_absolute_time(%DateTime{} = dt, %Mydia.TimeDisplay{} = display),
    do: DateTimeFormat.format(dt, :datetime, display)
end
