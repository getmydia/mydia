defmodule Mydia.Subtitles.Hash do
  @moduledoc """
  Implements OpenSubtitles moviehash algorithm for video file identification.

  The moviehash algorithm creates a unique hash by:
  1. Reading first 64KB of the file
  2. Reading last 64KB of the file
  3. Adding the file size to the sum
  4. Computing checksum as 64-bit integer

  This provides a quick fingerprint without reading the entire file.
  """

  import Bitwise

  @chunk_size 65_536

  @doc """
  Calculate OpenSubtitles moviehash for a video file.

  Returns `{:ok, hash, file_size}` where hash is a 16-character lowercase
  hexadecimal string, or `{:error, reason}` if the file cannot be processed.

  ## Examples

      iex> calculate_hash("/path/to/video.mp4")
      {:ok, "8e245d9679d31e12", 1_234_567_890}

      iex> calculate_hash("/nonexistent/file.mp4")
      {:error, :enoent}
  """
  @spec calculate_hash(String.t()) :: {:ok, String.t(), integer()} | {:error, atom()}
  def calculate_hash(file_path) do
    with {:ok, file_size} <- get_file_size(file_path),
         {:ok, hash} <- compute_hash(file_path, file_size) do
      {:ok, hash, file_size}
    end
  end

  # Get file size, returning error if file doesn't exist or isn't accessible
  defp get_file_size(file_path) do
    case File.stat(file_path) do
      {:ok, %{size: size}} -> {:ok, size}
      {:error, reason} -> {:error, reason}
    end
  end

  # Compute the actual hash
  defp compute_hash(file_path, file_size) when file_size < @chunk_size do
    # For files smaller than one chunk, read entire file
    case File.read(file_path) do
      {:ok, data} ->
        hash = calculate_checksum(data, file_size)
        {:ok, format_hash(hash)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp compute_hash(file_path, file_size) do
    with {:ok, file} <- File.open(file_path, [:read, :binary]),
         {:ok, first_chunk} <- read_chunk(file, 0),
         {:ok, last_chunk} <- read_chunk(file, file_size - @chunk_size),
         :ok <- File.close(file) do
      hash = calculate_checksum(first_chunk <> last_chunk, file_size)
      {:ok, format_hash(hash)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Read a chunk from the file at the specified position
  defp read_chunk(file, position) do
    case :file.position(file, position) do
      {:ok, _new_position} ->
        case IO.binread(file, @chunk_size) do
          data when is_binary(data) -> {:ok, data}
          {:error, reason} -> {:error, reason}
          :eof -> {:error, :eof}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Calculate checksum by summing 64-bit integers and adding file size
  defp calculate_checksum(data, file_size) do
    # Start with file size as initial hash
    hash = file_size

    # Add all 64-bit little-endian integers from the data
    data
    |> chunk_into_64bit_integers()
    |> Enum.reduce(hash, fn int, acc ->
      # Keep only lower 64 bits using bitwise AND with max 64-bit value
      band(acc + int, 0xFFFFFFFFFFFFFFFF)
    end)
  end

  # Split binary data into 64-bit little-endian integers
  defp chunk_into_64bit_integers(data) do
    chunk_into_64bit_integers(data, [])
  end

  defp chunk_into_64bit_integers(<<int::little-unsigned-64, rest::binary>>, acc) do
    chunk_into_64bit_integers(rest, [int | acc])
  end

  defp chunk_into_64bit_integers(_remaining, acc) do
    # Ignore any remaining bytes that don't make a full 64-bit integer
    Enum.reverse(acc)
  end

  # Format hash as 16-character lowercase hexadecimal string
  defp format_hash(hash) do
    hash
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(16, "0")
  end
end
