defmodule Mydia.Library.ThumbnailGenerator do
  @moduledoc """
  Generates thumbnail images and cover frames from video files using FFmpeg.

  This module provides functions to extract frames from video files at specified
  positions and save them as JPEG images. The generated thumbnails are stored
  using the GeneratedMedia content-addressable storage.

  ## Usage

      # Generate a cover image at 20% into the video (default)
      {:ok, checksum} = ThumbnailGenerator.generate_cover(media_file)

      # Generate at specific position (10 seconds)
      {:ok, checksum} = ThumbnailGenerator.generate_cover(media_file, position: {:seconds, 10})

      # Generate at specific percentage
      {:ok, checksum} = ThumbnailGenerator.generate_cover(media_file, position: {:percentage, 30})

  ## Requirements

  FFmpeg must be installed and available in the system PATH.
  """

  require Logger

  alias Mydia.Library.Ffmpeg
  alias Mydia.Library.GeneratedMedia
  alias Mydia.Library.MediaFile

  @default_position {:percentage, 20}
  @default_quality 2
  @default_width 480

  @type position :: {:seconds, number()} | {:percentage, number()}
  @type generate_opts :: [
          position: position(),
          quality: integer(),
          width: integer()
        ]

  @doc """
  Generates a cover thumbnail from a video file.

  Extracts a single frame from the video at the specified position, converts it
  to JPEG, and stores it using GeneratedMedia storage.

  ## Parameters
    - `media_file` - The MediaFile struct (must have library_path preloaded)
    - `opts` - Optional settings:
      - `:position` - Where to extract the frame (default: `{:percentage, 20}`)
      - `:quality` - JPEG quality (1-31, lower is better, default: 2)
      - `:width` - Output width in pixels (height auto-scaled, default: 480)

  ## Returns
    - `{:ok, checksum}` - The MD5 checksum of the generated image
    - `{:error, reason}` - Error description

  ## Examples

      {:ok, checksum} = ThumbnailGenerator.generate_cover(media_file)
      {:ok, checksum} = ThumbnailGenerator.generate_cover(media_file, position: {:seconds, 30})
  """
  @spec generate_cover(MediaFile.t(), generate_opts()) :: {:ok, String.t()} | {:error, term()}
  def generate_cover(%MediaFile{} = media_file, opts \\ []) do
    input_path = MediaFile.absolute_path(media_file)

    if is_nil(input_path) do
      {:error, :library_path_not_preloaded}
    else
      do_generate_cover(input_path, opts)
    end
  end

  @doc """
  Generates a cover thumbnail from a file path.

  Same as `generate_cover/2` but takes a file path directly instead of a MediaFile.

  ## Parameters
    - `input_path` - Path to the video file
    - `opts` - Optional settings (see `generate_cover/2`)

  ## Returns
    - `{:ok, checksum}` - The MD5 checksum of the generated image
    - `{:error, reason}` - Error description
  """
  @spec generate_cover_from_path(Path.t(), generate_opts()) ::
          {:ok, String.t()} | {:error, term()}
  def generate_cover_from_path(input_path, opts \\ []) when is_binary(input_path) do
    if File.exists?(input_path) do
      do_generate_cover(input_path, opts)
    else
      {:error, :file_not_found}
    end
  end

  @doc """
  Gets the duration of a video file in seconds.

  Uses FFprobe to extract the video duration.

  ## Parameters
    - `input_path` - Path to the video file

  ## Returns
    - `{:ok, duration}` - Duration in seconds as a float
    - `{:error, reason}` - Error description
  """
  @spec get_duration(Path.t()) :: {:ok, float()} | {:error, term()}
  def get_duration(input_path) when is_binary(input_path) do
    args = [
      "-v",
      "error",
      "-show_entries",
      "format=duration",
      "-of",
      "default=noprint_wrappers=1:nokey=1",
      input_path
    ]

    case run_ffprobe(args) do
      {:ok, output} ->
        case Float.parse(String.trim(output)) do
          {duration, _} -> {:ok, duration}
          :error -> {:error, :invalid_duration}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Checks if FFmpeg is available on the system.

  ## Returns
    - `true` if FFmpeg is available
    - `false` otherwise
  """
  @spec ffmpeg_available?() :: boolean()
  def ffmpeg_available? do
    not is_nil(System.find_executable("ffmpeg"))
  end

  @doc """
  Checks if FFprobe is available on the system.

  ## Returns
    - `true` if FFprobe is available
    - `false` otherwise
  """
  @spec ffprobe_available?() :: boolean()
  def ffprobe_available? do
    not is_nil(System.find_executable("ffprobe"))
  end

  # Private implementation

  defp do_generate_cover(input_path, opts) do
    position = Keyword.get(opts, :position, @default_position)
    quality = Keyword.get(opts, :quality, @default_quality)
    width = Keyword.get(opts, :width, @default_width)

    with :ok <- validate_video_stream(input_path),
         {:ok, seek_time} <- calculate_seek_time(input_path, position),
         {:ok, temp_path} <- create_temp_file(".jpg"),
         :ok <- run_ffmpeg_thumbnail(input_path, temp_path, seek_time, quality, width),
         {:ok, checksum} <- GeneratedMedia.store_file(:cover, temp_path) do
      # Clean up temp file
      File.rm(temp_path)
      {:ok, checksum}
    else
      {:error, :no_video_stream} = error ->
        Logger.warning("Cannot generate cover for #{input_path}: file has no valid video stream")
        error

      {:error, :corrupted_video} = error ->
        Logger.warning(
          "Cannot generate cover for #{input_path}: video stream is corrupted or undecodable"
        )

        error

      {:error, {:ffmpeg_error, _code, output}} = error ->
        cond do
          String.contains?(output, "Cannot determine format of input stream") ->
            Logger.warning(
              "Cannot generate cover for #{input_path}: video stream has no decodable frames"
            )

            {:error, :corrupted_video}

          String.contains?(output, "does not contain any stream") ->
            Logger.warning(
              "Cannot generate cover for #{input_path}: file has no video stream (audio only)"
            )

            {:error, :no_video_stream}

          true ->
            Logger.error("Failed to generate cover for #{input_path}: #{inspect(error)}")
            error
        end

      {:error, reason} = error ->
        Logger.error("Failed to generate cover: #{inspect(reason)}")
        error
    end
  end

  # Check if the file has a valid video stream before attempting to extract frames
  defp validate_video_stream(input_path) do
    # First check if ANY video stream exists
    check_args = [
      "-v",
      "error",
      "-show_entries",
      "stream=codec_type",
      "-of",
      "csv=p=0",
      input_path
    ]

    case run_ffprobe(check_args) do
      {:ok, output} ->
        streams = String.trim(output)

        if String.contains?(streams, "video") do
          # Video stream exists, check its properties
          validate_video_properties(input_path)
        else
          # No video stream - audio only file
          {:error, :no_video_stream}
        end

      {:error, _reason} ->
        # If ffprobe fails entirely, still try to generate
        :ok
    end
  end

  defp validate_video_properties(input_path) do
    args = [
      "-v",
      "error",
      "-select_streams",
      "v:0",
      "-show_entries",
      "stream=pix_fmt",
      "-of",
      "csv=p=0",
      input_path
    ]

    case run_ffprobe(args) do
      {:ok, output} ->
        output = String.trim(output)

        cond do
          # No output means no valid video properties
          output == "" ->
            :ok

          # Video stream exists but has missing/invalid pixel format (common in corrupted files)
          String.contains?(output, "N/A") or String.contains?(output, "none") ->
            # Still try - some files with missing metadata can still be decoded
            :ok

          true ->
            :ok
        end

      {:error, _reason} ->
        # If ffprobe fails, still try to generate - FFmpeg might succeed
        :ok
    end
  end

  defp calculate_seek_time(_input_path, {:seconds, seconds}) when is_number(seconds) do
    {:ok, seconds}
  end

  defp calculate_seek_time(input_path, {:percentage, percentage})
       when is_number(percentage) and percentage >= 0 and percentage <= 100 do
    case get_duration(input_path) do
      {:ok, duration} ->
        seek_time = duration * (percentage / 100)
        {:ok, seek_time}

      {:error, reason} ->
        # Fall back to a reasonable default if we can't get duration
        Logger.warning("Could not get video duration: #{inspect(reason)}, using 10s seek time")
        {:ok, 10.0}
    end
  end

  defp run_ffmpeg_thumbnail(input_path, output_path, seek_time, quality, width) do
    # Try input seeking first (fast), fall back to output seeking (reliable) if it fails
    case try_input_seeking(input_path, output_path, seek_time, quality, width) do
      :ok ->
        :ok

      {:error, _reason} ->
        # Fallback: use output seeking which is slower but handles problematic files better
        try_output_seeking(input_path, output_path, seek_time, quality, width)
    end
  end

  # Input seeking (-ss before -i) is fast but can fail with some files
  defp try_input_seeking(input_path, output_path, seek_time, quality, width) do
    args = [
      # Increase probe size and analysis duration for problematic files
      "-probesize",
      "50M",
      "-analyzeduration",
      "100M",
      "-ss",
      format_time(seek_time),
      "-i",
      input_path,
      "-vframes",
      "1",
      "-q:v",
      to_string(quality),
      "-vf",
      "scale=#{width}:-1",
      "-y",
      output_path
    ]

    run_and_verify(args, output_path)
  end

  # Output seeking (-ss after -i) is slower but more reliable for problematic files
  defp try_output_seeking(input_path, output_path, seek_time, quality, width) do
    # For output seeking, if seek_time is very small or problematic,
    # just grab the first frame
    effective_seek = if seek_time < 0.5, do: 0, else: seek_time

    args = [
      "-probesize",
      "50M",
      "-analyzeduration",
      "100M",
      "-i",
      input_path,
      "-ss",
      format_time(effective_seek),
      "-vframes",
      "1",
      "-q:v",
      to_string(quality),
      "-vf",
      "scale=#{width}:-1",
      "-y",
      output_path
    ]

    case run_and_verify(args, output_path) do
      :ok ->
        :ok

      {:error, _} when effective_seek > 0 ->
        # Last resort: try grabbing the very first frame
        try_first_frame(input_path, output_path, quality, width)

      error ->
        error
    end
  end

  # Last resort: grab the first available frame with aggressive error handling
  defp try_first_frame(input_path, output_path, quality, width) do
    # Try with error ignore options for corrupted files
    args = [
      "-probesize",
      "50M",
      "-analyzeduration",
      "100M",
      # Generate PTS if missing
      "-fflags",
      "+genpts+igndts",
      # Ignore errors during decoding
      "-err_detect",
      "ignore_err",
      "-i",
      input_path,
      "-vframes",
      "1",
      "-q:v",
      to_string(quality),
      "-vf",
      "scale=#{width}:-1",
      "-y",
      output_path
    ]

    case run_and_verify(args, output_path) do
      :ok ->
        :ok

      {:error, _} ->
        # Ultra last resort: try with forced pixel format assumption
        try_with_forced_format(input_path, output_path, quality, width)
    end
  end

  # Some broken files have valid video data but missing pixel format metadata
  # Try forcing common MPEG4 pixel format (yuv420p)
  defp try_with_forced_format(input_path, output_path, quality, width) do
    args = [
      "-probesize",
      "50M",
      "-analyzeduration",
      "100M",
      "-fflags",
      "+genpts+igndts",
      "-err_detect",
      "ignore_err",
      "-i",
      input_path,
      "-vframes",
      "1",
      "-q:v",
      to_string(quality),
      # Force pixel format conversion which may help with missing format
      "-pix_fmt",
      "yuvj420p",
      "-vf",
      "scale=#{width}:-1,format=yuvj420p",
      "-y",
      output_path
    ]

    run_and_verify(args, output_path)
  end

  defp run_and_verify(args, output_path) do
    case Ffmpeg.run(args) do
      {:ok, _output} ->
        if File.exists?(output_path) do
          :ok
        else
          {:error, :output_not_created}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_ffprobe(args) do
    ffprobe = System.find_executable("ffprobe")

    if is_nil(ffprobe) do
      {:error, :ffprobe_not_found}
    else
      case System.cmd(ffprobe, args, stderr_to_stdout: true) do
        {output, 0} ->
          {:ok, output}

        {output, exit_code} ->
          Logger.debug("FFprobe failed with exit code #{exit_code}: #{output}")
          {:error, {:ffprobe_error, exit_code, output}}
      end
    end
  end

  defp format_time(seconds) when is_float(seconds) do
    hours = trunc(seconds / 3600)
    minutes = trunc(rem(trunc(seconds), 3600) / 60)
    secs = :erlang.float_to_binary(seconds - hours * 3600 - minutes * 60, decimals: 2)

    "#{pad_number(hours)}:#{pad_number(minutes)}:#{secs}"
  end

  defp format_time(seconds) when is_integer(seconds) do
    format_time(seconds * 1.0)
  end

  defp pad_number(n), do: String.pad_leading(to_string(n), 2, "0")

  defp create_temp_file(extension) do
    temp_dir = System.tmp_dir!()
    filename = "thumbnail_#{:rand.uniform(1_000_000_000)}#{extension}"
    path = Path.join(temp_dir, filename)
    {:ok, path}
  end
end
