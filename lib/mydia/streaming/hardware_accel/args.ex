defmodule Mydia.Streaming.HardwareAccel.Args do
  @moduledoc """
  Builds the ffmpeg arguments that differ between software and hardware
  encoding. Pure: it takes a `Capabilities` and encode parameters and returns
  argument lists, so every tier and rate-control combination is testable without
  a GPU or an ffmpeg binary.

  The software tier reproduces exactly the arguments this pipeline emitted
  before hardware acceleration existed. The scale tests in
  `test/mydia/streaming/ffmpeg_scale*_test.exs` assert that composed output
  through `FfmpegHlsTranscoder.build_ffmpeg_args/3` and are the regression guard.

  ## Why the scale expression is shared

  `scale_vaapi` accepts the same expression syntax as `scale`, escaped comma
  included. Verified on Intel iHD 25.4.6 with ffmpeg 8.1.2:
  `scale_vaapi=w=-2:h=2*trunc(min(720\\,ih)/2):format=nv12` produced 1280x720
  from a 1080p source. So the no-upscale clamp and even-height rounding are
  written once in `height_expression/1` and reused by all three tiers.
  """

  require Logger

  alias Mydia.Streaming.HardwareAccel.Capabilities

  # Measured against libx264 -crf 23 on a 1080p sample: qp 23 costs 1.29x the
  # bitrate for SSIM 0.9923 against x264's 0.9949. See the rate-control table in
  # the design spec before changing this.
  @vaapi_qp 23

  defstruct tier: :software, input: [], video: []

  @type tier :: :software | :hybrid | :full_hardware
  @type t :: %__MODULE__{tier: tier(), input: [String.t()], video: [String.t()]}

  @spec build(Capabilities.t(), keyword()) :: t()
  def build(%Capabilities{} = caps, opts) do
    tier = tier(caps, Keyword.get(opts, :source_codec))
    height = Keyword.get(opts, :max_height)
    bitrate = Keyword.get(opts, :video_bitrate_kbps)

    %__MODULE__{
      tier: tier,
      input: input_args(tier, caps.device),
      video:
        codec_args(tier, opts) ++
          filter_args(tier, height) ++
          rate_control_args(tier, bitrate, Keyword.get(opts, :crf, 23))
    }
  end

  # A device that cannot encode H.264 is useless to this pipeline regardless of
  # what it can decode, so it degrades to software rather than to hybrid.
  defp tier(%Capabilities{backend: :none}, _source), do: :software

  defp tier(%Capabilities{} = caps, source) do
    cond do
      not Capabilities.can_encode?(caps, :h264) -> :software
      Capabilities.can_decode?(caps, source) -> :full_hardware
      true -> :hybrid
    end
  end

  defp input_args(:software, _device), do: []

  defp input_args(:full_hardware, device) do
    ["-hwaccel", "vaapi", "-hwaccel_device", device, "-hwaccel_output_format", "vaapi"]
  end

  # hwupload needs a filter device, which -hwaccel alone does not establish.
  defp input_args(:hybrid, device) do
    ["-init_hw_device", "vaapi=hw:#{device}", "-filter_hw_device", "hw"]
  end

  defp codec_args(:software, opts) do
    [
      "-c:v",
      Keyword.get(opts, :video_codec, "libx264"),
      "-preset",
      Keyword.get(opts, :preset, "medium"),
      "-pix_fmt",
      "yuv420p",
      "-profile:v",
      "high",
      "-g",
      "60",
      "-bf",
      "0"
    ]
  end

  # No -preset (VAAPI has none) and no -pix_fmt (the filter chain sets nv12;
  # leaving it in forces a download/upload round trip).
  defp codec_args(_hardware, _opts) do
    ["-c:v", "h264_vaapi", "-profile:v", "high", "-g", "60", "-bf", "0"]
  end

  defp filter_args(:software, height) do
    ["-vf", "scale=-2:#{height_expression(height)}"]
  end

  defp filter_args(:full_hardware, height) do
    ["-vf", "scale_vaapi=w=-2:h=#{height_expression(height)}:format=nv12"]
  end

  defp filter_args(:hybrid, height) do
    ["-vf", "scale=-2:#{height_expression(height)},format=nv12,hwupload"]
  end

  # `min(h, ih)` clamps against the input height so a rung above the source
  # never upscales. The comma is backslash-escaped because ffmpeg reads a bare
  # comma in a filtergraph as a filter separator, and these arguments reach a
  # port with no shell, so shell quoting would arrive literally.
  #
  # `2*trunc(.../2)` rounds down to an even height. An odd height makes libx264
  # with -pix_fmt yuv420p refuse to open the encoder (exit 187), which kills the
  # transcode before a playlist exists and surfaces as a generic playback error.
  defp height_expression(height) when is_integer(height) and height > 0 do
    "2*trunc(min(#{height}\\,ih)/2)"
  end

  defp height_expression(height) when is_integer(height) do
    Logger.warning(
      "Ignoring a non-positive transcode height ceiling (#{height}); " <>
        "encoding at the source resolution"
    )

    "2*trunc(ih/2)"
  end

  defp height_expression(_), do: "2*trunc(ih/2)"

  # :crf is software-only. The hardware tiers ignore it entirely and rate-control
  # off -qp (unmetered) or -rc_mode/-b:v (capped) instead, set by the two
  # `rate_control_args(_hardware, ...)` clauses below -- a caller that raises
  # :crf expecting it to affect a hardware encode's quality is a no-op.
  defp rate_control_args(:software, nil, crf), do: ["-crf", to_string(crf)]

  defp rate_control_args(:software, kbps, _crf) do
    ["-b:v", "#{kbps}k", "-maxrate", "#{kbps}k", "-bufsize", "#{kbps * 2}k"]
  end

  defp rate_control_args(_hardware, nil, _crf) do
    ["-rc_mode", "CQP", "-qp", to_string(@vaapi_qp)]
  end

  # VAAPI's default rc_mode is `auto`, which resolves by driver. Measured on iHD
  # 25.4.6 it honours -b:v without this flag, so pinning VBR is defensive rather
  # than a fix: it removes a driver-dependent variable from a client's bandwidth
  # cap.
  defp rate_control_args(_hardware, kbps, _crf) do
    ["-rc_mode", "VBR", "-b:v", "#{kbps}k", "-maxrate", "#{kbps}k", "-bufsize", "#{kbps * 2}k"]
  end
end
