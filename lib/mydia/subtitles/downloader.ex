defmodule Mydia.Subtitles.Downloader do
  @moduledoc """
  Downloads and stores subtitle files.

  Handles the complete subtitle download workflow:
  1. Resolves the requested provider (or the zero-config relay default) and
     downloads the subtitle's content through it via `Mydia.Subtitles.ProviderChain`
  2. Validates subtitle format
  3. Stores file with proper naming convention
  4. Persists metadata to database

  Routing download through the resolved provider (rather than always the
  relay) matters because download, not search, is what consumes an
  OpenSubtitles account's quota: a user's own provider is only worth adding
  if downloads actually use it instead of continuing to draw on the shared
  relay account.

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
  alias Mydia.Subtitles.{ProviderChain, Providers}
  alias Mydia.Library.MediaFile

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
    - `:provider_id` - The id of the provider to download through. This is
      either a `Mydia.Subtitles.SubtitleProvider` UUID (a user's own
      provider, looked up via `Mydia.Subtitles.Providers.get_provider/1`) or
      `Mydia.Subtitles.ProviderChain.default_provider/0`'s synthetic
      `"relay-default"` id. Omitted (or `nil`), it resolves to that same
      zero-config relay default, which is the common path. A `provider_id`
      that names neither -- a deleted provider, a typo, anything unresolved
      -- fails the download outright rather than silently falling back to
      the relay, which would recreate the bug this exists to fix.

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
    with {:ok, media_file} <- fetch_media_file(media_file_id),
         :ok <- validate_subtitle_info(subtitle_info),
         {:ok, _existing} <- check_duplicate(media_file_id, subtitle_info.subtitle_hash),
         {:ok, provider} <- resolve_provider(opts),
         {:ok, content} <- fetch_subtitle_content(provider, subtitle_info),
         :ok <- validate_format(content, subtitle_info.format),
         {:ok, final_path} <- store_subtitle_file(content, media_file, subtitle_info),
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

  # Check if subtitle already exists in database. Scoped to the media file on
  # purpose: two rips of the same movie (a 1080p and a 4K, say) can
  # legitimately share a subtitle_hash when a provider matches them to the
  # same underlying subtitle file, and a global lookup would hand back the
  # other file's row -- producing a track the delivery layer rightly refuses
  # to serve as :unauthorized.
  defp check_duplicate(media_file_id, subtitle_hash) do
    case Repo.get_by(Subtitle, media_file_id: media_file_id, subtitle_hash: subtitle_hash) do
      nil -> {:ok, nil}
      subtitle -> {:duplicate, subtitle}
    end
  end

  # Resolves opts[:provider_id] to a provider map/struct. Omitted or nil
  # resolves to ProviderChain.default_provider/0 (the zero-config relay,
  # keyed by the synthetic, non-UUID "relay-default" id) -- the common path,
  # since most installs never configure a provider of their own. Anything
  # else must resolve to a real Mydia.Subtitles.SubtitleProvider row via
  # Providers.get_provider/1; a deleted provider, or an id that is not even a
  # valid identifier, fails the download outright rather than silently
  # falling back to the relay (which would recreate the bug: a user's own
  # account never getting used for the part that spends quota).
  defp resolve_provider(opts) do
    default = ProviderChain.default_provider()

    case Keyword.get(opts, :provider_id) do
      nil -> {:ok, default}
      id when id == default.id -> {:ok, default}
      id -> lookup_provider(id)
    end
  end

  defp lookup_provider(id) do
    case Providers.get_provider(id) do
      nil -> {:error, {:unknown_provider, id}}
      provider -> {:ok, provider}
    end
  rescue
    # get_provider/1 casts `id` against the :binary_id primary key; a
    # provider_id that is not even a well-formed UUID (never a real DB row
    # to begin with) raises rather than returning nil. Treat it the same as
    # "not found" instead of letting the exception escape as a 500.
    Ecto.Query.CastError -> {:error, {:unknown_provider, id}}
  end

  # Downloads the subtitle's content through the resolved provider's
  # adapter. The Provider behaviour's download/2 callback returns the file's
  # raw content directly (verified against two prior reviews), so this is a
  # single call -- no separate "fetch a URL, then fetch the URL" hop and no
  # temp file to manage on this side.
  defp fetch_subtitle_content(provider, subtitle_info) do
    case ProviderChain.adapter_for(provider).download(provider, subtitle_info) do
      {:ok, content} when is_binary(content) -> {:ok, content}
      {:ok, other} -> {:error, {:invalid_download_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Validate subtitle content matches the expected format
  defp validate_format(content, expected_format) do
    if valid_subtitle_content?(content, expected_format) do
      :ok
    else
      {:error, {:format_validation_failed, expected_format}}
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

  # Write subtitle content to its permanent location with proper naming.
  # Writes the content directly to its final destination -- with the
  # provider handing back content rather than a URL, there is no temp file
  # to rename/copy into place across devices, so this is just one write.
  defp store_subtitle_file(content, media_file, subtitle_info) do
    absolute_path = MediaFile.absolute_path(media_file)

    if is_nil(absolute_path) do
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

      case File.write(final_path, content) do
        :ok -> {:ok, final_path}
        {:error, reason} -> {:error, {:file_store_failed, reason}}
      end
    end
  rescue
    error ->
      Logger.error("Subtitle storage exception",
        error: Exception.message(error),
        stacktrace: __STACKTRACE__
      )

      {:error, {:exception, error}}
  end

  # Persist subtitle metadata to database. `provider` is the resolved
  # provider map/struct (ProviderChain.default_provider/0's synthetic relay
  # map, or a real Mydia.Subtitles.SubtitleProvider row); its id is what gets
  # recorded, rather than a bare type string like "opensubtitles", so a user
  # with several accounts of the same type can tell which one served a given
  # file (useful groundwork for attributing quota usage later, even though
  # actually refreshing quota after a download stays out of scope here).
  defp persist_subtitle(media_file, subtitle_info, file_path, provider) do
    attrs = %{
      media_file_id: media_file.id,
      language: subtitle_info.language,
      provider: provider.id,
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
