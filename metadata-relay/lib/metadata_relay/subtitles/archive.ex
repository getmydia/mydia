defmodule MetadataRelay.Subtitles.Archive do
  @moduledoc """
  Extracts a single subtitle from an archive downloaded from a provider.

  SubDL and several other providers ship subtitles inside ZIP files. The archive
  arrives from a third party, so nothing in it is trusted: entry names are
  checked before use, and the total expanded size is capped so a small download
  cannot become a large write.

  Extraction happens entirely in memory. Nothing here writes to disk, which
  removes path traversal as a class of problem rather than trying to sanitise
  around it. The caller writes the returned content wherever it wants.

  This module is a port of Mydia.Subtitles.Archive and is kept in sync with it.
  """

  require Logger

  # 20 MB expanded. A feature-length subtitle is tens of kilobytes, so this is
  # three orders of magnitude of headroom and still refuses a bomb.
  @max_total_bytes 20_000_000

  @subtitle_extensions ~w(.srt .ass .ssa .vtt .sub)

  @zip_magic <<0x50, 0x4B, 0x03, 0x04>>

  @doc """
  Returns true when the binary starts with the ZIP local file header magic.
  """
  @spec zip?(binary()) :: boolean()
  def zip?(<<@zip_magic, _rest::binary>>), do: true
  def zip?(_binary), do: false

  @doc """
  Extracts the first subtitle entry from a ZIP archive held in memory.

  Returns the entry name and its content. Errors rather than guessing when the
  archive holds no subtitle, names an unsafe path, or expands past the cap.
  """
  @spec extract_subtitle(binary()) ::
          {:ok, %{name: String.t(), content: binary()}} | {:error, term()}
  def extract_subtitle(binary) do
    with {:ok, listing} <- list_entries(binary),
         :ok <- check_entry_names(listing),
         :ok <- check_declared_size(listing),
         {:ok, entries} <- unzip(binary),
         :ok <- check_total_size(entries),
         {:ok, entry} <- find_subtitle(entries) do
      {name, content} = entry
      {:ok, %{name: to_string(name), content: content}}
    end
  end

  ## Private

  defp unzip(binary) do
    case :zip.unzip(binary, [:memory]) do
      {:ok, entries} -> {:ok, entries}
      {:error, _reason} -> {:error, :invalid_archive}
    end
  rescue
    _ -> {:error, :invalid_archive}
  catch
    _, _ -> {:error, :invalid_archive}
  end

  # Names are read from the central directory before OTP unzip sanitises them.
  # :zip.unzip/2 rewrites absolute and parent-relative paths, so checking the
  # expanded entry list would never see a traversal attempt.
  defp check_entry_names(listing) do
    unsafe? =
      Enum.any?(listing, fn {name, _size} ->
        String.starts_with?(name, "/") or
          Path.type(name) == :absolute or
          ".." in Path.split(name)
      end)

    if unsafe?, do: {:error, :unsafe_archive_entry}, else: :ok
  end

  # Rejects a bomb before expanding it. `check_total_size/1` measures what came
  # out, which is too late to protect memory: by then the archive has already
  # been fully expanded. The declared sizes in the central directory can lie, so
  # both checks stay, this one to bound the allocation and the other to catch a
  # header that understated itself.
  defp check_declared_size(listing) do
    declared = Enum.reduce(listing, 0, fn {_name, size}, acc -> acc + size end)

    if declared >= @max_total_bytes do
      Logger.warning("Rejected subtitle archive on declared size", bytes: declared)
      {:error, :archive_too_large}
    else
      :ok
    end
  end

  defp list_entries(binary) do
    case :zip.zip_open(binary, [:memory]) do
      {:ok, handle} ->
        try do
          case :zip.zip_list_dir(handle) do
            {:ok, entries} ->
              listing =
                for {:zip_file, name, info, _comment, _offset, _comp_size} <- entries do
                  {to_string(name), uncompressed_size(info)}
                end

              {:ok, listing}

            {:error, _reason} ->
              {:error, :invalid_archive}
          end
        after
          :zip.zip_close(handle)
        end

      {:error, _reason} ->
        {:error, :invalid_archive}
    end
  rescue
    _ -> {:error, :invalid_archive}
  catch
    _, _ -> {:error, :invalid_archive}
  end

  # `info` is an Erlang :file_info record, whose second element is the
  # uncompressed size. Anything unexpected counts as zero and falls through to
  # the post-extraction check rather than failing the whole archive.
  defp uncompressed_size(info) when is_tuple(info) and tuple_size(info) > 1 do
    case elem(info, 1) do
      size when is_integer(size) and size >= 0 -> size
      _ -> 0
    end
  end

  defp uncompressed_size(_info), do: 0

  defp check_total_size(entries) do
    total = Enum.reduce(entries, 0, fn {_name, content}, acc -> acc + byte_size(content) end)

    # Cap is inclusive: exactly @max_total_bytes is already at the limit the
    # size-cap test builds. The plan's `>` would accept a 20 MB payload.
    if total >= @max_total_bytes do
      Logger.warning("Rejected oversized subtitle archive", bytes: total)
      {:error, :archive_too_large}
    else
      :ok
    end
  end

  defp find_subtitle(entries) do
    case Enum.find(entries, &subtitle_entry?/1) do
      nil -> {:error, :no_subtitle_in_archive}
      entry -> {:ok, entry}
    end
  end

  defp subtitle_entry?({name, _content}) do
    name
    |> to_string()
    |> Path.extname()
    |> String.downcase()
    |> Kernel.in(@subtitle_extensions)
  end
end
