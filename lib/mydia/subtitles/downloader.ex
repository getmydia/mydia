defmodule Mydia.Subtitles.Downloader do
  @moduledoc """
  Downloads and stores subtitle files.

  Handles the complete subtitle download workflow:
  1. Fetches subtitle content from the configured provider adapter
  2. Detects the real subtitle format from the content
  3. Writes content to a temporary file
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
  alias Mydia.Subtitles.ResyncEnqueue
  alias Mydia.Subtitles.Sidecars
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

      ResyncEnqueue.enqueue(media_file_id, subtitle.id)

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

  # The provider already handed us bytes, and the format has already been
  # detected from them, so this only needs somewhere to put them so the
  # storage step that follows has bytes on disk to move.
  defp write_temp(content) do
    path = Path.join(@temp_dir, "subtitle_#{:erlang.unique_integer([:positive])}.tmp")

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, content) do
      {:ok, path}
    else
      {:error, reason} -> {:error, {:temp_write_failed, reason}}
    end
  end

  # Move subtitle file to permanent location with proper naming.
  #
  # This used to be a bare File.rename/2 with no existence check: File.rename/2
  # silently overwrites an existing destination and returns :ok. That was
  # harmless while this was the only writer using this naming convention, but
  # Mydia.Subtitles.Uploader (user uploads) and Mydia.Subtitles.Sidecars
  # (files adopted from disk during a scan) now write the exact same paths.
  # Downloading a language that already has an upload- or sidecar-origin row
  # would otherwise clobber its bytes on disk while leaving both database
  # rows in place, one of them now describing content it does not match, and
  # deleting either row would destroy a file the other still references.
  #
  # Refuses rather than overwrites (mirroring Uploader.destination/3), and
  # refuses rather than writing against the losing sibling of an
  # identical-basename pair like Movie.mkv beside Movie.mp4 (mirroring
  # Uploader.check_ownership/2, via the same Sidecars.owning_media_file_for/2
  # this fix now calls here too).
  defp store_subtitle_file(temp_path, media_file, subtitle_info, format) do
    with {:ok, absolute_path} <- resolve_absolute_path(media_file),
         :ok <- validate_language(subtitle_info.language),
         {:ok, final_path} <- destination(absolute_path, subtitle_info.language, format),
         :ok <- check_ownership(media_file, final_path) do
      move_to_final_path(temp_path, absolute_path, final_path)
    else
      {:error, reason} ->
        File.rm(temp_path)
        {:error, reason}
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

  defp resolve_absolute_path(media_file) do
    case MediaFile.absolute_path(media_file) do
      nil -> {:error, :media_file_path_not_resolved}
      absolute_path -> {:ok, absolute_path}
    end
  end

  # `language` comes from a provider's search result, external data the same
  # way an upload's language field is. A traversal through it is not
  # currently exploitable (File.mkdir_p!/1 below targets the media file's own
  # known-good directory, never the computed path's dirname, so a traversal
  # has no phantom directory to resolve through and the write fails outright),
  # but this allowlist is the same containment Uploader applies at its own
  # boundary, kept independent on purpose.
  #
  # Deliberately NOT shared with Uploader.validate_language/1 as a common
  # function: the two modules return this failure in incompatible shapes.
  # Uploader hands a String.t() straight to a LiveView flash; this module
  # returns an atom matched by MydiaWeb.MediaLive.Show.SubtitleEvents.
  # download_error_message/1 and by the GraphQL resolver's catch-all. Forcing
  # one shape to serve both callers would cost more than the ~10 duplicated
  # lines it would save. This mirrors an existing precedent in this codebase:
  # see @filename_pattern's own comment in
  # lib/mydia/streaming/session_subtitles.ex for the same trailing-newline
  # trap, duplicated there for the same reason.
  #
  # `\A`/`\z` rather than `^`/`$`: in PCRE (what Elixir's Regex uses) a bare
  # `$` also matches just before a single trailing newline, so "en\n" would
  # otherwise pass and land in a filename with an embedded newline.
  @language_pattern ~r/\A[a-z]{2,3}(-[A-Z]{2})?\z/

  defp validate_language(language) when is_binary(language) do
    if Regex.match?(@language_pattern, language) do
      :ok
    else
      {:error, :invalid_language}
    end
  end

  defp validate_language(_language), do: {:error, :invalid_language}

  # An existing path is refused rather than overwritten: predictable beats
  # clever when the result is a file write into someone's library. See
  # move_to_final_path/3 for how the write itself stays exclusive so two
  # downloads racing for the same new path cannot both win this check and
  # then still clobber one another.
  defp destination(absolute_path, language, format) do
    base_filename = Path.basename(absolute_path, Path.extname(absolute_path))
    media_dir = Path.dirname(absolute_path)
    final_path = Path.join(media_dir, "#{base_filename}.#{language}.#{format}")

    if File.exists?(final_path) do
      {:error, :subtitle_already_exists}
    else
      {:ok, final_path}
    end
  end

  # A sidecar whose basename is shared by two media files in the same
  # directory (Movie.mkv beside Movie.mp4) belongs to whichever one
  # Mydia.Subtitles.Sidecars.reconcile/1 would adopt it for, never to both.
  # Downloading against the losing sibling would write a path a later
  # reconcile pass attributes to the other file: the same two-rows-one-file
  # shape this whole fix exists to close.
  defp check_ownership(media_file, final_path) do
    filename = Path.basename(final_path)

    case Sidecars.owning_media_file_for(media_file, filename) do
      nil ->
        :ok

      owner ->
        if owner.id == media_file.id do
          :ok
        else
          {:error, {:owned_by_other_media_file, owner.id}}
        end
    end
  end

  # Reads the temp file's bytes back and writes them to final_path with
  # :exclusive rather than renaming temp_path onto it. Two reasons:
  #
  #   * File.rename/2 has no exclusive form, so destination/3's existence
  #     check would leave the same TOCTOU race Uploader closed in
  #     Uploader.write/3: two downloads racing for the same new path could
  #     both pass that check and then one rename would silently clobber the
  #     other's just-placed bytes. File.write/3's :exclusive flag closes it
  #     the same way it does there: the loser gets :eexist here instead.
  #   * It also removes the need for the old exdev cross-device fallback:
  #     @temp_dir (the OS temp directory) is commonly a different filesystem
  #     than a library path on a self-hosted NAS setup, and File.write/3
  #     writes directly to final_path's own filesystem regardless, where
  #     File.rename/2 could not cross that boundary at all.
  #
  # mkdir_p targets media_dir, derived from absolute_path (a database-backed
  # value), never from final_path itself, for the same reason
  # Uploader.write/3 keeps that same separation: language is already
  # known-good by the time this runs, but this stays safe even for some
  # future caller of destination/3 that skipped that check.
  defp move_to_final_path(temp_path, absolute_path, final_path) do
    media_dir = Path.dirname(absolute_path)
    File.mkdir_p!(media_dir)

    with {:ok, content} <- File.read(temp_path),
         :ok <- File.write(final_path, content, [:exclusive]) do
      File.rm(temp_path)
      {:ok, final_path}
    else
      {:error, reason} ->
        File.rm(temp_path)
        {:error, {:file_store_failed, reason}}
    end
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
