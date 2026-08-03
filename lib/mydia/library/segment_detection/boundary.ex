defmodule Mydia.Library.SegmentDetection.Boundary do
  @moduledoc """
  Snaps a detected credits end to the picture's actual end.

  Fingerprinting locates the credits *music*. The music and the picture rarely
  stop at the same instant, so the raw fingerprint end can leave a few seconds
  of black on screen or cut the last card off. Running `blackdetect` over a
  narrow window around the detected end and taking the last black transition
  fixes that cheaply.

  Every failure path returns the original value. This is a refinement, so a
  missing binary, an unreadable file, or partial ffmpeg output must degrade to
  "good enough", never to an error the caller has to handle.
  """

  require Logger

  alias Mydia.Library.Ffmpeg

  # How far either side of the detected end to look.
  @window_ms 20_000

  # blackdetect tuning: minimum black duration in seconds, and the picture
  # threshold. These are ffmpeg's own defaults apart from a shorter minimum
  # duration, since credits-to-black transitions are brief.
  #
  # MEASURED CONFIRMATION 2026-08-03, do not "clean this up" back to the default.
  # ffmpeg's default d is 2.0 seconds. Real credits-to-black transitions are far
  # shorter: on a sampled episode the transition at the detected credits end was
  # 0.125s long. With the default d=2.0 blackdetect reported NOTHING over that
  # window; with d=0.05 it found the transition. Reverting this constant does not
  # break loudly, it just makes refine_end/2 silently never refine anything.
  @min_black_duration "0.05"
  @picture_threshold "0.98"

  @doc """
  Returns a refined end timestamp in milliseconds, or `end_ms` unchanged.
  """
  @spec refine_end(String.t(), integer()) :: integer()
  def refine_end(path, end_ms) when is_binary(path) and is_integer(end_ms) do
    {window_start_ms, window_length_ms} = search_window(end_ms)

    args = [
      "-nostdin",
      "-ss",
      to_string(window_start_ms / 1000),
      "-t",
      to_string(window_length_ms / 1000),
      "-i",
      path,
      "-vf",
      "blackdetect=d=#{@min_black_duration}:pic_th=#{@picture_threshold}",
      "-an",
      "-f",
      "null",
      "-"
    ]

    case Ffmpeg.run(args) do
      {:ok, output} ->
        output
        |> parse_black_intervals(window_start_ms)
        |> pick_end(end_ms)

      {:error, reason} ->
        Logger.debug("Skipping credits boundary refinement",
          path: path,
          reason: inspect(reason)
        )

        end_ms
    end
  end

  @doc """
  Returns `{window_start_ms, window_length_ms}` for the blackdetect pass.

  The window is `end_ms` plus or minus #{@window_ms} ms, clamped at the start of
  the file. Clamping shortens the window instead of sliding it forward, so an
  end near the start of the file never searches beyond `end_ms + #{@window_ms}`.

  Public for testing.
  """
  @spec search_window(integer()) :: {non_neg_integer(), non_neg_integer()}
  def search_window(end_ms) when is_integer(end_ms) do
    window_start_ms = max(end_ms - @window_ms, 0)
    window_end_ms = max(end_ms + @window_ms, 0)

    {window_start_ms, window_end_ms - window_start_ms}
  end

  @doc """
  Extracts absolute `black_start` times in milliseconds from blackdetect output.

  blackdetect reports times relative to the trimmed input, because the window is
  cut with `-ss`, so `window_start_ms` is added back to make them absolute.

  Unparseable text is skipped rather than raised on. blackdetect output is
  interleaved with the rest of ffmpeg's logging and can be truncated partway
  through a line.
  """
  # binary() rather than String.t(): this parses whatever `Ffmpeg.run/2` hands
  # back, and that output is not guaranteed to be valid UTF-8.
  @spec parse_black_intervals(binary(), integer()) :: [integer()]
  def parse_black_intervals(output, window_start_ms)
      when is_binary(output) and is_integer(window_start_ms) do
    ~r/black_start:([0-9]+(?:\.[0-9]+)?)/
    |> Regex.scan(output, capture: :all_but_first)
    |> Enum.flat_map(fn [value] ->
      case Float.parse(value) do
        {seconds, _rest} -> [window_start_ms + round(seconds * 1000)]
        :error -> []
      end
    end)
  end

  @doc """
  Chooses the refined end from the detected black starts.

  The latest transition wins: credits fade to black at their end, and any
  earlier black is a transition *within* the credits.
  """
  @spec pick_end([integer()], integer()) :: integer()
  def pick_end([], end_ms), do: end_ms
  def pick_end(candidates, _end_ms), do: Enum.max(candidates)
end
