defmodule Mydia.Library.PreviewGenerator do
  @moduledoc """
  Generates video preview clips for hover previews.

  This module creates short video clips that can be played on hover to give users
  a quick preview of the video content. It extracts multiple short segments from
  different parts of the video and concatenates them into a single preview file.

  Implementation inspired by Stash (https://github.com/stashapp/stash).

  ## Usage

      # Generate preview for a video file
      {:ok, %{preview_checksum: checksum, duration: duration}} =
        PreviewGenerator.generate(media_file)

      # With custom options
      {:ok, result} = PreviewGenerator.generate(media_file,
        segment_count: 5,        # Number of segments to extract
        segment_duration: 2.0,   # Duration of each segment in seconds
        skip_start_percent: 0.05 # Skip first 5% of video
      )

  ## Output Format

  The output is an MP4 video file with:
  - H.264 video codec
  - 640px width (height auto-scaled to preserve aspect ratio)
  - No audio track (muted preview)
  - Approximately 10 seconds total duration (5 segments x 2 seconds)

  ## Requirements

  FFmpeg must be installed and available in the system PATH.
  """

  require Logger

  alias Mydia.Library.Ffmpeg
  alias Mydia.Library.GeneratedMedia
  alias Mydia.Library.MediaFile
  alias Mydia.Library.ThumbnailGenerator

  # Preview configuration
  @default_segment_count 5
  @default_segment_duration 2.0
  @default_skip_start_percent 0.05
  @default_skip_end_percent 0.05
  @default_width 640
  @default_crf 23

  @type generate_opts :: [
          segment_count: pos_integer(),
          segment_duration: float(),
          skip_start_percent: float(),
          skip_end_percent: float(),
          width: pos_integer(),
          crf: pos_integer()
        ]

  @type generate_result :: %{
          preview_checksum: String.t(),
          duration: float()
        }

  @doc """
  Generates a video preview from a video file.

  Extracts multiple short segments evenly distributed across the video
  and concatenates them into a single preview file.

  ## Parameters
    - `media_file` - The MediaFile struct (must have library_path preloaded)
    - `opts` - Optional settings:
      - `:segment_count` - Number of segments (default: #{@default_segment_count})
      - `:segment_duration` - Duration per segment in seconds (default: #{@default_segment_duration})
      - `:skip_start_percent` - Skip percentage at start (default: #{@default_skip_start_percent})
      - `:skip_end_percent` - Skip percentage at end (default: #{@default_skip_end_percent})
      - `:width` - Output width in pixels (default: #{@default_width})
      - `:crf` - Quality (0-51, lower is better, default: #{@default_crf})

  ## Returns
    - `{:ok, result}` - Map with preview_checksum and duration
    - `{:error, reason}` - Error description
  """
  @spec generate(MediaFile.t(), generate_opts()) :: {:ok, generate_result()} | {:error, term()}
  def generate(%MediaFile{} = media_file, opts \\ []) do
    input_path = MediaFile.absolute_path(media_file)

    if is_nil(input_path) do
      {:error, :library_path_not_preloaded}
    else
      do_generate(input_path, opts)
    end
  end

  @doc """
  Generates a video preview from a file path.

  Same as `generate/2` but takes a file path directly instead of a MediaFile.
  """
  @spec generate_from_path(Path.t(), generate_opts()) ::
          {:ok, generate_result()} | {:error, term()}
  def generate_from_path(input_path, opts \\ []) when is_binary(input_path) do
    if File.exists?(input_path) do
      do_generate(input_path, opts)
    else
      {:error, :file_not_found}
    end
  end

  # Private implementation

  defp do_generate(input_path, opts) do
    segment_count = Keyword.get(opts, :segment_count, @default_segment_count)
    segment_duration = Keyword.get(opts, :segment_duration, @default_segment_duration)
    skip_start_percent = Keyword.get(opts, :skip_start_percent, @default_skip_start_percent)
    skip_end_percent = Keyword.get(opts, :skip_end_percent, @default_skip_end_percent)
    width = Keyword.get(opts, :width, @default_width)
    crf = Keyword.get(opts, :crf, @default_crf)

    with {:ok, duration} <- ThumbnailGenerator.get_duration(input_path),
         {:ok, segment_starts} <-
           calculate_segment_starts(
             duration,
             segment_count,
             segment_duration,
             skip_start_percent,
             skip_end_percent
           ),
         {:ok, temp_dir} <- create_temp_directory(),
         {:ok, segment_paths} <-
           extract_segments(input_path, segment_starts, segment_duration, temp_dir, width, crf),
         {:ok, preview_path} <- concatenate_segments(segment_paths, temp_dir),
         {:ok, preview_checksum} <- GeneratedMedia.store_file(:preview, preview_path) do
      cleanup_temp_directory(temp_dir)

      preview_duration = length(segment_starts) * segment_duration

      {:ok,
       %{
         preview_checksum: preview_checksum,
         duration: preview_duration
       }}
    else
      {:error, reason} = error ->
        Logger.error("Failed to generate video preview: #{inspect(reason)}")
        error
    end
  end

  # Calculate start times for each segment, evenly distributed across the video
  defp calculate_segment_starts(
         duration,
         segment_count,
         segment_duration,
         skip_start_percent,
         skip_end_percent
       ) do
    skip_start = duration * skip_start_percent
    skip_end = duration * skip_end_percent
    effective_start = skip_start
    effective_end = duration - skip_end
    effective_duration = effective_end - effective_start

    # Check if video is long enough for all segments
    total_segment_duration = segment_count * segment_duration

    if effective_duration < total_segment_duration do
      # Video is too short - use what we can
      if effective_duration < segment_duration do
        {:error, :video_too_short}
      else
        # Reduce segment count to fit
        adjusted_count = max(1, trunc(effective_duration / segment_duration))
        step = effective_duration / adjusted_count

        starts =
          0..(adjusted_count - 1)
          |> Enum.map(fn i -> effective_start + i * step end)

        {:ok, starts}
      end
    else
      # Distribute segments evenly across effective duration
      step = (effective_duration - segment_duration) / max(1, segment_count - 1)

      starts =
        0..(segment_count - 1)
        |> Enum.map(fn i -> effective_start + i * step end)
        # Ensure segments don't extend past effective_end
        |> Enum.filter(&(&1 + segment_duration <= effective_end + 0.1))

      if starts == [] do
        {:error, :no_segments_possible}
      else
        {:ok, starts}
      end
    end
  end

  # Extract each segment as a separate video file
  defp extract_segments(input_path, segment_starts, segment_duration, temp_dir, width, crf) do
    results =
      segment_starts
      |> Enum.with_index()
      |> Enum.map(fn {start_time, index} ->
        output_path =
          Path.join(temp_dir, "segment_#{String.pad_leading(to_string(index), 3, "0")}.mp4")

        case extract_single_segment(
               input_path,
               start_time,
               segment_duration,
               output_path,
               width,
               crf
             ) do
          :ok -> {:ok, output_path}
          {:error, reason} -> {:error, {index, reason}}
        end
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      {:ok, Enum.map(results, fn {:ok, path} -> path end)}
    else
      {:error, {:segment_extraction_failed, errors}}
    end
  end

  defp extract_single_segment(input_path, start_time, duration, output_path, width, crf) do
    args = [
      # Fast seek to start position
      "-ss",
      format_time(start_time),
      "-i",
      input_path,
      # Duration of segment
      "-t",
      to_string(duration * 1.0),
      # Video filters: scale, ensure even dimensions for H.264
      "-vf",
      "scale=#{width}:-2",
      # Video codec settings (H.264)
      "-c:v",
      "libx264",
      "-profile:v",
      "high",
      "-level",
      "4.2",
      "-crf",
      to_string(crf),
      "-preset",
      "fast",
      "-pix_fmt",
      "yuv420p",
      # No audio
      "-an",
      # Handle variable framerate
      "-vsync",
      "2",
      # Overwrite
      "-y",
      output_path
    ]

    case Ffmpeg.run(args) do
      {:ok, _output} ->
        if File.exists?(output_path) do
          :ok
        else
          {:error, {:segment_not_created, start_time}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Concatenate all segments into a single preview video
  defp concatenate_segments(segment_paths, temp_dir) do
    output_path = Path.join(temp_dir, "preview.mp4")
    list_path = Path.join(temp_dir, "segments.txt")

    # Create concat list file
    list_content =
      segment_paths
      |> Enum.map_join("\n", &"file '#{&1}'")

    File.write!(list_path, list_content)

    args = [
      "-f",
      "concat",
      "-safe",
      "0",
      "-i",
      list_path,
      # Copy streams (already encoded)
      "-c",
      "copy",
      "-y",
      output_path
    ]

    case Ffmpeg.run(args) do
      {:ok, _} ->
        if File.exists?(output_path) do
          {:ok, output_path}
        else
          {:error, :preview_not_created}
        end

      {:error, reason} ->
        {:error, reason}
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

  defp create_temp_directory do
    temp_dir = Path.join(System.tmp_dir!(), "preview_#{:rand.uniform(1_000_000_000)}")

    case File.mkdir_p(temp_dir) do
      :ok -> {:ok, temp_dir}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_temp_directory(temp_dir) do
    File.rm_rf(temp_dir)
  end
end
