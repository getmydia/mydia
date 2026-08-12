defmodule Mydia.Subtitles.Archive do
  @moduledoc """
  Extracts a single subtitle from an archive downloaded from a provider.

  SubDL and several other providers ship subtitles inside ZIP files. The archive
  arrives from a third party, so nothing in it is trusted: entry names are
  checked before use, and the total expanded size is capped so a small download
  cannot become a large write.

  Extraction happens entirely in memory. Nothing here writes to disk, which
  removes path traversal as a class of problem rather than trying to sanitise
  around it. The caller writes the returned content wherever it wants.
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
    with :ok <- check_entry_names(binary),
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
  defp check_entry_names(binary) do
    case list_raw_names(binary) do
      {:ok, names} ->
        unsafe? =
          Enum.any?(names, fn name ->
            String.starts_with?(name, "/") or
              Path.type(name) == :absolute or
              ".." in Path.split(name)
          end)

        if unsafe?, do: {:error, :unsafe_archive_entry}, else: :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_raw_names(binary) do
    case :zip.zip_open(binary, [:memory]) do
      {:ok, handle} ->
        try do
          case :zip.zip_list_dir(handle) do
            {:ok, entries} ->
              names =
                for {:zip_file, name, _info, _comment, _offset, _comp_size} <- entries do
                  to_string(name)
                end

              {:ok, names}

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
