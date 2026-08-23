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

  alias Mydia.Library.Hdr
  alias Mydia.Library.Structs.FileAnalysisResult
  alias Mydia.Library.Structs.StreamInfo

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
        hdr: %Mydia.Library.Hdr{},
        size: 2147483648
      }}
  """
  @spec analyze(String.t()) :: {:ok, analysis_result()} | {:error, term()}
  def analyze(file_path) do
    if File.exists?(file_path) do
      with {:ok, ffprobe_data} <- run_ffprobe(file_path),
           {:ok, metadata} <- parse_probe(ffprobe_data) do
        metadata = maybe_probe_hdr10_plus(metadata, file_path)

        # File may disappear between the existence check and here on a long
        # ffprobe run; fall back to nil rather than raising so the row's
        # failure path still gets exercised via apply_analysis/2.
        size =
          case File.stat(file_path) do
            {:ok, %{size: s}} -> s
            {:error, _} -> nil
          end

        {:ok, %{metadata | size: size}}
      end
    else
      {:error, :file_not_found}
    end
  end

  ## Private Functions

  # Default 30s timeout for ffprobe. Overridable via
  # `config :mydia, :ffprobe_timeout_ms` so operators on slow mounts can tune it.
  @default_timeout_ms 30_000

  defp run_ffprobe(file_path) do
    args = [
      "-v",
      "quiet",
      "-print_format",
      "json",
      "-show_format",
      "-show_streams",
      file_path
    ]

    run_ffprobe_args(args)
  end

  # HDR10+ metadata is per-frame SEI (SMPTE ST 2094-40), so it never appears in
  # stream-level side data no matter which label is matched. Detecting it needs
  # a frame read, which is why this second pass exists.
  #
  # Gated by needs_frame_probe?/1 so it fires only for a plain HDR10 result:
  # SDR, HLG and Dolby Vision files pay nothing.
  defp maybe_probe_hdr10_plus(%{hdr: hdr} = metadata, file_path) do
    if Hdr.needs_frame_probe?(hdr) do
      case run_frame_probe(file_path) do
        {:ok, side_data} ->
          %{metadata | hdr: Hdr.from_ffprobe(%{"color_transfer" => "smpte2084"}, side_data)}

        {:error, _reason} ->
          # HDR10+ is a superset of HDR10, so degrading to the base format is
          # correct rather than merely safe.
          metadata
      end
    else
      metadata
    end
  end

  defp maybe_probe_hdr10_plus(metadata, _file_path), do: metadata

  defp run_frame_probe(file_path) do
    args = [
      "-v",
      "quiet",
      "-print_format",
      "json",
      "-select_streams",
      "v:0",
      "-read_intervals",
      "%+#5",
      "-show_frames",
      "-show_entries",
      "frame=side_data_list",
      file_path
    ]

    case run_ffprobe_args(args) do
      {:ok, %{"frames" => frames}} when is_list(frames) ->
        {:ok, Enum.flat_map(frames, fn frame -> List.wrap(frame["side_data_list"]) end)}

      {:ok, _other} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Shared port-and-trap-exit plumbing for both the stream-level and
  # frame-level ffprobe passes. Both share the resolved binary path and the
  # `ffprobe_timeout_ms` configuration; only the argument list differs. The
  # target file path is always the last argument, which is all the log
  # messages below need it for.
  defp run_ffprobe_args(args) do
    file_path = List.last(args)
    start_ms = System.monotonic_time(:millisecond)
    timeout_ms = Application.get_env(:mydia, :ffprobe_timeout_ms, @default_timeout_ms)

    case resolve_ffprobe_path() do
      nil ->
        Logger.error("Failed to run FFprobe - is it installed?",
          file: file_path,
          elapsed_ms: elapsed_ms(start_ms),
          reason: :ffprobe_not_found
        )

        {:error, :ffprobe_not_found}

      ffprobe_path ->
        previous_trap_exit = Process.flag(:trap_exit, true)

        try do
          port =
            Port.open(
              {:spawn_executable, ffprobe_path},
              [:binary, :exit_status, :stderr_to_stdout, :hide, args: args]
            )

          os_pid =
            case Port.info(port, :os_pid) do
              {:os_pid, pid} -> pid
              _ -> nil
            end

          collect_ffprobe_output(port, os_pid, [], start_ms, timeout_ms, file_path)
        rescue
          e in ErlangError ->
            Logger.error("Failed to run FFprobe - is it installed?",
              file: file_path,
              elapsed_ms: elapsed_ms(start_ms),
              reason: :ffprobe_not_found,
              error: inspect(e)
            )

            {:error, :ffprobe_not_found}

          e ->
            Logger.error("Unexpected error running FFprobe",
              file: file_path,
              elapsed_ms: elapsed_ms(start_ms),
              reason: :unexpected_error,
              error: inspect(e)
            )

            {:error, :unexpected_error}
        after
          Process.flag(:trap_exit, previous_trap_exit)
        end
    end
  end

  # Resolve ffprobe binary. Tests can override via Application env to point at
  # a fake shim that simulates timeouts or specific failure modes.
  defp resolve_ffprobe_path do
    case Application.get_env(:mydia, :ffprobe_path) do
      path when is_binary(path) and path != "" -> path
      _ -> System.find_executable("ffprobe")
    end
  end

  defp collect_ffprobe_output(port, os_pid, acc, start_ms, timeout_ms, file_path) do
    remaining = max(0, timeout_ms - elapsed_ms(start_ms))

    receive do
      {^port, {:data, data}} ->
        collect_ffprobe_output(port, os_pid, [data | acc], start_ms, timeout_ms, file_path)

      {^port, {:exit_status, 0}} ->
        case Jason.decode(IO.iodata_to_binary(Enum.reverse(acc))) do
          {:ok, data} ->
            {:ok, data}

          {:error, error} ->
            Logger.error("Failed to parse FFprobe JSON output",
              file: file_path,
              elapsed_ms: elapsed_ms(start_ms),
              reason: :invalid_json,
              error: inspect(error)
            )

            {:error, :invalid_json}
        end

      {^port, {:exit_status, exit_code}} ->
        Logger.error("FFprobe failed",
          file: file_path,
          elapsed_ms: elapsed_ms(start_ms),
          exit_code: exit_code,
          reason: :ffprobe_failed,
          output: IO.iodata_to_binary(Enum.reverse(acc))
        )

        {:error, :ffprobe_failed}

      {:EXIT, ^port, reason} ->
        # Linked-port abnormal teardown. Without this clause the receive blocks
        # until the full timeout fires even though the port is already dead.
        Logger.error("FFprobe port exited abnormally",
          file: file_path,
          elapsed_ms: elapsed_ms(start_ms),
          reason: {:port_exit, reason}
        )

        {:error, {:port_exit, reason}}
    after
      remaining ->
        Logger.error("FFprobe timed out",
          file: file_path,
          elapsed_ms: elapsed_ms(start_ms),
          timeout_ms: timeout_ms,
          reason: :ffprobe_timeout
        )

        kill_ffprobe(port, os_pid)
        flush_port_messages(port)
        {:error, :ffprobe_timeout}
    end
  end

  # Drain any pending `{port, _}` or `{:EXIT, port, _}` messages so they do not
  # accumulate in the caller's mailbox after the port has been killed. Bounded
  # by `after 0` so this is a non-blocking flush.
  defp flush_port_messages(port) do
    receive do
      {^port, _} -> flush_port_messages(port)
      {:EXIT, ^port, _} -> flush_port_messages(port)
    after
      0 -> :ok
    end
  end

  # Close the port and ensure no zombie OS process survives the timeout. Mirrors
  # the pattern in `Mydia.Streaming.FFmpegHlsTranscoder` (lines 340-374).
  defp kill_ffprobe(port, os_pid) do
    if is_port(port) and Port.info(port) do
      Port.close(port)
    end

    # Brief grace window for the port closure to propagate
    Process.sleep(50)

    if os_pid && process_alive?(os_pid) do
      Logger.warning("FFprobe process #{os_pid} did not terminate gracefully, sending SIGKILL")
      System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)
    end
  end

  defp process_alive?(os_pid) do
    case System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp elapsed_ms(start_ms), do: System.monotonic_time(:millisecond) - start_ms

  # Public so tests can drive the ffprobe-JSON-to-FileAnalysisResult mapping
  # directly, without spawning a real (or shimmed) ffprobe port.
  @doc false
  @spec parse_probe(map()) :: {:ok, analysis_result()}
  def parse_probe(data) do
    streams = Map.get(data, "streams", [])
    format = Map.get(data, "format", %{})

    # Find video and audio streams
    video_stream = Enum.find(streams, fn stream -> stream["codec_type"] == "video" end)
    audio_stream = Enum.find(streams, fn stream -> stream["codec_type"] == "audio" end)

    metadata =
      FileAnalysisResult.new(%{
        resolution: extract_resolution(video_stream),
        width: video_stream && video_stream["width"],
        height: video_stream && video_stream["height"],
        codec: extract_video_codec(video_stream),
        audio_codec: extract_audio_codec(audio_stream),
        bitrate: extract_bitrate(video_stream, format),
        hdr: Hdr.from_ffprobe(video_stream || %{}),
        duration: extract_duration(format),
        container: extract_container(format),
        size: nil,
        streams: extract_streams(streams)
      })

    {:ok, metadata}
  end

  # Every video, audio and subtitle stream, in ffprobe's own order. Attachment
  # and data streams return nil from from_ffprobe_stream/1 and are dropped.
  defp extract_streams(streams) when is_list(streams) do
    streams
    |> Enum.map(&StreamInfo.from_ffprobe_stream/1)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_streams(_streams), do: []

  defp extract_duration(format) do
    case format["duration"] do
      nil ->
        nil

      duration when is_binary(duration) ->
        case Float.parse(duration) do
          {value, _} -> value
          :error -> nil
        end

      duration when is_number(duration) ->
        duration / 1.0

      _ ->
        nil
    end
  end

  # Extracts container format from FFprobe format section.
  # FFprobe returns format_name which may contain comma-separated values like "mov,mp4,m4a,3gp"
  # We normalize this to a single, canonical container name.
  defp extract_container(format) do
    case format["format_name"] do
      nil ->
        nil

      format_name when is_binary(format_name) ->
        # Take the first format if comma-separated (e.g., "mov,mp4,m4a" -> "mov")
        format_name
        |> String.split(",")
        |> List.first()
        |> String.trim()
        |> String.downcase()
        |> normalize_container_name()

      _ ->
        nil
    end
  end

  # Normalizes container names to canonical forms for consistency
  defp normalize_container_name("matroska"), do: "mkv"
  defp normalize_container_name("mov"), do: "mp4"
  defp normalize_container_name("m4v"), do: "mp4"
  defp normalize_container_name("m4a"), do: "mp4"
  defp normalize_container_name("3gp"), do: "mp4"
  defp normalize_container_name("3g2"), do: "mp4"
  defp normalize_container_name("mj2"), do: "mp4"
  defp normalize_container_name("mpegts"), do: "ts"
  defp normalize_container_name("mpeg"), do: "ts"
  defp normalize_container_name(name), do: name

  defp extract_resolution(nil), do: nil

  defp extract_resolution(video_stream) do
    height = video_stream["height"]
    width = video_stream["width"]
    effective_height = effective_resolution_height(width, height)

    cond do
      # 4K / UHD / 2160p
      effective_height >= 2000 ->
        if width >= 3800, do: "4K", else: "2160p"

      # 1440p
      effective_height >= 1400 ->
        "1440p"

      # 1080p / Full HD
      effective_height >= 1000 ->
        "1080p"

      # 720p / HD
      effective_height >= 700 ->
        "720p"

      # 480p / SD
      effective_height >= 450 ->
        "480p"

      # 360p
      effective_height >= 300 ->
        "360p"

      true ->
        # Unknown or very low resolution
        if effective_height, do: "#{effective_height}p", else: nil
    end
  end

  # Cropped cinemascope encodes often keep the source width (for example
  # 1920x800) while trimming black bars from the stored frame height. Use the
  # encoded width as a fallback only when the stored height is not already near
  # a standard tier. That fixes 1920x800 -> 1080p and 1280x534 -> 720p while
  # leaving true ultrawide sources like 2560x1080 at their actual 1080p tier.
  defp effective_resolution_height(width, height)
       when is_integer(width) and is_integer(height) and width > 0 and height > 0 do
    cond do
      standard_resolution_height?(height) ->
        height

      width > height ->
        inferred_resolution_height_from_width(width) || height

      true ->
        height
    end
  end

  defp effective_resolution_height(_width, height), do: height

  @resolution_height_tolerance 24

  defp standard_resolution_height?(height) do
    Enum.any?([2160, 1440, 1080, 720, 480, 360], fn standard_height ->
      abs(height - standard_height) <= @resolution_height_tolerance
    end)
  end

  defp inferred_resolution_height_from_width(width) when width >= 3800, do: 2160
  defp inferred_resolution_height_from_width(width) when width >= 2500, do: 1440
  defp inferred_resolution_height_from_width(width) when width >= 1900, do: 1080
  defp inferred_resolution_height_from_width(width) when width >= 1200, do: 720
  defp inferred_resolution_height_from_width(_width), do: nil

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
end
