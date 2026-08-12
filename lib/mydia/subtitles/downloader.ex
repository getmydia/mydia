defmodule Mydia.Subtitles.Downloader do
  @moduledoc """
  Downloads and stores subtitle files.

  Handles the complete subtitle download workflow:
  1. Fetches download URL from configured provider
  2. Downloads subtitle file content
  3. Validates subtitle format
  4. Stores file with proper naming convention
  5. Persists metadata to database

  ## Storage Convention

  Subtitles are stored alongside media files with naming:
  `{media_filename}.{language}.{format}`

  For example:
  - `/movies/Inception/Inception.en.srt`
  - `/tv/Breaking Bad/Season 01/Breaking.Bad.S01E01.es.srt`

  ## Supported Formats

  - SRT (SubRip)
  - ASS (Advanced SubStation Alpha)
  - VTT (WebVTT)
  """

  require Logger
  alias Mydia.Repo
  alias Mydia.Subtitles.Subtitle
  alias Mydia.Subtitles.Client.MetadataRelay
  alias Mydia.Library.MediaFile

  @download_timeout 30_000
  @temp_dir System.tmp_dir!()

  @doc """
  Downloads a subtitle file and stores it locally.

  ## Parameters

  - `subtitle_info` - Map containing subtitle metadata from search results:
    - `:file_id` - Provider's subtitle file identifier
    - `:language` - ISO 639-1 language code (e.g., "en", "es")
    - `:format` - Subtitle format ("srt", "ass", "vtt")
    - `:subtitle_hash` - Unique hash identifying this subtitle
    - `:rating` - Optional quality rating (0.0-10.0)
    - `:download_count` - Optional download count from provider
    - `:hearing_impaired` - Boolean indicating SDH/CC subtitles
  - `media_file_id` - Binary ID of the media file
  - `opts` - Keyword list of options:
    - `:provider` - Provider type (default: "relay")
    - `:timeout` - Download timeout in milliseconds (default: 30_000)

  ## Returns

  - `{:ok, subtitle}` - Subtitle schema struct with file path and metadata
  - `{:error, reason}` - Error tuple with descriptive reason

  ## Examples

      iex> download(%{
      ...>   file_id: 12345,
      ...>   language: "en",
      ...>   format: "srt",
      ...>   subtitle_hash: "abc123xyz",
      ...>   rating: 8.5,
      ...>   hearing_impaired: false
      ...> }, "media-file-uuid")
      {:ok, %Subtitle{language: "en", file_path: "/path/to/movie.en.srt"}}

      iex> download(%{file_id: 99999, language: "en", format: "srt"}, "invalid-id")
      {:error, :media_file_not_found}
  """
  @spec download(map(), binary(), keyword()) :: {:ok, Subtitle.t()} | {:error, term()}
  def download(subtitle_info, media_file_id, opts \\ []) do
    provider = Keyword.get(opts, :provider, "relay")
    timeout = Keyword.get(opts, :timeout, @download_timeout)

    with {:ok, media_file} <- fetch_media_file(media_file_id),
         :ok <- validate_subtitle_info(subtitle_info),
         {:ok, _existing} <- check_duplicate(media_file_id, subtitle_info.subtitle_hash),
         {:ok, download_url} <- fetch_download_url(subtitle_info.file_id, provider, timeout),
         {:ok, temp_path} <- download_file(download_url, timeout),
         :ok <- validate_format(temp_path, subtitle_info.format),
         {:ok, final_path} <- store_subtitle_file(temp_path, media_file, subtitle_info),
         {:ok, subtitle} <- persist_subtitle(media_file, subtitle_info, final_path, provider) do
      Logger.info("Subtitle downloaded successfully",
        media_file_id: media_file_id,
        language: subtitle_info.language,
        path: final_path
      )

      {:ok, subtitle}
    else
      {:duplicate, subtitle} ->
        Logger.debug("Subtitle already exists", subtitle_id: subtitle.id)
        {:ok, subtitle}

      {:error, reason} = error ->
        Logger.warning("Subtitle download failed",
          media_file_id: media_file_id,
          reason: inspect(reason)
        )

        error
    end
  end

  ## Private Functions

  # Fetch media file from database with necessary associations
  defp fetch_media_file(media_file_id) do
    case Repo.get(MediaFile, media_file_id) do
      nil ->
        {:error, :media_file_not_found}

      media_file ->
        # Preload library_path to resolve absolute path
        media_file = Repo.preload(media_file, :library_path)
        {:ok, media_file}
    end
  end

  # Validate required subtitle information
  defp validate_subtitle_info(info) do
    required_fields = [:file_id, :language, :format, :subtitle_hash]

    missing_fields =
      Enum.filter(required_fields, fn field ->
        not Map.has_key?(info, field) or is_nil(Map.get(info, field))
      end)

    case missing_fields do
      [] ->
        if info.format in Subtitle.supported_formats() do
          :ok
        else
          {:error, {:unsupported_format, info.format}}
        end

      fields ->
        {:error, {:missing_required_fields, fields}}
    end
  end

  # Scoped to the media file on purpose. Two rips of the same movie share
  # subtitle hashes, and a global lookup would hand back the other file's row,
  # producing a track the delivery layer rightly refuses as unauthorized.
  defp check_duplicate(media_file_id, subtitle_hash) do
    case Repo.get_by(Subtitle, media_file_id: media_file_id, subtitle_hash: subtitle_hash) do
      nil -> {:ok, nil}
      subtitle -> {:duplicate, subtitle}
    end
  end

  # Fetch download URL from configured provider
  defp fetch_download_url(file_id, "relay", timeout) do
    case MetadataRelay.get_download_url(file_id, timeout: timeout) do
      {:ok, %{"download_url" => url}} when is_binary(url) ->
        {:ok, url}

      {:ok, response} ->
        Logger.error("Invalid download URL response", response: inspect(response))
        {:error, :invalid_download_url_response}

      {:error, reason} ->
        {:error, {:download_url_fetch_failed, reason}}
    end
  end

  defp fetch_download_url(_file_id, provider, _timeout) do
    {:error, {:unsupported_provider, provider}}
  end

  # Download subtitle file to temporary location
  defp download_file(url, timeout) do
    temp_path = Path.join(@temp_dir, "subtitle_#{:erlang.unique_integer([:positive])}.tmp")

    Logger.debug("Downloading subtitle file", url: url, temp_path: temp_path)

    try do
      case Req.get(url, receive_timeout: timeout, into: File.stream!(temp_path)) do
        {:ok, %{status: 200}} ->
          {:ok, temp_path}

        {:ok, %{status: status}} ->
          File.rm(temp_path)
          Logger.warning("Subtitle download failed", status: status, url: url)
          {:error, {:http_error, status}}

        {:error, %{reason: :timeout}} ->
          File.rm(temp_path)
          {:error, :download_timeout}

        {:error, reason} ->
          File.rm(temp_path)
          {:error, {:download_failed, reason}}
      end
    rescue
      error ->
        File.rm(temp_path)

        Logger.error("Subtitle download exception",
          error: Exception.message(error),
          stacktrace: __STACKTRACE__
        )

        {:error, {:exception, error}}
    end
  end

  # Validate subtitle file format by checking content
  defp validate_format(file_path, expected_format) do
    case File.read(file_path) do
      {:ok, content} ->
        if valid_subtitle_content?(content, expected_format) do
          :ok
        else
          {:error, {:format_validation_failed, expected_format}}
        end

      {:error, reason} ->
        {:error, {:file_read_error, reason}}
    end
  end

  # Check if content matches expected subtitle format
  defp valid_subtitle_content?(content, "srt") do
    # SRT files start with subtitle number followed by timecode
    String.match?(content, ~r/^\d+\s*\n\d{2}:\d{2}:\d{2},\d{3}\s*-->/m)
  end

  defp valid_subtitle_content?(content, "ass") do
    # ASS files contain [Script Info] section
    String.contains?(content, "[Script Info]") or String.contains?(content, "[V4+ Styles]")
  end

  defp valid_subtitle_content?(content, "vtt") do
    # VTT files start with WEBVTT header
    String.starts_with?(content, "WEBVTT")
  end

  defp valid_subtitle_content?(_content, _format), do: false

  # Move subtitle file to permanent location with proper naming
  defp store_subtitle_file(temp_path, media_file, subtitle_info) do
    absolute_path = MediaFile.absolute_path(media_file)

    if is_nil(absolute_path) do
      File.rm(temp_path)
      {:error, :media_file_path_not_resolved}
    else
      # Extract base filename without extension
      base_filename = Path.basename(absolute_path, Path.extname(absolute_path))
      media_dir = Path.dirname(absolute_path)

      # Build subtitle filename: {base}.{language}.{format}
      subtitle_filename = "#{base_filename}.#{subtitle_info.language}.#{subtitle_info.format}"
      final_path = Path.join(media_dir, subtitle_filename)

      # Ensure directory exists
      File.mkdir_p!(media_dir)

      # Move file to final location
      case File.rename(temp_path, final_path) do
        :ok ->
          {:ok, final_path}

        {:error, :exdev} ->
          # Cross-device move, use copy + delete
          case File.cp(temp_path, final_path) do
            :ok ->
              File.rm(temp_path)
              {:ok, final_path}

            {:error, reason} ->
              File.rm(temp_path)
              {:error, {:file_store_failed, reason}}
          end

        {:error, reason} ->
          File.rm(temp_path)
          {:error, {:file_store_failed, reason}}
      end
    end
  rescue
    error ->
      File.rm(temp_path)

      Logger.error("Subtitle storage exception",
        error: Exception.message(error),
        stacktrace: __STACKTRACE__
      )

      {:error, {:exception, error}}
  end

  # Persist subtitle metadata to database
  defp persist_subtitle(media_file, subtitle_info, file_path, provider) do
    attrs = %{
      media_file_id: media_file.id,
      language: subtitle_info.language,
      provider: provider,
      subtitle_hash: subtitle_info.subtitle_hash,
      file_path: file_path,
      format: subtitle_info.format,
      rating: Map.get(subtitle_info, :rating),
      download_count: Map.get(subtitle_info, :download_count),
      hearing_impaired: Map.get(subtitle_info, :hearing_impaired, false)
    }

    %Subtitle{}
    |> Subtitle.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, subtitle} ->
        {:ok, subtitle}

      {:error, changeset} ->
        # Clean up file if database insert fails
        File.rm(file_path)

        Logger.error("Failed to persist subtitle to database",
          errors: inspect(changeset.errors)
        )

        {:error, {:database_insert_failed, changeset}}
    end
  end
end
