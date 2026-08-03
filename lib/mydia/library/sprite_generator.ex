defmodule Mydia.Library.SpriteGenerator do
  @moduledoc """
  Generates sprite sheets and WebVTT files for video scrubbing timelines.

  This module extracts a fixed number of frames from video files, stitches them
  into a single sprite sheet image, and generates a WebVTT file that maps timestamps
  to sprite coordinates for video player timeline previews.

  The frame interval is calculated dynamically based on video duration to ensure
  consistent sprite sizes regardless of video length. This approach is inspired by
  Stash (https://github.com/stashapp/stash).

  ## Usage

      # Generate sprite sheet and VTT for a video file
      {:ok, %{sprite_checksum: sprite, vtt_checksum: vtt}} =
        SpriteGenerator.generate(media_file)

      # With custom options
      {:ok, result} = SpriteGenerator.generate(media_file,
        frame_count: 81,       # Extract 81 frames total (9x9 grid)
        thumbnail_width: 160,  # Each thumbnail 160px wide
        thumbnail_height: 90,  # Each thumbnail 90px tall
        columns: 9,            # 9 thumbnails per row
        skip_start: 5,         # Skip first 5 seconds
        skip_end: 5            # Skip last 5 seconds
      )

  ## Output Format

  The sprite sheet is a single JPEG image with thumbnails arranged in a grid.
  The WebVTT file maps time ranges to sprite coordinates using the `#xywh=` fragment:

      WEBVTT

      00:00:00.000 --> 00:00:05.000
      sprite.jpg#xywh=0,0,160,90

      00:00:05.000 --> 00:00:10.000
      sprite.jpg#xywh=160,0,160,90

  ## Requirements

  FFmpeg must be installed and available in the system PATH.
  """

  require Logger

  alias Mydia.Library.Ffmpeg
  alias Mydia.Library.GeneratedMedia
  alias Mydia.Library.MediaFile
  alias Mydia.Library.ThumbnailGenerator

  # Sprite grid configuration (matching Stash defaults)
  @default_sprite_rows 9
  @default_sprite_cols 9
  @default_frame_count @default_sprite_rows * @default_sprite_cols

  # Thumbnail configuration
  @default_thumbnail_width 160
  @default_thumbnail_height 90
  @default_quality 3

  # Skip configuration (as percentages of duration)
  @default_skip_start_percent 0.02
  @default_skip_end_percent 0.02

  @type generate_opts :: [
          frame_count: pos_integer(),
          thumbnail_width: pos_integer(),
          thumbnail_height: pos_integer(),
          columns: pos_integer(),
          quality: pos_integer(),
          skip_start: number(),
          skip_end: number()
        ]

  @type generate_result :: %{
          sprite_checksum: String.t(),
          vtt_checksum: String.t(),
          frame_count: pos_integer()
        }

  @doc """
  Generates a sprite sheet and WebVTT file from a video file.

  Extracts a fixed number of frames distributed evenly across the video,
  creates a sprite sheet with all frames arranged in a grid, and generates
  a WebVTT file mapping timestamps to coordinates.

  ## Parameters
    - `media_file` - The MediaFile struct (must have library_path preloaded)
    - `opts` - Optional settings:
      - `:frame_count` - Total frames to extract (default: #{@default_frame_count})
      - `:thumbnail_width` - Width of each thumbnail (default: #{@default_thumbnail_width})
      - `:thumbnail_height` - Height of each thumbnail (default: #{@default_thumbnail_height})
      - `:columns` - Number of thumbnails per row (default: #{@default_sprite_cols})
      - `:quality` - JPEG quality 1-31, lower is better (default: #{@default_quality})
      - `:skip_start` - Seconds to skip at start (default: 2% of duration)
      - `:skip_end` - Seconds to skip at end (default: 2% of duration)

  ## Returns
    - `{:ok, result}` - Map with sprite_checksum, vtt_checksum, and frame_count
    - `{:error, reason}` - Error description

  ## Examples

      {:ok, result} = SpriteGenerator.generate(media_file)
      {:ok, result} = SpriteGenerator.generate(media_file, frame_count: 64, columns: 8)
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
  Generates a sprite sheet and WebVTT file from a file path.

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
    frame_count = Keyword.get(opts, :frame_count, @default_frame_count)
    thumb_width = Keyword.get(opts, :thumbnail_width, @default_thumbnail_width)
    thumb_height = Keyword.get(opts, :thumbnail_height, @default_thumbnail_height)
    columns = Keyword.get(opts, :columns, @default_sprite_cols)
    quality = Keyword.get(opts, :quality, @default_quality)
    skip_start = Keyword.get(opts, :skip_start, :default)
    skip_end = Keyword.get(opts, :skip_end, :default)

    with {:ok, duration} <- ThumbnailGenerator.get_duration(input_path),
         {:ok, timestamps, interval} <-
           calculate_timestamps(duration, frame_count, skip_start, skip_end),
         {:ok, temp_dir} <- create_temp_directory(),
         {:ok, frame_paths} <-
           extract_frames(input_path, timestamps, temp_dir, thumb_width, thumb_height),
         {:ok, sprite_path} <- create_sprite_sheet(frame_paths, temp_dir, columns, quality),
         {:ok, sprite_checksum} <- GeneratedMedia.store_file(:sprite, sprite_path),
         {:ok, vtt_content} <-
           generate_vtt(timestamps, interval, sprite_checksum, thumb_width, thumb_height, columns),
         {:ok, vtt_checksum} <- GeneratedMedia.store(:vtt, vtt_content) do
      # Clean up temp files
      cleanup_temp_directory(temp_dir)

      {:ok,
       %{
         sprite_checksum: sprite_checksum,
         vtt_checksum: vtt_checksum,
         frame_count: length(timestamps)
       }}
    else
      {:error, reason} = error ->
        Logger.error("Failed to generate sprite sheet: #{inspect(reason)}")
        error
    end
  end

  # Calculate timestamps for frame extraction based on fixed frame count
  # Returns timestamps and the computed interval for VTT generation
  defp calculate_timestamps(duration, frame_count, skip_start_opt, skip_end_opt) do
    # Calculate skip values (use percentage of duration if :default)
    skip_start =
      case skip_start_opt do
        :default -> duration * @default_skip_start_percent
        value when is_number(value) -> value
      end

    skip_end =
      case skip_end_opt do
        :default -> duration * @default_skip_end_percent
        value when is_number(value) -> value
      end

    effective_start = skip_start
    effective_end = max(0, duration - skip_end)
    effective_duration = effective_end - effective_start

    if effective_duration <= 0 do
      {:error, :video_too_short}
    else
      # Calculate interval to distribute frames evenly across the video
      interval = effective_duration / frame_count

      # Generate timestamps starting from effective_start
      timestamps =
        0..(frame_count - 1)
        |> Enum.map(fn i -> effective_start + i * interval end)
        |> Enum.filter(&(&1 < effective_end))

      if timestamps == [] do
        {:error, :no_frames_to_extract}
      else
        {:ok, timestamps, interval}
      end
    end
  end

  defp extract_frames(input_path, timestamps, temp_dir, width, height) do
    frame_paths =
      timestamps
      |> Enum.with_index()
      |> Enum.map(fn {timestamp, index} ->
        output_path =
          Path.join(temp_dir, "frame_#{String.pad_leading(to_string(index), 5, "0")}.jpg")

        {timestamp, output_path}
      end)

    results =
      frame_paths
      |> Enum.map(fn {timestamp, output_path} ->
        extract_single_frame(input_path, timestamp, output_path, width, height)
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      {:ok, Enum.map(frame_paths, fn {_, path} -> path end)}
    else
      {:error, {:frame_extraction_failed, errors}}
    end
  end

  defp extract_single_frame(input_path, timestamp, output_path, width, height) do
    args = [
      "-ss",
      format_time(timestamp),
      "-i",
      input_path,
      "-vframes",
      "1",
      "-vf",
      "scale=#{width}:#{height}:force_original_aspect_ratio=decrease,pad=#{width}:#{height}:(ow-iw)/2:(oh-ih)/2",
      "-y",
      output_path
    ]

    case Ffmpeg.run(args) do
      {:ok, _output} ->
        if File.exists?(output_path) do
          :ok
        else
          {:error, {:frame_not_created, timestamp}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_sprite_sheet(frame_paths, temp_dir, columns, quality) do
    frame_count = length(frame_paths)
    rows = ceil(frame_count / columns)
    output_path = Path.join(temp_dir, "sprite.jpg")

    # Create a text file listing all input frames for the montage
    list_path = Path.join(temp_dir, "frames.txt")

    list_content = Enum.map_join(frame_paths, "\n", &"file '#{&1}'")

    File.write!(list_path, list_content)

    # Build inputs list for FFmpeg
    inputs =
      frame_paths
      |> Enum.flat_map(fn path -> ["-i", path] end)

    # Create a temporary video from all frames using concat filter
    concat_path = Path.join(temp_dir, "concat.mp4")

    concat_args =
      inputs ++
        [
          "-filter_complex",
          "[0:v]" <>
            Enum.map_join(1..(frame_count - 1), "", fn i -> "[#{i}:v]" end) <>
            "concat=n=#{frame_count}:v=1[out]",
          "-map",
          "[out]",
          "-c:v",
          "libx264",
          "-preset",
          "ultrafast",
          "-y",
          concat_path
        ]

    case Ffmpeg.run(concat_args) do
      {:ok, _} ->
        # Now apply tile filter to create sprite sheet
        tile_args = [
          "-i",
          concat_path,
          "-vf",
          "tile=#{columns}x#{rows}",
          "-q:v",
          to_string(quality),
          "-y",
          output_path
        ]

        case Ffmpeg.run(tile_args) do
          {:ok, _} ->
            if File.exists?(output_path) do
              {:ok, output_path}
            else
              {:error, :sprite_not_created}
            end

          error ->
            error
        end

      {:error, _} ->
        # Fall back to montage via vstack/hstack approach
        create_sprite_sheet_fallback(frame_paths, output_path, columns, quality)
    end
  end

  defp create_sprite_sheet_fallback(frame_paths, output_path, columns, quality) do
    # Use a more reliable approach: scale and tile using vstack/hstack
    frame_count = length(frame_paths)
    rows = ceil(frame_count / columns)

    # Pad frame_paths to fill the grid
    padding_count = rows * columns - frame_count

    padded_paths =
      if padding_count > 0 do
        # Use the last frame as padding (will be cropped anyway)
        frame_paths ++ List.duplicate(List.last(frame_paths), padding_count)
      else
        frame_paths
      end

    inputs = Enum.flat_map(padded_paths, fn path -> ["-i", path] end)

    # Build filter: hstack for each row, then vstack all rows
    row_filters =
      padded_paths
      |> Enum.chunk_every(columns)
      |> Enum.with_index()
      |> Enum.map(fn {row_paths, row_idx} ->
        input_refs =
          row_paths
          |> Enum.with_index()
          |> Enum.map_join("", fn {_, col_idx} ->
            global_idx = row_idx * columns + col_idx
            "[#{global_idx}:v]"
          end)

        "#{input_refs}hstack=inputs=#{length(row_paths)}[row#{row_idx}]"
      end)

    row_labels = Enum.map_join(0..(rows - 1), "", &"[row#{&1}]")
    vstack_filter = "#{row_labels}vstack=inputs=#{rows}[out]"

    filter_complex = Enum.join(row_filters ++ [vstack_filter], ";")

    args =
      inputs ++
        [
          "-filter_complex",
          filter_complex,
          "-map",
          "[out]",
          "-q:v",
          to_string(quality),
          "-y",
          output_path
        ]

    case Ffmpeg.run(args) do
      {:ok, _} ->
        if File.exists?(output_path) do
          {:ok, output_path}
        else
          {:error, :sprite_not_created}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp generate_vtt(timestamps, interval, sprite_checksum, thumb_width, thumb_height, columns) do
    sprite_filename = "#{sprite_checksum}.jpg"

    cues =
      timestamps
      |> Enum.with_index()
      |> Enum.map(fn {timestamp, index} ->
        start_time = format_vtt_time(timestamp)
        end_time = format_vtt_time(timestamp + interval)

        # Calculate position in sprite grid
        col = rem(index, columns)
        row = div(index, columns)
        x = col * thumb_width
        y = row * thumb_height

        """
        #{start_time} --> #{end_time}
        #{sprite_filename}#xywh=#{x},#{y},#{thumb_width},#{thumb_height}
        """
      end)

    vtt_content = "WEBVTT\n\n" <> Enum.join(cues, "\n")

    {:ok, vtt_content}
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

  defp format_vtt_time(seconds) when is_number(seconds) do
    hours = trunc(seconds / 3600)
    minutes = trunc(rem(trunc(seconds), 3600) / 60)
    secs = trunc(seconds) - hours * 3600 - minutes * 60
    millis = trunc((seconds - trunc(seconds)) * 1000)

    "#{pad_number(hours)}:#{pad_number(minutes)}:#{pad_number(secs)}.#{pad_millis(millis)}"
  end

  defp pad_number(n), do: String.pad_leading(to_string(n), 2, "0")
  defp pad_millis(n), do: String.pad_leading(to_string(n), 3, "0")

  defp create_temp_directory do
    temp_dir = Path.join(System.tmp_dir!(), "sprite_#{:rand.uniform(1_000_000_000)}")

    case File.mkdir_p(temp_dir) do
      :ok -> {:ok, temp_dir}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_temp_directory(temp_dir) do
    File.rm_rf(temp_dir)
  end
end
