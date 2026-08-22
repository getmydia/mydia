defmodule Mydia.Subtitles do
  @moduledoc """
  Context module for subtitle operations.

  Provides public API for searching, downloading, and managing subtitles.
  Routes requests to appropriate providers (relay or direct) based on configuration.

  ## Usage

      # Search for subtitles
      {:ok, %{results: results, providers: providers}} =
        Subtitles.search_candidates(media_file_id, "en,es")

      # Download a specific subtitle
      {:ok, subtitle} = Subtitles.download_subtitle(subtitle_info, media_file_id)

      # List downloaded subtitles
      subtitles = Subtitles.list_subtitles(media_file_id)

      # Delete a subtitle
      :ok = Subtitles.delete_subtitle(subtitle_id)
  """

  require Logger
  import Ecto.Query

  alias Mydia.Repo
  alias Mydia.Subtitles.{Subtitle, MediaHash, Downloader}
  alias Mydia.Library.MediaFile
  alias Mydia.Media.{MediaItem, Episode}

  # The 50-point metadata bonus needs an imdb, tmdb or tvdb id in the search
  # params; a title-only search starts every result at 0. What each provider
  # can add on top of that:
  #
  #   * Relay and direct SubDL add nothing at all. SubDL reports no rating and
  #     no download count, so both bonuses are skipped, and it has no hash
  #     search, so the 100-point hash bonus never fires. Auto-download is off
  #     for them at any threshold above 50, which is the honest outcome:
  #     nothing in a SubDL result separates a good match from a bad one.
  #   * Gestdown reports a download count but no rating, so it adds
  #     log10(count) * 10.
  #   * OpenSubtitles reports both, and is the only provider that can also
  #     claim a hash match.
  #
  # At 150 only a hash match could ever qualify, making auto-download an
  # OpenSubtitles-with-hash feature. At 100 the popularity term is what carries
  # a result over: metadata plus a perfect rating is 70, so clearing the bar
  # takes roughly 1000 downloads alongside that rating, or about 100k on their
  # own.
  @high_confidence_threshold 100
  @scoring_weights %{
    hash_match: 100,
    metadata_match: 50,
    rating: 20,
    popularity: 10
  }

  @doc """
  Searches for subtitles for a media file.

  ## Parameters

  - `media_file_id` - Binary ID of the media file
  - `opts` - Keyword list of options:
    - `:languages` - Comma-separated language codes (e.g., "en,es,fr")
    - `:auto_download` - Boolean to auto-download high-confidence match (default: false)

  ## Returns

  - `{:ok, results}` - List of subtitle search results with scores
  - `{:ok, {:downloaded, subtitle}}` - When auto_download is true and high-confidence match found
  - `{:error, reason}` - Error tuple

  ## Examples

      iex> search_subtitles("media-file-id", languages: "en")
      {:ok, [%{file_id: 12345, language: "en", score: 180, ...}]}

      iex> search_subtitles("media-file-id", languages: "en", auto_download: true)
      {:ok, {:downloaded, %Subtitle{}}}
  """
  @spec search_subtitles(binary(), keyword()) ::
          {:ok, list(map()) | {:downloaded, Subtitle.t()}} | {:error, term()}
  def search_subtitles(media_file_id, opts \\ []) do
    languages = Keyword.get(opts, :languages, "en")
    auto_download = Keyword.get(opts, :auto_download, false)

    with {:ok, media_file} <- fetch_media_file_with_associations(media_file_id),
         {:ok, search_params} <- build_search_params(media_file, languages),
         {:ok, raw_results, providers} <- perform_search(search_params),
         :ok <- ensure_a_provider_answered(raw_results, providers),
         scored_results <- score_results(raw_results, search_params) do
      handle_search_results(scored_results, media_file_id, auto_download)
    end
  end

  # A search where every provider failed is not the same as a search that found
  # nothing, and the difference used to be visible: before the provider chain,
  # a failure returned {:error, {:search_failed, reason}} and the LiveView
  # flashed it. Returning {:ok, []} instead renders an empty results table,
  # telling the user no subtitles exist for their file when the truth is that
  # nothing was reachable, or that a quota ran out and they could fix it by
  # configuring their own provider.
  #
  # A partial failure stays a success on purpose: results that did arrive are
  # worth more than the failure notice, and the per-provider statuses remain
  # available through `search_candidates/2` for a surface that wants both.
  defp ensure_a_provider_answered([], [_ | _] = providers) do
    if Enum.all?(providers, & &1.error) do
      {:error, {:all_providers_failed, Enum.map(providers, &{&1.name, &1.error})}}
    else
      :ok
    end
  end

  defp ensure_a_provider_answered(_results, _providers), do: :ok

  @doc """
  Searches providers for a media file and returns scored candidates plus
  per-provider status.

  This is what the subtitle search modal and the player's results header
  call. Unlike `search_subtitles/2` it never downloads and always reports
  which providers answered.
  """
  @spec search_candidates(binary(), String.t()) ::
          {:ok, %{results: [map()], providers: [map()]}} | {:error, term()}
  def search_candidates(media_file_id, languages) do
    with {:ok, media_file} <- fetch_media_file_with_associations(media_file_id),
         {:ok, search_params} <- build_search_params(media_file, languages),
         {:ok, %{results: results, providers: providers}} <-
           Mydia.Subtitles.ProviderChain.search(search_params) do
      {:ok, %{results: score_results(results, search_params), providers: providers}}
    end
  end

  @doc """
  Returns the score at or above which a result is auto-downloaded.
  """
  @spec high_confidence_threshold() :: integer()
  def high_confidence_threshold, do: @high_confidence_threshold

  @doc """
  Downloads a subtitle file.

  ## Parameters

  - `subtitle_info` - Map containing subtitle metadata:
    - `:file_id` - Provider's subtitle file identifier
    - `:language` - ISO 639-1 language code
    - `:format` - Subtitle format ("srt", "ass", "vtt")
    - `:subtitle_hash` - Unique hash identifying this subtitle
    - Plus optional fields: rating, download_count, hearing_impaired
  - `media_file_id` - Binary ID of the media file
  - `opts` - Keyword list of options (passed to Downloader)

  ## Returns

  - `{:ok, subtitle}` - Downloaded and persisted Subtitle struct
  - `{:error, reason}` - Error tuple

  ## Examples

      iex> download_subtitle(%{file_id: 12345, language: "en", ...}, "media-id")
      {:ok, %Subtitle{}}
  """
  @spec download_subtitle(map(), binary(), keyword()) :: {:ok, Subtitle.t()} | {:error, term()}
  def download_subtitle(subtitle_info, media_file_id, opts \\ []) do
    Downloader.download(subtitle_info, media_file_id, opts)
  end

  @doc """
  Downloads a subtitle search result.

  Takes a result as the provider chain tagged it, or the equivalent payload a
  verified `Mydia.Subtitles.Candidate` carries, and resolves the provider from
  it before downloading.

  Both the subtitle search modal and the player's download mutation call this.
  They used to derive the provider separately, and only one of them did it
  correctly, so a Gestdown result was fetched from the relay and failed.
  """
  @spec download_from_result(map(), binary()) :: {:ok, Subtitle.t()} | {:error, term()}
  def download_from_result(result, media_file_id) do
    download_subtitle(result_to_subtitle_info(result), media_file_id, provider_opts(result))
  end

  @doc """
  Returns the format a result should be recorded as before it is downloaded.

  Providers often leave `:format` nil and put the real extension on the file
  name. This is a declared value only; the downloader detects the real format
  from the bytes it receives.
  """
  @spec normalize_format(map()) :: String.t()
  def normalize_format(%{format: format}) when is_binary(format) and format != "", do: format

  def normalize_format(%{file_name: name}) when is_binary(name) do
    case name |> Path.extname() |> String.trim_leading(".") |> String.downcase() do
      "" -> "srt"
      ext -> ext
    end
  end

  def normalize_format(_result), do: "srt"

  @doc """
  Lists all downloaded subtitles for a media file.

  ## Parameters

  - `media_file_id` - Binary ID of the media file

  ## Returns

  - List of Subtitle structs

  ## Examples

      iex> list_subtitles("media-file-id")
      [%Subtitle{language: "en", ...}, %Subtitle{language: "es", ...}]
  """
  @spec list_subtitles(binary()) :: list(Subtitle.t())
  def list_subtitles(media_file_id) do
    Subtitle
    |> where([s], s.media_file_id == ^media_file_id)
    |> order_by([s], desc: s.rating, asc: s.language)
    |> Repo.all()
  end

  @doc """
  Deletes a subtitle file and its database record.

  ## Parameters

  - `subtitle_id` - Binary ID of the subtitle

  ## Returns

  - `:ok` - Subtitle deleted successfully
  - `{:error, reason}` - Error tuple

  ## Examples

      iex> delete_subtitle("subtitle-id")
      :ok

      iex> delete_subtitle("nonexistent-id")
      {:error, :subtitle_not_found}
  """
  @spec delete_subtitle(binary()) :: :ok | {:error, term()}
  def delete_subtitle(subtitle_id) do
    case Repo.get(Subtitle, subtitle_id) do
      nil ->
        {:error, :subtitle_not_found}

      subtitle ->
        # Delete file first
        case File.rm(subtitle.file_path) do
          :ok ->
            Repo.delete(subtitle)
            :ok

          {:error, :enoent} ->
            # File already gone, just delete record
            Repo.delete(subtitle)
            :ok

          {:error, reason} ->
            Logger.warning("Failed to delete subtitle file",
              subtitle_id: subtitle_id,
              path: subtitle.file_path,
              reason: reason
            )

            {:error, {:file_deletion_failed, reason}}
        end
    end
  end

  ## Private Functions

  defp result_to_subtitle_info(result) do
    %{
      file_id: result.file_id,
      language: result.language,
      format: normalize_format(result),
      subtitle_hash: result.subtitle_hash,
      rating: Map.get(result, :rating),
      download_count: Map.get(result, :download_count),
      hearing_impaired: Map.get(result, :hearing_impaired) || false
    }
  end

  # The result carries both the config id and the provider type. Prefer the id,
  # because that config holds the credentials: a credentialed provider resolved
  # by type alone falls back to a registry default with no API key, so a user
  # with a working SubDL or OpenSubtitles account searches successfully and
  # then cannot download anything they found.
  #
  # The type is the fallback for a config edited or deleted inside the token's
  # 15 minute window, which is the case it was added for.
  defp provider_opts(result) do
    case Map.get(result, :provider_id) do
      nil ->
        [provider_type: result.provider_type]

      provider_id ->
        case fetch_provider_config(provider_id) do
          nil -> [provider_type: result.provider_type]
          config -> [provider_type: config.type, provider_config: config]
        end
    end
  end

  defp fetch_provider_config(provider_id) do
    [enabled: true]
    |> Mydia.Settings.ServiceConfigs.list_subtitle_provider_configs()
    |> Enum.find(&(&1.id == provider_id))
  end

  # Fetch media file with all necessary associations for subtitle search
  defp fetch_media_file_with_associations(media_file_id) do
    query =
      from mf in MediaFile,
        where: mf.id == ^media_file_id,
        left_join: mi in MediaItem,
        on: mf.media_item_id == mi.id,
        left_join: ep in Episode,
        on: mf.episode_id == ep.id,
        left_join: series in MediaItem,
        on: ep.media_item_id == series.id,
        left_join: mh in MediaHash,
        on: mf.id == mh.media_file_id,
        preload: [
          media_item: mi,
          episode: {ep, media_item: series},
          library_path: []
        ],
        select: %{
          media_file: mf,
          media_hash: mh
        }

    case Repo.one(query) do
      nil ->
        {:error, :media_file_not_found}

      %{media_file: media_file, media_hash: media_hash} ->
        {:ok, Map.put(media_file, :media_hash, media_hash)}
    end
  end

  # Build search parameters based on available media information
  defp build_search_params(media_file, languages) do
    params = %{languages: languages}

    # Add hash if available
    params =
      if media_file.media_hash do
        Map.merge(params, %{
          file_hash: media_file.media_hash.opensubtitles_hash,
          file_size: media_file.media_hash.file_size
        })
      else
        params
      end

    # Add metadata IDs from media_item or episode
    params =
      cond do
        media_file.media_item ->
          add_media_item_params(params, media_file.media_item)

        media_file.episode && media_file.episode.media_item ->
          params
          |> add_media_item_params(media_file.episode.media_item)
          |> add_episode_params(media_file.episode)

        true ->
          params
      end

    # Ensure we have at least one search criterion
    if map_size(params) > 1 do
      {:ok, params}
    else
      {:error, :insufficient_search_criteria}
    end
  end

  defp add_media_item_params(params, media_item) do
    params
    |> maybe_put(:imdb_id, media_item.imdb_id)
    |> maybe_put(:tmdb_id, media_item.tmdb_id)
    |> maybe_put(:tvdb_id, media_item.tvdb_id)
    |> Map.put(:media_type, if(media_item.type == "tv_show", do: "episode", else: "movie"))
  end

  defp add_episode_params(params, episode) do
    params
    |> Map.put(:season_number, episode.season_number)
    |> Map.put(:episode_number, episode.episode_number)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Perform subtitle search across every configured provider.
  defp perform_search(params) do
    case Mydia.Subtitles.ProviderChain.search(params) do
      {:ok, %{results: results, providers: providers}} -> {:ok, results, providers}
    end
  end

  @doc false
  # Score subtitle results based on matching criteria
  def score_results(results, search_params) do
    results
    |> Enum.map(fn result ->
      score = calculate_score(result, search_params)
      Map.put(result, :score, score)
    end)
    |> Enum.sort_by(&{&1.score, Map.get(&1, :provider_priority, 0)}, :desc)
  end

  defp calculate_score(result, search_params) do
    score = 0

    # Hash match (highest confidence)
    score =
      if Map.has_key?(search_params, :file_hash) &&
           Map.get(result, :moviehash_match) == true do
        score + @scoring_weights.hash_match
      else
        score
      end

    # Metadata match (IMDB/TMDB)
    score =
      if Map.has_key?(search_params, :imdb_id) || Map.has_key?(search_params, :tmdb_id) ||
           Map.has_key?(search_params, :tvdb_id) do
        score + @scoring_weights.metadata_match
      else
        score
      end

    # Rating bonus (0-10 scale, multiply by weight)
    score =
      case Map.get(result, :rating) do
        rating when is_number(rating) ->
          score + round(rating * @scoring_weights.rating / 10)

        _ ->
          score
      end

    # Popularity bonus (download count)
    score =
      case Map.get(result, :download_count) do
        count when is_integer(count) and count > 0 ->
          # Logarithmic scale: log10(count) * weight
          popularity_score = :math.log10(count) * @scoring_weights.popularity
          score + round(popularity_score)

        _ ->
          score
      end

    score
  end

  # Handle search results based on auto_download setting
  defp handle_search_results([], _media_file_id, _auto_download) do
    {:ok, []}
  end

  defp handle_search_results([best | _rest] = results, media_file_id, true) do
    # Check if auto-download is appropriate for high-confidence match
    if best.score >= @high_confidence_threshold do
      # Auto-download high-confidence match
      subtitle_info = %{
        file_id: best.file_id,
        language: best.language,
        # The provider states the format. Deriving it from the file name breaks
        # on providers whose name carries no extension: Gestdown's is a release
        # tag like "Bluray-CtrlHD", so Path.extname/1 returns "" and the
        # download is rejected as an unsupported format.
        format: best.format || "srt",
        subtitle_hash: best.subtitle_hash || generate_subtitle_hash(best),
        rating: best.rating,
        download_count: best.download_count,
        hearing_impaired: Map.get(best, :hearing_impaired) || false
      }

      # Route to the provider that produced this candidate. Without it the
      # download goes to the relay by default and fails for anything found by
      # Gestdown, SubDL or a direct OpenSubtitles account.
      download_opts =
        case Map.get(best, :provider_type) do
          nil -> []
          provider_type -> [provider_type: provider_type]
        end

      case download_subtitle(subtitle_info, media_file_id, download_opts) do
        {:ok, subtitle} ->
          Logger.info("Auto-downloaded high-confidence subtitle",
            media_file_id: media_file_id,
            language: subtitle.language,
            score: best.score
          )

          {:ok, {:downloaded, subtitle}}

        {:error, reason} ->
          Logger.warning("Auto-download failed, returning search results",
            reason: inspect(reason)
          )

          {:ok, results}
      end
    else
      {:ok, results}
    end
  end

  defp handle_search_results(results, _media_file_id, _auto_download) do
    {:ok, results}
  end

  # Generate a subtitle hash if not provided by the API
  defp generate_subtitle_hash(result) do
    # Use file_id and language as unique identifier
    :crypto.hash(:sha256, "#{result.file_id}-#{result.language}")
    |> Base.encode16(case: :lower)
  end
end
