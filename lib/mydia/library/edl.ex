defmodule Mydia.Library.Edl do
  @moduledoc """
  Parses an Edit Decision List: the mplayer/Kodi sidecar format Comskip,
  MCEBuddy and similar DVR tools write beside a recording.

  Each line is `start end [action]`. Times are seconds (`612.48`, what Comskip
  writes) or timestamps (`00:10:12.48`, `10:12.48`). Actions:

    * `0`: cut
    * `1`: mute
    * `2`: scene marker
    * `3`: commercial break

  Only cuts and commercial breaks are kept, both as commercial breaks: Mydia
  uses EDL for skipping ads, and a mute range or a scene marker is not
  something to skip. A line with no action is a cut, as Kodi reads it.

  Frame-number lines (`#1234`) are dropped, since converting them needs the
  frame rate. So is any line that does not parse. The parser never raises: a
  sidecar is someone else's file, and a bad line costs one break, not playback.
  """

  @kept_actions ~w(0 3)

  # `media_segments.start_ms`/`end_ms` are `integer` columns: int4 on
  # PostgreSQL. A larger value (about 24.8 days) would make the insert raise,
  # so such a line is treated like any other unusable one.
  @max_ms 2_147_483_647

  @doc """
  Returns the file's commercial breaks as `{start_ms, end_ms}` tuples, sorted
  by start, with overlapping or touching ranges merged.
  """
  @spec parse(binary()) :: [{non_neg_integer(), pos_integer()}]
  def parse(content) when is_binary(content) do
    content
    |> String.split(~r/\r?\n/)
    |> Enum.flat_map(&parse_line/1)
    |> Enum.sort()
    |> merge()
  end

  defp parse_line(line) do
    case String.split(line) do
      [start, stop] -> range(start, stop)
      [start, stop, action] when action in @kept_actions -> range(start, stop)
      _ -> []
    end
  end

  defp range(start, stop) do
    with {:ok, start_ms} <- to_ms(start),
         {:ok, end_ms} <- to_ms(stop),
         true <- end_ms > start_ms and end_ms <= @max_ms do
      [{start_ms, end_ms}]
    else
      _ -> []
    end
  end

  # `ss.sss`, `mm:ss.sss` or `hh:mm:ss.sss`. Every part must parse completely
  # and be non-negative, so `#100` and `-5` are rejected here.
  defp to_ms(time) do
    parts = String.split(time, ":")

    with true <- length(parts) in 1..3,
         {:ok, numbers} <- parse_parts(parts) do
      seconds = Enum.reduce(numbers, 0.0, fn n, acc -> acc * 60 + n end)
      {:ok, round(seconds * 1000)}
    else
      _ -> :error
    end
  end

  defp parse_parts(parts) do
    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, acc} ->
      case Float.parse(part) do
        {n, ""} when n >= 0 -> {:cont, {:ok, acc ++ [n]}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp merge([]), do: []

  defp merge([first | rest]) do
    rest
    |> Enum.reduce([first], fn {start, stop}, [{prev_start, prev_stop} | done] ->
      if start <= prev_stop do
        [{prev_start, max(stop, prev_stop)} | done]
      else
        [{start, stop}, {prev_start, prev_stop} | done]
      end
    end)
    |> Enum.reverse()
  end
end
