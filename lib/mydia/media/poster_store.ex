defmodule Mydia.Media.PosterStore do
  @moduledoc """
  Filesystem side of custom posters.

  Uploaded posters live under `<generated_media_path>/posters/` and are named
  `<media_item_id>-<sha8>.<ext>`, where `sha8` is the first 8 hex characters of
  the image's SHA-256. They are served at `/generated/posters/<filename>`.
  """

  alias Mydia.Library.GeneratedMedia

  @url_prefix "/generated/posters/"
  @max_bytes 10_000_000
  # \z, not $: $ also matches before a trailing newline.
  @filename_regex ~r/\A[0-9a-f-]+-[0-9a-f]{8}\.(jpg|png|webp)\z/

  @doc "The directory hosted posters are written to."
  @spec storage_dir() :: Path.t()
  def storage_dir, do: Path.join(GeneratedMedia.base_path(), "posters")

  @doc "Detects JPEG, PNG or WebP by magic bytes."
  @spec detect_format(binary()) :: {:ok, String.t()} | {:error, :unsupported_format}
  def detect_format(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "jpg"}
  def detect_format(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: {:ok, "png"}
  def detect_format(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: {:ok, "webp"}
  def detect_format(_), do: {:error, :unsupported_format}

  @doc """
  Writes `binary` for the media item and returns its `/generated/posters/...` path.
  """
  @spec write(String.t(), binary()) ::
          {:ok, String.t()} | {:error, :unsupported_format | :too_large | File.posix()}
  def write(media_item_id, binary) when is_binary(binary) do
    with :ok <- check_size(binary),
         {:ok, ext} <- detect_format(binary) do
      sha8 = :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower) |> binary_part(0, 8)
      filename = "#{media_item_id}-#{sha8}.#{ext}"
      dir = storage_dir()

      with :ok <- File.mkdir_p(dir),
           :ok <- write_new(Path.join(dir, filename), binary) do
        {:ok, @url_prefix <> filename}
      end
    end
  end

  # Names are content-addressed, so an existing file already holds these
  # bytes and may be in use by the item. Rewriting it would truncate a file a
  # client could be reading. New bytes go to a temporary file first and are
  # renamed into place, so a crash, a full disk or a concurrent upload never
  # leaves a truncated file under the final name. The temporary name starts
  # with a dot and ends in `.tmp`, so `@filename_regex` never serves it.
  defp write_new(path, binary) do
    if File.regular?(path) do
      :ok
    else
      tmp = temp_path(path)

      with :ok <- File.write(tmp, binary),
           :ok <- File.rename(tmp, path) do
        :ok
      else
        error ->
          _ = File.rm(tmp)
          error
      end
    end
  end

  defp temp_path(path) do
    suffix = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    Path.join(Path.dirname(path), ".#{Path.basename(path)}.#{suffix}.tmp")
  end

  defp check_size(binary) when byte_size(binary) > @max_bytes, do: {:error, :too_large}
  defp check_size(_), do: :ok

  @doc """
  Removes a hosted poster file. Anything that is not a
  `/generated/posters/<basename>` path is ignored.
  """
  @spec delete(String.t() | nil) :: :ok
  def delete(url) do
    if hosted?(url) do
      _ = File.rm(Path.join(storage_dir(), Path.basename(url)))
    end

    :ok
  end

  @doc "True when the value is a path to a hosted poster file."
  @spec hosted?(String.t() | nil) :: boolean()
  def hosted?(@url_prefix <> name) when name != "" do
    name == Path.basename(name) and name not in [".", ".."]
  end

  def hosted?(_), do: false

  @doc """
  Resolves a hosted poster filename to its path on disk. Only names matching
  the poster naming scheme and present on disk resolve.
  """
  @spec path_for(String.t()) :: {:ok, Path.t()} | {:error, :not_found}
  def path_for(filename) when is_binary(filename) do
    path = Path.join(storage_dir(), filename)

    if Regex.match?(@filename_regex, filename) and File.regular?(path) do
      {:ok, path}
    else
      {:error, :not_found}
    end
  end

  def path_for(_), do: {:error, :not_found}
end
