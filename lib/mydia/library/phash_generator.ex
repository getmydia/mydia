defmodule Mydia.Library.PhashGenerator do
  @moduledoc """
  Generates perceptual hashes (pHash) for video files using a difference hash algorithm.

  This module extracts representative frames from video files and computes a 64-bit
  perceptual hash using the difference hash (dHash) algorithm. The dHash is robust
  against minor video variations like compression, resolution changes, and color shifts.

  ## Algorithm

  The dHash algorithm works by:
  1. Extracting a representative frame from the video (default: 20% position)
  2. Resizing the frame to 9x8 pixels grayscale
  3. Computing horizontal gradients (comparing adjacent pixels)
  4. Producing a 64-bit hash where each bit represents whether a pixel is brighter
     than its neighbor to the right

  ## Usage

      # Generate a phash for a media file
      {:ok, hash} = PhashGenerator.generate(media_file)

      # Generate from a file path
      {:ok, hash} = PhashGenerator.generate_from_path("/path/to/video.mp4")

      # Compare two hashes
      distance = PhashGenerator.hamming_distance(hash1, hash2)
      similar? = distance <= 10  # Typically 0-10 = very similar

  ## Requirements

  FFmpeg must be installed and available in the system PATH.
  """

  require Logger

  alias Mydia.Library.Ffmpeg
  alias Mydia.Library.MediaFile
  alias Mydia.Library.ThumbnailGenerator

  @default_position {:percentage, 20}
  @hash_width 9
  @hash_height 8

  @type position :: {:seconds, number()} | {:percentage, number()}
  @type generate_opts :: [position: position()]

  @doc """
  Generates a perceptual hash from a video file.

  Extracts a frame from the video, computes a 64-bit difference hash, and
  returns it as a 16-character hexadecimal string.

  ## Parameters
    - `media_file` - The MediaFile struct (must have library_path preloaded)
    - `opts` - Optional settings:
      - `:position` - Where to extract the frame (default: `{:percentage, 20}`)

  ## Returns
    - `{:ok, hash}` - The 16-character hexadecimal hash string
    - `{:error, reason}` - Error description

  ## Examples

      {:ok, hash} = PhashGenerator.generate(media_file)
      # => {:ok, "a1b2c3d4e5f60708"}
  """
  @spec generate(MediaFile.t(), generate_opts()) :: {:ok, String.t()} | {:error, term()}
  def generate(%MediaFile{} = media_file, opts \\ []) do
    input_path = MediaFile.absolute_path(media_file)

    if is_nil(input_path) do
      {:error, :library_path_not_preloaded}
    else
      do_generate(input_path, opts)
    end
  end

  @doc """
  Generates a perceptual hash from a file path.

  Same as `generate/2` but takes a file path directly instead of a MediaFile.
  """
  @spec generate_from_path(Path.t(), generate_opts()) :: {:ok, String.t()} | {:error, term()}
  def generate_from_path(input_path, opts \\ []) when is_binary(input_path) do
    if File.exists?(input_path) do
      do_generate(input_path, opts)
    else
      {:error, :file_not_found}
    end
  end

  @doc """
  Calculates the Hamming distance between two perceptual hashes.

  The Hamming distance is the number of bit positions where the two hashes differ.
  A lower distance indicates more similar images:
  - 0: Identical or nearly identical
  - 1-10: Very similar (likely same video, different encoding)
  - 11-20: Somewhat similar (may be related content)
  - 21+: Different content

  ## Parameters
    - `hash1` - First hash as a 16-character hexadecimal string
    - `hash2` - Second hash as a 16-character hexadecimal string

  ## Returns
    - The number of differing bits (0-64)

  ## Examples

      distance = PhashGenerator.hamming_distance("a1b2c3d4e5f60708", "a1b2c3d4e5f6070a")
      # => 2
  """
  @spec hamming_distance(String.t(), String.t()) :: non_neg_integer()
  def hamming_distance(hash1, hash2)
      when is_binary(hash1) and is_binary(hash2) and byte_size(hash1) == 16 and
             byte_size(hash2) == 16 do
    {:ok, int1} = parse_hash(hash1)
    {:ok, int2} = parse_hash(hash2)

    xor_result = Bitwise.bxor(int1, int2)
    count_bits(xor_result)
  end

  def hamming_distance(hash1, hash2) when is_binary(hash1) and is_binary(hash2) do
    # Handle malformed hashes gracefully
    Logger.warning(
      "Invalid hash format for hamming distance: #{inspect(hash1)}, #{inspect(hash2)}"
    )

    64
  end

  @doc """
  Checks if two hashes are similar within a given threshold.

  ## Parameters
    - `hash1` - First hash
    - `hash2` - Second hash
    - `threshold` - Maximum Hamming distance to consider similar (default: 10)

  ## Returns
    - `true` if the hashes are similar, `false` otherwise
  """
  @spec similar?(String.t(), String.t(), non_neg_integer()) :: boolean()
  def similar?(hash1, hash2, threshold \\ 10) do
    hamming_distance(hash1, hash2) <= threshold
  end

  # Private implementation

  defp do_generate(input_path, opts) do
    position = Keyword.get(opts, :position, @default_position)

    with {:ok, seek_time} <- calculate_seek_time(input_path, position),
         {:ok, pixels} <- extract_grayscale_pixels(input_path, seek_time),
         {:ok, hash} <- compute_dhash(pixels) do
      {:ok, hash}
    else
      {:error, :no_video_stream} = error ->
        Logger.warning("Cannot generate phash for #{input_path}: file has no valid video stream")
        error

      {:error, reason} = error ->
        Logger.error("Failed to generate phash: #{inspect(reason)}")
        error
    end
  end

  defp calculate_seek_time(_input_path, {:seconds, seconds}) when is_number(seconds) do
    {:ok, seconds}
  end

  defp calculate_seek_time(input_path, {:percentage, percentage})
       when is_number(percentage) and percentage >= 0 and percentage <= 100 do
    case ThumbnailGenerator.get_duration(input_path) do
      {:ok, duration} ->
        seek_time = duration * (percentage / 100)
        {:ok, seek_time}

      {:error, reason} ->
        Logger.warning("Could not get video duration: #{inspect(reason)}, using 10s seek time")
        {:ok, 10.0}
    end
  end

  defp extract_grayscale_pixels(input_path, seek_time) do
    # Extract a 9x8 grayscale frame as raw pixel data
    # We use 9x8 because dHash needs 9 columns to produce 8 gradient comparisons per row
    args = [
      "-ss",
      format_time(seek_time),
      "-i",
      input_path,
      "-vframes",
      "1",
      "-vf",
      "scale=#{@hash_width}:#{@hash_height}:flags=area,format=gray",
      "-f",
      "rawvideo",
      "-pix_fmt",
      "gray",
      "-"
    ]

    # stderr is kept out of the captured output here: ffmpeg writes the raw
    # pixel bytes to stdout ("-"), so merging its banner/log text from
    # stderr would corrupt the fixed-size payload checked below.
    case Ffmpeg.run(args, stderr_to_stdout: false) do
      {:ok, output} when byte_size(output) == @hash_width * @hash_height ->
        {:ok, output}

      {:ok, output} when byte_size(output) == 0 ->
        # No output - possibly no video stream or seek beyond end
        {:error, :no_video_stream}

      {:ok, output} ->
        # Unexpected output size
        Logger.warning(
          "Unexpected pixel data size: #{byte_size(output)}, expected #{@hash_width * @hash_height}"
        )

        {:error, {:unexpected_output_size, byte_size(output)}}

      {:error, {:ffmpeg_error, _code, output}} when is_binary(output) ->
        cond do
          String.contains?(output, "does not contain any stream") ->
            {:error, :no_video_stream}

          String.contains?(output, "Invalid data found") ->
            {:error, :corrupted_video}

          true ->
            {:error, :ffmpeg_error}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp compute_dhash(pixels) when byte_size(pixels) == @hash_width * @hash_height do
    # Convert binary to list of pixel values
    pixel_list = :binary.bin_to_list(pixels)

    # Split into rows
    rows = Enum.chunk_every(pixel_list, @hash_width)

    # For each row, compare adjacent pixels (left < right = 1, otherwise 0)
    # This produces 8 bits per row * 8 rows = 64 bits
    bits =
      rows
      |> Enum.flat_map(fn row ->
        row
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [left, right] ->
          if left < right, do: 1, else: 0
        end)
      end)

    # Convert 64 bits to a 64-bit integer, then to hex string
    hash_int =
      bits
      |> Enum.with_index()
      |> Enum.reduce(0, fn {bit, index}, acc ->
        Bitwise.bor(acc, Bitwise.bsl(bit, 63 - index))
      end)

    hash_hex =
      hash_int
      |> Integer.to_string(16)
      |> String.downcase()
      |> String.pad_leading(16, "0")

    {:ok, hash_hex}
  end

  defp compute_dhash(_pixels), do: {:error, :invalid_pixel_data}

  defp parse_hash(hash) when is_binary(hash) and byte_size(hash) == 16 do
    case Integer.parse(hash, 16) do
      {value, ""} -> {:ok, value}
      _ -> {:error, :invalid_hash_format}
    end
  end

  defp count_bits(0), do: 0

  defp count_bits(n) do
    Bitwise.band(n, 1) + count_bits(Bitwise.bsr(n, 1))
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
end
