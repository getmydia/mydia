defmodule Mydia.Streaming.KeyframeLocator do
  @moduledoc """
  Finds the keyframe a stream-copy seek will start from.

  A copied video stream can only begin on a keyframe, so a `:window` session
  resumed with `-ss 27` really begins at whatever keyframe FFmpeg's seek lands
  on. Unless the server reports that keyframe, the player's `StreamTimeline`
  maps position zero onto 27 and every position it shows or saves runs ahead
  by up to a GOP.

  `ffprobe -read_intervals T%+#1` seeks the way FFmpeg's `-ss` does and reads
  one packet, and measured on MKV and MP4 it lands on the same keyframe FFmpeg
  itself starts from. That is usually the keyframe at or before T, but MP4
  compares decode timestamps, so a target inside the B-frame delay just before
  a keyframe lands on that keyframe, after T. MPEG-TS has no seek index and
  lands mid-GOP, which is why only a keyframe packet counts as an answer.
  `HlsSession` also only asks about MKV and MP4.
  """

  require Logger

  alias Mydia.BoundedCommand

  # About 23ms against a local disk. The bound is for storage that has stopped
  # answering: the lookup sits in front of StartStreamingSession, which the
  # p2p host abandons after 25s.
  @timeout_ms 1_500

  @type runner ::
          (String.t(), [String.t()], timeout() ->
             {:ok, binary()} | {:error, BoundedCommand.error()})

  @doc """
  The timestamp, in seconds, of the keyframe a copy seek to `seconds` starts from.

  `:none` when ffprobe cannot say: it timed out, failed, is missing, or landed
  on a packet that is not a keyframe. `runner` exists for tests.
  """
  @spec locate(String.t(), number(), runner()) :: {:ok, float()} | :none
  def locate(path, seconds, runner \\ &BoundedCommand.run/3) do
    args = [
      "-v",
      "error",
      "-read_intervals",
      "#{seconds}%+#1",
      "-select_streams",
      # V, not v: the transcoder maps 0:V:0?, which skips attached cover art.
      "V:0",
      "-show_entries",
      "packet=pts_time,flags",
      "-of",
      "csv=p=0",
      path
    ]

    case runner.(ffprobe(), args, @timeout_ms) do
      {:ok, output} ->
        parse(output)

      {:error, :timeout} ->
        Logger.warning(
          "Keyframe lookup for #{path} at #{seconds}s timed out after #{@timeout_ms}ms"
        )

        :none

      {:error, reason} ->
        Logger.debug("Keyframe lookup for #{path} at #{seconds}s failed: #{inspect(reason)}")
        :none
    end
  end

  @doc false
  # Public only so the parsing can be asserted directly; nothing outside this
  # module should call it. BoundedCommand merges stderr into the output, so
  # this looks for the first packet line instead of trusting the first line.
  @spec parse(binary()) :: {:ok, float()} | :none
  def parse(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.find_value(:none, &packet_line/1)
  end

  # nil skips a line that is not a packet at all.
  defp packet_line(line) do
    case String.split(String.trim(line), ",") do
      [pts, "K" <> _ | _] -> seconds(pts)
      [pts, _flags | _] -> if seconds(pts), do: :none
      _ -> nil
    end
  end

  defp seconds(text) do
    case Float.parse(text) do
      {value, ""} -> {:ok, value}
      _ -> nil
    end
  end

  # Same override convention as Mydia.Library.Ffmpeg.
  defp ffprobe, do: Application.get_env(:mydia, :ffprobe_path) || "ffprobe"
end
