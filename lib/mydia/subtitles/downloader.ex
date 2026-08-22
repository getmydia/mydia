defmodule Mydia.Subtitles.Downloader do
  @moduledoc """
  Downloads and stores subtitle files.

  Handles the complete subtitle download workflow:
  1. Fetches subtitle content from the configured provider adapter
  2. Writes content to a temporary file
  3. Detects the real subtitle format from the content
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
  alias Mydia.Subtitles.Format
  alias Mydia.Subtitles.Subtitle
  alias Mydia.Library.MediaFile

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
    - `:provider_type` - Provider type atom (default: `:relay`)
    - `:provider_config` - Provider config map; when omitted, a registry default
      is used for the given type

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
    provider_type = Keyword.get(opts, :provider_type, :relay)
    provider_config = Keyword.get(opts, :provider_config) || default_config(provider_type)
    # No timeout is read here any more. Each adapter owns its own receive_timeout,
    # because only the adapter knows how many requests its download takes.

    with {:ok, media_file} <- fetch_media_file(media_file_id),
         :ok <- validate_subtitle_info(subtitle_info),
         {:ok, _existing} <- check_duplicate(media_file_id, subtitle_info.subtitle_hash),
         {:ok, content} <- fetch_subtitle_content(subtitle_info, provider_config),
         {:ok, format} <- Format.detect(content),
         {:ok, temp_path} <- write_temp(content),
         {:ok, final_path} <- store_subtitle_file(temp_path, media_file, subtitle_info, format),
         {:ok, subtitle} <-
           persist_subtitle(
             media_file,
             subtitle_info,
             final_path,
             format,
             to_string(provider_type)
           ) do
      Logger.info("Subtitle downloaded successfully",
        media_file_id: media_file_id,
        language: subtitle_info.language,
        provider: provider_type,
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

  # A candidate may name a provider whose config row was edited or deleted inside
  # the token's 15 minute window. Falling back to a registry-shaped config keeps
  # a still-valid token working instead of failing on a technicality.
  defp default_config(provider_type) do
    Mydia.Subtitles.ProviderRegistry.default_configs()
    |> Enum.find(%{type: provider_type, connection_settings: %{}}, &(&1.type == provider_type))
  end

  # No archive handling here. A provider that ships zips unwraps its own before
  # returning, so the downloader stays ignorant of any provider's wire format.

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

  # Fetch the subtitle body through the provider that produced this candidate.
  defp fetch_subtitle_content(subtitle_info, provider_config) do
    adapter = Mydia.Subtitles.ProviderRegistry.adapter_for(provider_config)

    case adapter.download(provider_config, subtitle_info) do
      {:ok, content} when is_binary(content) ->
        {:ok, content}

      {:ok, other} ->
        Logger.error("Invalid download response", response: inspect(other))
        {:error, :invalid_download_response}

      {:error, reason} ->
        {:error, {:download_failed, reason}}
    end
  end

  # The provider already handed us bytes, so this only needs somewhere to put
  # them for the format validation and storage steps that follow.
  defp write_temp(content) do
    path = Path.join(@temp_dir, "subtitle_#{:erlang.unique_integer([:positive])}.tmp")

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, content) do
      {:ok, path}
    else
      {:error, reason} -> {:error, {:temp_write_failed, reason}}
    end
  end

  # Move subtitle file to permanent location with proper naming
  defp store_subtitle_file(temp_path, media_file, subtitle_info, format) do
    absolute_path = MediaFile.absolute_path(media_file)

    if is_nil(absolute_path) do
      File.rm(temp_path)
      {:error, :media_file_path_not_resolved}
    else
      # Extract base filename without extension
      base_filename = Path.basename(absolute_path, Path.extname(absolute_path))
      media_dir = Path.dirname(absolute_path)

      # Build subtitle filename: {base}.{language}.{format}
      subtitle_filename = "#{base_filename}.#{subtitle_info.language}.#{format}"
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
  defp persist_subtitle(media_file, subtitle_info, file_path, format, provider) do
    attrs = %{
      media_file_id: media_file.id,
      language: subtitle_info.language,
      provider: provider,
      subtitle_hash: subtitle_info.subtitle_hash,
      file_path: file_path,
      format: format,
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
