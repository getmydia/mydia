defmodule Mydia.Library.FileAnalyzer do
  @moduledoc """
  Analyzes media files using FFprobe to extract technical metadata.

  Extracts:
  - Video resolution and quality (1080p, 720p, 4K, etc.)
  - Video codec (H.264, HEVC/H.265, AV1, etc.)
  - Audio codec (AAC, AC3, DTS, etc.)
  - Bitrate information
  - HDR format if present
  - File size
  """

  require Logger

  alias Mydia.Library.Structs.FileAnalysisResult

  @type analysis_result :: FileAnalysisResult.t()

  @doc """
  Analyzes a media file and extracts technical metadata.

  Returns {:ok, metadata_map} or {:error, reason}.

  ## Examples

      iex> FileAnalyzer.analyze("/path/to/video.mkv")
      {:ok, %{
        resolution: "1080p",
        codec: "H.264",
        audio_codec: "AAC",
        bitrate: 8000000,
        hdr_format: nil,
        size: 2147483648
      }}
  """
  @spec analyze(String.t()) :: {:ok, analysis_result()} | {:error, term()}
  def analyze(file_path) do
    if File.exists?(file_path) do
      with {:ok, ffprobe_data} <- run_ffprobe(file_path),
           {:ok, metadata} <- parse_ffprobe_output(ffprobe_data) do
        # Add file size
        size = File.stat!(file_path).size
        {:ok, %{metadata | size: size}}
      end
    else
      {:error, :file_not_found}
    end
  end

  ## Private Functions

  defp run_ffprobe(file_path) do
    # FFprobe command to get JSON output with stream and format info
    args = [
      "-v",
      "quiet",
      "-print_format",
      "json",
      "-show_format",
      "-show_streams",
      file_path
    ]

    case System.cmd("ffprobe", args, stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, data} ->
            {:ok, data}

          {:error, error} ->
            Logger.error("Failed to parse FFprobe JSON output",
              file: file_path,
              error: inspect(error)
            )

            {:error, :invalid_json}
        end

      {error_output, exit_code} ->
        Logger.error("FFprobe failed",
          file: file_path,
          exit_code: exit_code,
          output: error_output
        )

        {:error, :ffprobe_failed}
    end
  rescue
    e in ErlangError ->
      # FFprobe might not be installed
      Logger.error("Failed to run FFprobe - is it installed?",
        file: file_path,
        error: inspect(e)
      )

      {:error, :ffprobe_not_found}

    e ->
      Logger.error("Unexpected error running FFprobe",
        file: file_path,
        error: inspect(e)
      )

      {:error, :unexpected_error}
  end

  defp parse_ffprobe_output(data) do
    streams = Map.get(data, "streams", [])
    format = Map.get(data, "format", %{})

    # Find video and audio streams
    video_stream = Enum.find(streams, fn stream -> stream["codec_type"] == "video" end)
    audio_stream = Enum.find(streams, fn stream -> stream["codec_type"] == "audio" end)

    metadata =
      FileAnalysisResult.new(%{
        resolution: extract_resolution(video_stream),
        codec: extract_video_codec(video_stream),
        audio_codec: extract_audio_codec(audio_stream),
        bitrate: extract_bitrate(video_stream, format),
        hdr_format: extract_hdr_format(video_stream),
        size: nil
      })

    {:ok, metadata}
  end

  defp extract_resolution(nil), do: nil

  defp extract_resolution(video_stream) do
    height = video_stream["height"]
    width = video_stream["width"]

    cond do
      # 4K / UHD / 2160p
      height >= 2000 ->
        if width >= 3800, do: "4K", else: "2160p"

      # 1440p
      height >= 1400 ->
        "1440p"

      # 1080p / Full HD
      height >= 1000 ->
        "1080p"

      # 720p / HD
      height >= 700 ->
        "720p"

      # 480p / SD
      height >= 450 ->
        "480p"

      # 360p
      height >= 300 ->
        "360p"

      true ->
        # Unknown or very low resolution
        if height, do: "#{height}p", else: nil
    end
  end

  defp extract_video_codec(nil), do: nil

  defp extract_video_codec(video_stream) do
    codec_name = video_stream["codec_name"]
    codec_long_name = video_stream["codec_long_name"]
    profile = video_stream["profile"]

    case codec_name do
      "h264" ->
        # H.264 / AVC
        if profile, do: "H.264 (#{profile})", else: "H.264"

      "hevc" ->
        # H.265 / HEVC
        if profile, do: "HEVC (#{profile})", else: "HEVC"

      "av1" ->
        "AV1"

      "vp9" ->
        "VP9"

      "vp8" ->
        "VP8"

      "mpeg2video" ->
        "MPEG-2"

      "mpeg4" ->
        "MPEG-4"

      "xvid" ->
        "XviD"

      "divx" ->
        "DivX"

      name when is_binary(name) ->
        # Use long name if available, otherwise codec name
        if codec_long_name && codec_long_name != "" do
          # Clean up long name
          codec_long_name
          |> String.split("/")
          |> List.first()
          |> String.trim()
        else
          String.upcase(name)
        end

      _ ->
        nil
    end
  end

  defp extract_audio_codec(nil), do: nil

  defp extract_audio_codec(audio_stream) do
    codec_name = audio_stream["codec_name"]
    channels = audio_stream["channels"]
    profile = audio_stream["profile"]

    # Format channel count (e.g., 6 channels = 5.1)
    channel_str =
      case channels do
        1 -> "Mono"
        2 -> "Stereo"
        6 -> "5.1"
        8 -> "7.1"
        n when is_integer(n) -> "#{n}ch"
        _ -> nil
      end

    codec_str =
      case codec_name do
        "aac" ->
          if profile && profile != "LC", do: "AAC #{profile}", else: "AAC"

        "ac3" ->
          "AC3"

        "eac3" ->
          "DD+"

        "dts" ->
          # Check for DTS variants
          if profile do
            cond do
              String.contains?(profile, "MA") -> "DTS-HD MA"
              String.contains?(profile, "HR") -> "DTS-HD HR"
              String.contains?(profile, "X") -> "DTS:X"
              true -> "DTS"
            end
          else
            "DTS"
          end

        "truehd" ->
          # Check for Atmos
          if profile && String.contains?(profile, "Atmos") do
            "TrueHD Atmos"
          else
            "TrueHD"
          end

        "flac" ->
          "FLAC"

        "opus" ->
          "Opus"

        "vorbis" ->
          "Vorbis"

        "mp3" ->
          "MP3"

        "pcm_s16le" ->
          "PCM"

        name when is_binary(name) ->
          String.upcase(name)

        _ ->
          nil
      end

    # Combine codec and channel info
    case {codec_str, channel_str} do
      {nil, nil} -> nil
      {codec, nil} -> codec
      {nil, channels} -> channels
      {codec, channels} -> "#{codec} #{channels}"
    end
  end

  defp extract_bitrate(video_stream, format) do
    # Try video stream bitrate first, then fall back to overall bitrate
    cond do
      video_stream && video_stream["bit_rate"] ->
        parse_bitrate(video_stream["bit_rate"])

      format["bit_rate"] ->
        parse_bitrate(format["bit_rate"])

      true ->
        nil
    end
  end

  defp parse_bitrate(bitrate) when is_binary(bitrate) do
    case Integer.parse(bitrate) do
      {value, _} -> value
      :error -> nil
    end
  end

  defp parse_bitrate(bitrate) when is_integer(bitrate), do: bitrate
  defp parse_bitrate(_), do: nil

  defp extract_hdr_format(nil), do: nil

  defp extract_hdr_format(video_stream) do
    # Check color transfer characteristic
    color_transfer = video_stream["color_transfer"]
    color_space = video_stream["color_space"]
    color_primaries = video_stream["color_primaries"]

    # Check for side data (Dolby Vision, HDR10+, etc.)
    side_data = video_stream["side_data_list"] || []

    has_dolby_vision =
      Enum.any?(side_data, fn data ->
        data["side_data_type"] == "DOVI configuration record"
      end)

    has_hdr10_plus =
      Enum.any?(side_data, fn data ->
        data["side_data_type"] == "HDR10+"
      end)

    cond do
      has_dolby_vision ->
        "Dolby Vision"

      has_hdr10_plus ->
        "HDR10+"

      # Check for HDR10 based on color transfer
      color_transfer in ["smpte2084", "arib-std-b67"] ->
        "HDR10"

      # Check for HLG (Hybrid Log-Gamma)
      color_transfer == "arib-std-b67" ->
        "HLG"

      # Check for wide color gamut (potential HDR)
      color_primaries == "bt2020" && color_space == "bt2020nc" ->
        "HDR"

      true ->
        nil
    end
  end
end
