defmodule MydiaWeb.ActivityLive.DateFilter do
  @moduledoc """
  Date presets for the activity feed.

  "today" and "yesterday" are calendar days in the viewer's display zone, so
  their boundaries are local midnights converted to UTC. "week" and "month" are
  rolling windows and need no zone. The SQL filter (`opts/3`) and the live
  insert check (`matches?/4`) both derive from `boundaries/3`, so they agree.
  """

  @doc "Query options (`:since` / `:until`) for a preset."
  @spec opts(String.t(), DateTime.t(), String.t()) :: keyword()
  def opts("today", now, zone), do: [since: start_of_day(now, zone, 0)]

  def opts("yesterday", now, zone),
    do: [since: start_of_day(now, zone, -1), until: start_of_day(now, zone, 0)]

  def opts("week", now, _zone), do: [since: DateTime.add(now, -7, :day)]
  def opts("month", now, _zone), do: [since: DateTime.add(now, -30, :day)]
  def opts(_preset, _now, _zone), do: []

  @doc "Whether `inserted_at` falls inside the preset, mirroring `opts/3`."
  @spec matches?(DateTime.t(), String.t(), DateTime.t(), String.t()) :: boolean()
  def matches?(inserted_at, preset, now, zone) do
    opts = opts(preset, now, zone)

    since_ok? =
      case Keyword.fetch(opts, :since) do
        {:ok, since} -> DateTime.compare(inserted_at, since) != :lt
        :error -> true
      end

    until_ok? =
      case Keyword.fetch(opts, :until) do
        {:ok, until} -> DateTime.compare(inserted_at, until) == :lt
        :error -> true
      end

    since_ok? and until_ok?
  end

  # UTC instant of local midnight, `days_offset` calendar days from today in `zone`.
  defp start_of_day(now, zone, days_offset) do
    local_today =
      case DateTime.shift_zone(now, zone) do
        {:ok, local} -> DateTime.to_date(local)
        {:error, _} -> DateTime.to_date(now)
      end

    local_today
    |> Date.add(days_offset)
    |> midnight_utc(zone)
  end

  defp midnight_utc(date, zone) do
    case DateTime.new(date, ~T[00:00:00], zone) do
      {:ok, dt} -> to_utc(dt)
      {:ambiguous, earlier, _later} -> to_utc(earlier)
      {:gap, _before, after_gap} -> to_utc(after_gap)
      {:error, _} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end
  end

  defp to_utc(dt), do: DateTime.shift_zone!(dt, "Etc/UTC")
end
