defmodule Mydia.Streaming.Tonemap.Probe do
  @moduledoc """
  Finds out which ffmpeg tonemap filters work on this host.

  A filter appearing in `ffmpeg -filters` is not proof that it works: the
  filter can be compiled in while the library or device behind it is missing
  (see `Mydia.Streaming.HardwareAccel.Probe`, where `-hwaccels` lists `vaapi`
  on an image with no driver). So the listing only decides which tests are
  worth running, and each flag is set by a real throwaway run.

  `zscale` needs no device, so it is trusted from the listing when both
  `zscale` and `tonemap` are present. `libplacebo` needs a Vulkan device and
  `tonemap_vaapi` needs the VAAPI render node, so those two are run for real.

  `tonemap_vaapi` rejects input that lacks mastering-display side data ("No
  mastering display data from input"), and a synthetic frame with color tags
  alone does not carry it. So the VAAPI test first encodes a one-frame HDR10
  clip with libx265, which writes mastering metadata into the stream, and
  tonemaps that file. If the clip cannot be made, VAAPI is reported unusable.
  """

  require Logger

  alias Mydia.BoundedCommand
  alias Mydia.Streaming.Tonemap
  alias Mydia.Streaming.Tonemap.Filters

  # Same budget and reasoning as `HardwareAccel.Probe`: this runs inside
  # `HardwareAccel.handle_continue/2`, so a wedged ffmpeg blocks every
  # capability caller until the call timeout.
  @probe_timeout_ms 5_000

  @source ["-f", "lavfi", "-i", "testsrc=size=320x240:duration=0.2:rate=5", "-frames:v", "1"]
  @sink ["-f", "null", "-"]

  @hdr10_x265 "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:" <>
                "master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):" <>
                "max-cll=1000,400:hdr10=1:repeat-headers=1"

  @doc """
  Runs the probe. Options:

    * `:device` - the VAAPI render node (defaults to `/dev/dri/renderD128`)
    * `:vaapi?` - whether VAAPI is usable at all; when false the VAAPI test
      is never run
    * `:runner` - `(exe, args, timeout -> {:ok, output} | {:error, term})`,
      defaults to `Mydia.BoundedCommand.run/3`
  """
  @spec run(keyword()) :: Tonemap.t()
  def run(opts \\ []) do
    runner = Keyword.get(opts, :runner, &BoundedCommand.run/3)
    ffmpeg = Application.get_env(:mydia, :ffmpeg_path) || "ffmpeg"

    case runner.(ffmpeg, ["-hide_banner", "-filters"], @probe_timeout_ms) do
      {:ok, output} ->
        filters = parse_filters(output)

        %Tonemap{
          zscale: filters.zscale and filters.tonemap,
          libplacebo:
            filters.libplacebo and works?(:libplacebo, libplacebo_args(), ffmpeg, runner),
          vaapi:
            Keyword.get(opts, :vaapi?, false) and filters.tonemap_vaapi and
              vaapi_works?(opts, ffmpeg, runner)
        }

      {:error, reason} ->
        Logger.info("Tonemap probe could not list ffmpeg filters: #{inspect(reason)}")
        Tonemap.none()
    end
  end

  @doc "Reads which of the four filters of interest `ffmpeg -filters` lists."
  @spec parse_filters(String.t()) :: Filters.t()
  def parse_filters(output) do
    names =
      output
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case String.split(line) do
          [_flags, name | _rest] -> [name]
          _ -> []
        end
      end)
      |> MapSet.new()

    %Filters{
      zscale: "zscale" in names,
      tonemap: "tonemap" in names,
      libplacebo: "libplacebo" in names,
      tonemap_vaapi: "tonemap_vaapi" in names
    }
  end

  defp libplacebo_args do
    ["-hide_banner", "-loglevel", "error", "-init_hw_device", "vulkan"] ++
      @source ++ ["-vf", "libplacebo=format=yuv420p"] ++ @sink
  end

  # The clip is generated into a throwaway directory that is always removed.
  defp vaapi_works?(opts, ffmpeg, runner) do
    dir =
      Path.join(System.tmp_dir!(), "mydia-tonemap-probe-#{System.unique_integer([:positive])}")

    try do
      with :ok <- File.mkdir_p(dir),
           clip = Path.join(dir, "hdr10.mkv"),
           true <- works?(:hdr10_clip, clip_args(clip), ffmpeg, runner) do
        works?(:tonemap_vaapi, vaapi_args(opts, clip), ffmpeg, runner)
      else
        _ -> false
      end
    after
      File.rm_rf(dir)
    end
  end

  defp clip_args(path) do
    ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=1"] ++
      ["-frames:v", "1", "-vf", "format=yuv420p10le", "-c:v", "libx265", "-preset", "ultrafast"] ++
      ["-pix_fmt", "yuv420p10le", "-color_primaries", "bt2020", "-color_trc", "smpte2084"] ++
      ["-colorspace", "bt2020nc", "-x265-params", @hdr10_x265, "-y", path]
  end

  defp vaapi_args(opts, clip) do
    device = Keyword.get(opts, :device) || "/dev/dri/renderD128"

    ["-hide_banner", "-loglevel", "error"] ++
      ["-init_hw_device", "vaapi=hw:#{device}", "-filter_hw_device", "hw", "-i", clip] ++
      ["-vf", "format=p010,hwupload,tonemap_vaapi=format=nv12", "-frames:v", "1"] ++ @sink
  end

  defp works?(name, args, ffmpeg, runner) do
    case runner.(ffmpeg, args, @probe_timeout_ms) do
      {:ok, _output} ->
        true

      {:error, {:exit, _code, output}} ->
        Logger.info("ffmpeg #{name} test run failed: #{String.trim(output)}")
        false

      {:error, reason} ->
        Logger.info("ffmpeg #{name} test run failed: #{inspect(reason)}")
        false
    end
  end
end
