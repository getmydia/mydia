defmodule MydiaWeb.DownloadsLive.Format do
  @moduledoc "Display formatting shared by the Downloads LiveView and its components."

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

    cond do
      diff < 0 -> "Now"
      diff < 60 -> "#{diff}s"
      diff < 3600 -> "#{div(diff, 60)}m"
      diff < 86400 -> "#{div(diff, 3600)}h"
      true -> "#{div(diff, 86400)}d"
    end
  end

  def format_eta(seconds) when is_integer(seconds) do
    cond do
      seconds < 0 -> "Now"
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86400 -> "#{div(seconds, 3600)}h"
      true -> "#{div(seconds, 86400)}d"
    end
  end

  def format_ratio(nil), do: "0.00"
  def format_ratio(ratio) when is_float(ratio), do: Float.round(ratio, 2) |> to_string()
  def format_ratio(ratio) when is_integer(ratio), do: "#{ratio}.00"

  def format_relative_time(%DateTime{} = dt) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86400)}d ago"
      true -> Calendar.strftime(dt, "%b %d")
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
      diff < 0 -> "Retrying soon..."
      diff < 60 -> "in #{diff}s"
      diff < 3600 -> "in #{div(diff, 60)}m"
      diff < 86400 -> "in #{div(diff, 3600)}h"
      true -> "in #{div(diff, 86400)}d"
    end
  end

  @doc "Absolute UTC timestamp for a tooltip next to a relative time."
  @spec format_absolute_time(DateTime.t()) :: String.t()
  def format_absolute_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
end
