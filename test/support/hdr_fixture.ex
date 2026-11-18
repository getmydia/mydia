defmodule Mydia.HdrFixture do
  @moduledoc """
  Generates short HDR test clips with a real FFmpeg, into a directory the
  caller owns. Nothing is committed: the clips are synthetic (`testsrc2`) and
  cheap to make, and a checked-in HEVC file would be an opaque binary.

  Each clip is HEVC 10-bit in Matroska with the colour tags a real HDR rip
  carries. HDR10 also carries x265 mastering display and content light level
  metadata.

  The commands are exposed through `hdr10_args/3` and `hlg_args/3` so a check
  on another host (the Android one) can reuse them verbatim.
  """

  @hdr10_x265 "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:" <>
                "master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):" <>
                "max-cll=1000,400:hdr10=1:repeat-headers=1"

  @hlg_x265 "colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:repeat-headers=1"

  @doc "A 2-second HDR10 clip of the given height (16:9). Returns its path."
  @spec hdr10_clip(Path.t(), pos_integer(), pos_integer()) :: Path.t()
  def hdr10_clip(dir, height, seconds \\ 2),
    do: generate(dir, "hdr10", hdr10_args(height, seconds))

  @doc "A 2-second HLG clip of the given height (16:9). Returns its path."
  @spec hlg_clip(Path.t(), pos_integer(), pos_integer()) :: Path.t()
  def hlg_clip(dir, height, seconds \\ 2), do: generate(dir, "hlg", hlg_args(height, seconds))

  @doc "ffmpeg arguments (without the output path) for an HDR10 clip."
  def hdr10_args(height, seconds \\ 2) do
    encode_args(height, seconds, "smpte2084", @hdr10_x265)
  end

  @doc "ffmpeg arguments (without the output path) for an HLG clip."
  def hlg_args(height, seconds \\ 2) do
    encode_args(height, seconds, "arib-std-b67", @hlg_x265)
  end

  defp encode_args(height, seconds, trc, x265_params) do
    width = div(height * 16, 9) |> div(2) |> Kernel.*(2)

    [
      "-hide_banner",
      "-loglevel",
      "error",
      "-f",
      "lavfi",
      "-i",
      "testsrc2=size=#{width}x#{height}:rate=24:duration=#{seconds}",
      "-vf",
      "format=yuv420p10le",
      "-c:v",
      "libx265",
      "-preset",
      "ultrafast",
      "-pix_fmt",
      "yuv420p10le",
      "-color_primaries",
      "bt2020",
      "-color_trc",
      trc,
      "-colorspace",
      "bt2020nc",
      "-x265-params",
      "log-level=error:" <> x265_params
    ]
  end

  defp generate(dir, name, args) do
    path = Path.join(dir, "#{name}.mkv")

    case System.cmd("ffmpeg", args ++ ["-y", path], stderr_to_stdout: true) do
      {_out, 0} -> path
      {out, status} -> raise "ffmpeg failed to make #{path} (exit #{status}):\n#{out}"
    end
  end
end
