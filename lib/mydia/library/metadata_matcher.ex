defmodule Mydia.Library.MetadataMatcher do
  @moduledoc """
  Matches parsed file information to metadata provider entries (TMDB/TVDB).

  This module takes parsed file information from `FileParser` and searches
  metadata providers to find the best match. It uses:
  - Title and year information for matching
  - Confidence scoring to determine match quality
  - Fallback strategies when exact matches aren't found
  """

  @behaviour Mydia.Library.Matcher

  require Logger
  alias Mydia.{Media, Metadata}
  alias Mydia.Accounts.Scope
  alias Mydia.Library.ReleaseParser, as: FileParser
  alias Mydia.Library.Structs.MatchResult
  alias Mydia.Library.Text
  alias Mydia.Metadata.Structs.MediaMetadata

  @type match_result :: MatchResult.t()

  # Cost of a known-wrong year on an otherwise plausible title. Sized against
  # `Mydia.ImportGroups`' 0.85 auto-accept threshold: an exact title match
  # cannot score below 0.9, so anything at or under 0.10 leaves a contradicted
  # year auto-accepting silently. Sized from above too -- `select_best_tv_match/2`
  # discards anything under 0.5, and a suggestion a reviewer can see and correct
  # beats falling through to the series-level guess, so a contradicted exact
  # title still lands around 0.65-0.7: queued for review, not thrown away. Only
  # a weak title *and* a wrong year fall through entirely, which is the one
  # combination carrying no evidence worth showing anyone.
  @year_contradiction_penalty 0.25

  @doc """
  Normalizes a search query by removing metadata artifacts from filenames.

  This removes:
  - Year suffixes and everything after (e.g., ".1989-...", "(1989)", etc.)
  - Release group tags, quality indicators, codec info
  - IMDB/TVDB ID annotations like {imdb-...} or [tvdbid-...]
  - File separators (., -, _, +) replaced with spaces
  - Multiple whitespace collapsed to single space

  ## Examples

      iex> normalize_search_query("The.Simpsons.1989-(71663)")
      "The Simpsons"

      iex> normalize_search_query("The+Simpsons+(1989)+{imdb-tt0096697}")
      "The Simpsons"

      iex> normalize_search_query("Movie.Name.2020.1080p.BluRay.x264-RARBG")
      "Movie Name"
  """
  @spec normalize_search_query(String.t()) :: String.t()
  def normalize_search_query(query) when is_binary(query) do
    query
    # Remove IMDB/TVDB/TMDB ID annotations like {imdb-tt0096697} or [tvdbid-12345]
    |> String.replace(~r/\{imdb-[^\}]+\}/i, "")
    |> String.replace(~r/\[tvdbid-[^\]]+\]/i, "")
    |> String.replace(~r/\{tmdb-[^\}]+\}/i, "")
    |> String.replace(~r/\[tmdbid-[^\]]+\]/i, "")
    # Remove year in parentheses and everything after: (1989)...
    |> String.replace(~r/\(\d{4}\).*$/, "")
    # Remove year with separators and everything after: .1989-... or -1989. or _1989_
    |> String.replace(~r/[._-]\d{4}[._-].*$/, "")
    # Remove standalone year at end with separator: .1989 or -1989 or _1989
    |> String.replace(~r/[._-]\d{4}$/, "")
    # Remove common quality indicators and everything after
    |> String.replace(~r/[._-](480p|720p|1080p|2160p|4k).*$/i, "")
    |> String.replace(~r/[._-](bluray|brrip|webrip|web-dl|webdl|hdtv|dvdrip).*$/i, "")
    # Remove codec info and everything after
    |> String.replace(~r/[._-](x264|x265|h264|h265|hevc|xvid|divx|avc).*$/i, "")
    # Remove release group tags (usually at the end like -RARBG, -YTS, etc.)
    |> String.replace(~r/-[A-Z0-9]+$/, "")
    # Replace separators with spaces
    |> String.replace(~r/[._+\-]+/, " ")
    # Collapse multiple spaces
    |> String.replace(~r/\s+/, " ")
    # Trim whitespace
    |> String.trim()
  end

  def normalize_search_query(query), do: query

  @doc """
  Matches a file path to metadata provider entries.

  Returns the best match with confidence score, or nil if no match found.

  ## Examples

      iex> MetadataMatcher.match_file("/media/movies/Inception.2010.1080p.mkv")
      {:ok, %{
        provider_id: "27205",
        provider_type: :tmdb,
        title: "Inception",
        year: 2010,
        match_confidence: 0.95,
        metadata: %{...}
      }}
  """
  @spec match_file(String.t(), keyword()) :: {:ok, match_result()} | {:error, term()}
  def match_file(file_path, opts \\ []) do
    config = Keyword.get(opts, :config, Metadata.default_relay_config())

    # Parse the file using full path to leverage folder structure for TV shows
    # This prioritizes folder names like "/media/tv/Bluey/Season 03/" over filename parsing
    parsed = FileParser.parse_with_path(file_path)

    case parsed.type do
      :movie ->
        match_movie(parsed, config, opts)

      :tv_show ->
        match_tv_show(parsed, config, opts)

      :unknown ->
        Logger.warning("Could not determine media type from file",
          path: file_path,
          confidence: parsed.confidence
        )

        {:error, :unknown_media_type}
    end
  end

  @doc """
  Matches parsed movie information to TMDB.

  Returns the best match or error if no suitable match found.

  When parsed info contains an external_id (e.g., from folder name like [tmdb-664]),
  it will perform a direct lookup instead of searching by title.
  """
  @spec match_movie(map(), map(), keyword()) :: {:ok, match_result()} | {:error, term()}
  def match_movie(%{type: :movie} = parsed, config, opts \\ []) do
    # First, check if we have an external provider ID for direct lookup
    case lookup_by_external_id(parsed, config, opts) do
      {:ok, _match_result} = success ->
        success

      {:error, :no_external_id} ->
        # No external ID, proceed with normal matching
        match_movie_by_title(parsed, config, opts)

      {:error, reason} ->
        # External ID lookup failed, fall back to title-based matching
        Logger.warning("External ID lookup failed, falling back to title search",
          external_id: parsed.external_id,
          external_provider: parsed.external_provider,
          reason: reason
        )

        match_movie_by_title(parsed, config, opts)
    end
  end

  # Lookup movie directly by external provider ID (from folder name like [tmdb-664])
  defp lookup_by_external_id(parsed, config, opts) do
    # Check if we have external ID and provider
    external_id = Map.get(parsed, :external_id)
    external_provider = Map.get(parsed, :external_provider)

    case {external_id, external_provider} do
      {nil, _} ->
        {:error, :no_external_id}

      {_, nil} ->
        {:error, :no_external_id}

      {id, :tmdb} ->
        Logger.info("Performing direct TMDB lookup by ID from folder name",
          tmdb_id: id,
          title: parsed.title
        )

        fetch_opts = Keyword.merge(opts, media_type: :movie)

        case Metadata.fetch_by_id(config, id, fetch_opts) do
          {:ok, result} ->
            Logger.info("Direct TMDB lookup successful",
              tmdb_id: id,
              title: result.title,
              year: result.year
            )

            movie_metadata =
              MediaMetadata.from_api_response(
                Map.from_struct(result),
                :movie,
                id
              )

            {:ok,
             MatchResult.new(
               provider_id: id,
               provider_type: :tmdb,
               title: result.title,
               year: result.year,
               # Direct ID lookup is very high confidence
               match_confidence: 0.99,
               match_type: :direct_id_lookup,
               metadata: movie_metadata,
               parsed_info: parsed
             )}

          {:error, reason} ->
            {:error, reason}
        end

      {id, provider} ->
        # Other providers (tvdb, imdb) - not yet supported for direct lookup
        Logger.warning("Direct lookup not supported for provider",
          provider: provider,
          id: id
        )

        {:error, :unsupported_provider}
    end
  end

  # Match movie by title (original behavior)
  defp match_movie_by_title(parsed, config, opts) do
    if parsed.title do
      # First, try to match against existing media items in the local database
      case find_local_movie(parsed) do
        {:ok, match_result} ->
          Logger.info("Matched file to existing local media item",
            title: parsed.title,
            local_title: match_result.title,
            tmdb_id: match_result.provider_id
          )

          {:ok, match_result}

        {:error, :no_local_match} ->
          # No local match, search external metadata provider
          search_external_movie(parsed, config, opts)
      end
    else
      {:error, :no_title_extracted}
    end
  end

  # Search external metadata provider for movie
  defp search_external_movie(parsed, config, opts) do
    search_opts = build_movie_search_opts(parsed, opts)
    normalized_title = normalize_search_query(parsed.title)

    case Metadata.search_cached(config, normalized_title, search_opts) do
      {:ok, []} ->
        # Try without year if we got no results
        if parsed.year do
          Logger.debug("No results with year, retrying without year",
            title: parsed.title,
            year: parsed.year
          )

          retry_opts = Keyword.delete(search_opts, :year)

          case Metadata.search_cached(config, normalized_title, retry_opts) do
            {:ok, results} when results != [] ->
              select_best_movie_match(results, parsed)

            _ ->
              {:error, :no_matches_found}
          end
        else
          {:error, :no_matches_found}
        end

      {:ok, results} ->
        select_best_movie_match(results, parsed)

      {:error, reason} = error ->
        Logger.error("Metadata search failed", title: parsed.title, reason: reason)
        error
    end
  end

  @doc """
  Matches parsed TV show information to TVDB/TMDB.

  Returns the best match or error if no suitable match found.

  When parsed info contains an external_id (e.g., from folder name like [tvdb-81189]),
  it will perform a direct lookup instead of searching by title.
  """
  @spec match_tv_show(map(), map(), keyword()) :: {:ok, match_result()} | {:error, term()}
  def match_tv_show(%{type: :tv_show} = parsed, config, opts \\ []) do
    # First, check if we have an external provider ID for direct lookup
    case lookup_tv_show_by_external_id(parsed, config, opts) do
      {:ok, _match_result} = success ->
        success

      {:error, :no_external_id} ->
        # No external ID, proceed with normal matching
        match_tv_show_by_title(parsed, config, opts)

      {:error, reason} ->
        # External ID lookup failed, fall back to title-based matching
        Logger.warning("TV show external ID lookup failed, falling back to title search",
          external_id: Map.get(parsed, :external_id),
          external_provider: Map.get(parsed, :external_provider),
          reason: reason
        )

        match_tv_show_by_title(parsed, config, opts)
    end
  end

  # Lookup TV show directly by external provider ID (from folder name like [tvdb-81189])
  defp lookup_tv_show_by_external_id(parsed, config, opts) do
    # Check if we have external ID and provider
    external_id = Map.get(parsed, :external_id)
    external_provider = Map.get(parsed, :external_provider)

    case {external_id, external_provider} do
      {nil, _} ->
        {:error, :no_external_id}

      {_, nil} ->
        {:error, :no_external_id}

      {id, :tmdb} ->
        Logger.info("Performing direct TMDB lookup for TV show by ID from folder name",
          tmdb_id: id,
          title: parsed.title
        )

        fetch_opts = Keyword.merge(opts, media_type: :tv_show)

        case Metadata.fetch_by_id(config, id, fetch_opts) do
          {:ok, result} ->
            Logger.info("Direct TMDB TV show lookup successful",
              tmdb_id: id,
              title: result.title,
              year: result.year
            )

            tv_metadata =
              MediaMetadata.from_api_response(
                Map.from_struct(result),
                :tv_show,
                id
              )

            {:ok,
             MatchResult.new(
               provider_id: id,
               provider_type: :tmdb,
               title: result.title,
               year: result.year,
               # Direct ID lookup is very high confidence
               match_confidence: 0.99,
               match_type: :direct_id_lookup,
               metadata: tv_metadata,
               parsed_info: parsed
             )}

          {:error, reason} ->
            {:error, reason}
        end

      {id, :tvdb} ->
        Logger.info("Performing direct TVDB lookup for TV show by ID from folder name",
          tvdb_id: id,
          title: parsed.title
        )

        # For TVDB, we need to use the TVDB-specific fetch
        fetch_opts = Keyword.merge(opts, media_type: :tv_show, provider: :tvdb)

        case Metadata.fetch_by_id(config, id, fetch_opts) do
          {:ok, result} ->
            Logger.info("Direct TVDB TV show lookup successful",
              tvdb_id: id,
              title: result.title,
              year: result.year
            )

            tv_metadata =
              MediaMetadata.from_api_response(
                Map.from_struct(result),
                :tv_show,
                id
              )

            {:ok,
             MatchResult.new(
               provider_id: id,
               provider_type: :tvdb,
               title: result.title,
               year: result.year,
               # Direct ID lookup is very high confidence
               match_confidence: 0.99,
               match_type: :direct_id_lookup,
               metadata: tv_metadata,
               parsed_info: parsed
             )}

          {:error, reason} ->
            {:error, reason}
        end

      {id, provider} ->
        # Other providers (imdb) - not yet supported for direct lookup
        Logger.warning("Direct TV show lookup not supported for provider",
          provider: provider,
          id: id
        )

        {:error, :unsupported_provider}
    end
  end

  # Match TV show by title (original behavior)
  defp match_tv_show_by_title(parsed, config, opts) do
    if parsed.title do
      # First, try to match against existing media items in the local database
      case find_local_tv_show(parsed) do
        {:ok, match_result} ->
          Logger.info("Matched file to existing local TV show",
            title: parsed.title,
            local_title: match_result.title,
            tmdb_id: match_result.provider_id
          )

          {:ok, match_result}

        {:error, :no_local_match} ->
          # No local match, search external metadata provider
          search_external_tv_show(parsed, config, opts)
      end
    else
      {:error, :no_title_extracted}
    end
  end

  # Search external metadata provider for TV show
  defp search_external_tv_show(parsed, config, opts) do
    search_opts = build_tv_search_opts(parsed, opts)
    normalized_title = normalize_search_query(parsed.title)

    case Metadata.search_cached(config, normalized_title, search_opts) do
      {:ok, []} ->
        # Try without year if we got no results
        if parsed.year do
          Logger.debug("No TV show results with year, retrying without year",
            title: parsed.title,
            year: parsed.year
          )

          retry_opts = Keyword.delete(search_opts, :year)

          case Metadata.search_cached(config, normalized_title, retry_opts) do
            {:ok, results} when results != [] ->
              select_best_tv_match(results, parsed)

            _ ->
              # Try series-level fallback for partial match
              try_series_level_match(parsed, config, opts)
          end
        else
          # Try series-level fallback for partial match
          try_series_level_match(parsed, config, opts)
        end

      {:ok, results} ->
        case select_best_tv_match(results, parsed) do
          {:ok, _match} = success ->
            success

          {:error, :low_confidence_match} ->
            # Try series-level fallback for low confidence matches
            # This happens when we get series results but they don't match well
            Logger.debug("Low confidence match, trying series-level fallback",
              title: parsed.title
            )

            try_series_level_match(parsed, config, opts)

          error ->
            error
        end

      {:error, reason} = error ->
        Logger.error("Metadata search failed", title: parsed.title, reason: reason)
        error
    end
  end

  ## Private Functions

  # Try to match at series level when episode-specific match fails
  # This creates a "partial match" for future/unreleased episodes
  defp try_series_level_match(parsed, config, opts) do
    Logger.debug("Attempting series-level match for partial match support",
      title: parsed.title,
      season: parsed.season,
      episodes: parsed.episodes
    )

    # Search for the series (without specific episode constraints)
    search_opts =
      [media_type: :tv_show]
      |> Keyword.merge(Keyword.take(opts, [:language, :include_adult, :provider]))

    normalized_title = normalize_search_query(parsed.title)

    case Metadata.search_cached(config, normalized_title, search_opts) do
      {:ok, results} when results != [] ->
        # Find best matching series
        case find_best_series_match(results, parsed) do
          {:ok, series, score} ->
            Logger.info("Found series-level match for future/unreleased episode",
              series_title: series.title,
              parsed_season: parsed.season,
              parsed_episodes: parsed.episodes,
              score: score
            )

            # Return partial match result
            series_metadata =
              MediaMetadata.from_api_response(
                Map.from_struct(series),
                :tv_show,
                to_string(series.provider_id)
              )

            # Normalize the search result's provider to a concrete TV source.
            # TVDB results carry provider: :tvdb; TMDB results carry
            # provider: :metadata_relay, which maps to :tmdb.
            provider_type = if series.provider == :tvdb, do: :tvdb, else: :tmdb

            {:ok,
             MatchResult.new(
               provider_id: to_string(series.provider_id),
               provider_type: provider_type,
               title: series.title,
               year: series.year,
               # A series-level match is an identity claim backed by the
               # folder name, the strongest signal available once the
               # episode-specific search has failed. A flat 0.85 here would
               # promote a barely-passing `find_best_series_match/2` score
               # (0.5, the floor it accepts) to the same confidence as a
               # near-exact title match, clearing FileIngest's auto-link
               # threshold on a weak guess. Using the score itself keeps that
               # threshold meaningful: only a genuinely strong series match
               # can auto-link, while a weak one still surfaces (this whole
               # code path was dead at the old flat 0.70, which never cleared
               # the threshold at all -- the fix is scoring it, not flattening
               # it a second time).
               match_confidence: score,
               match_type: :partial_match,
               partial_reason: :episode_not_found,
               metadata: series_metadata,
               parsed_info: parsed
             )}

          {:error, _} ->
            {:error, :no_matches_found}
        end

      {:ok, []} ->
        {:error, :no_matches_found}

      {:error, reason} = error ->
        Logger.error("Series-level search failed", title: parsed.title, reason: reason)
        error
    end
  end

  # Find the best matching series from search results. Returns the score
  # alongside the match so the caller can use it as match_confidence instead
  # of a flat constant -- see the comment at the `match_confidence: score`
  # call site in `try_series_level_match/3`.
  defp find_best_series_match(results, parsed) do
    scored_results =
      Enum.map(results, fn result ->
        score = calculate_series_match_score(result, parsed)
        {result, score}
      end)

    case Enum.max_by(scored_results, fn {_result, score} -> score end, fn -> nil end) do
      {best_match, score} when score >= 0.5 ->
        {:ok, best_match, score}

      _ ->
        {:error, :low_confidence_match}
    end
  end

  # Calculate match score for series-level matching
  defp calculate_series_match_score(result, parsed) do
    base_score = 0.5
    title_sim = title_similarity(result.title, parsed.title)

    score =
      base_score
      |> add_score(title_sim, 0.2)
      |> add_score(year_match?(result.year, parsed.year), 0.1)
      |> add_score(popularity_score(result.popularity), 0.1)
      # Bonus for exact title match
      |> add_score(exact_title_match?(result.title, parsed.title), 0.15)
      # Penalty for derivative titles
      |> add_score(title_derivative_penalty(result.title, parsed.title), 1.0)

    min(score, 1.0)
  end

  # Try to find a matching movie in the local database
  defp find_local_movie(parsed) do
    # Search for movies with matching title (case-insensitive)
    media_items =
      Media.list_media_items(Scope.system())
      |> Enum.filter(fn item ->
        item.type == "movie" &&
          titles_match?(item.title, parsed.title) &&
          years_compatible?(item.year, parsed.year)
      end)

    case media_items do
      [] ->
        {:error, :no_local_match}

      [item | _] ->
        # Found a match! Return a match_result struct
        {pid, ptype} = provider_id_for_item(item, :movie)

        {:ok,
         MatchResult.new(
           provider_id: pid || to_string(item.id),
           provider_type: ptype || :tmdb,
           title: item.title,
           year: item.year,
           match_confidence: 0.95,
           metadata: convert_db_metadata(item.metadata, item, :movie),
           parsed_info: parsed,
           from_local_db: true
         )}
    end
  end

  # Try to find a matching TV show in the local database
  defp find_local_tv_show(parsed) do
    # Search for TV shows with matching title (case-insensitive)
    media_items =
      Media.list_media_items(Scope.system())
      |> Enum.filter(fn item ->
        item.type == "tv_show" &&
          titles_match?(item.title, parsed.title) &&
          years_compatible?(item.year, parsed.year)
      end)

    case media_items do
      [] ->
        {:error, :no_local_match}

      [item | _] ->
        # Use tvdb_id if available, fall back to tmdb_id
        {provider_id, provider_type} =
          if item.tvdb_id do
            {to_string(item.tvdb_id), :tvdb}
          else
            {to_string(item.tmdb_id), :tmdb}
          end

        {:ok,
         MatchResult.new(
           provider_id: provider_id,
           provider_type: provider_type,
           title: item.title,
           year: item.year,
           match_confidence: 0.95,
           metadata: convert_db_metadata(item.metadata, item, :tv_show),
           parsed_info: parsed,
           from_local_db: true
         )}
    end
  end

  # Check if two titles match (case-insensitive, normalized)
  defp titles_match?(title1, title2) when is_binary(title1) and is_binary(title2) do
    normalized1 = normalize_title(title1)
    normalized2 = normalize_title(title2)

    # Use title similarity to allow for small differences
    # Lower threshold (0.70) to handle cases where file parser includes extra metadata tags
    title_similarity(normalized1, normalized2) >= 0.70
  end

  defp titles_match?(_title1, _title2), do: false

  # Check if years are compatible (nil means no year constraint)
  defp years_compatible?(nil, _parsed_year), do: true
  defp years_compatible?(_item_year, nil), do: true
  defp years_compatible?(item_year, parsed_year), do: abs(item_year - parsed_year) <= 1

  defp build_movie_search_opts(parsed, opts) do
    base_opts = [media_type: :movie]

    base_opts
    |> add_if_present(:year, parsed.year)
    |> Keyword.merge(Keyword.take(opts, [:language, :include_adult]))
  end

  defp build_tv_search_opts(parsed, opts) do
    base_opts = [media_type: :tv_show]

    base_opts
    |> add_if_present(:year, parsed.year)
    |> Keyword.merge(Keyword.take(opts, [:language, :include_adult, :provider]))
  end

  defp add_if_present(opts, _key, nil), do: opts
  defp add_if_present(opts, key, value), do: Keyword.put(opts, key, value)

  defp select_best_movie_match(results, parsed) do
    scored_results =
      Enum.map(results, fn result ->
        score = calculate_movie_match_score(result, parsed)
        {result, score}
      end)

    case Enum.max_by(scored_results, fn {_result, score} -> score end, fn -> nil end) do
      {best_match, score} when score >= 0.5 ->
        Logger.info("Found movie match",
          title: best_match.title,
          year: best_match.year,
          provider_id: best_match.provider_id,
          match_score: score
        )

        movie_metadata =
          MediaMetadata.from_api_response(
            Map.from_struct(best_match),
            :movie,
            to_string(best_match.provider_id)
          )

        {:ok,
         MatchResult.new(
           provider_id: to_string(best_match.provider_id),
           provider_type: :tmdb,
           title: best_match.title,
           year: best_match.year,
           match_confidence: score,
           metadata: movie_metadata,
           parsed_info: parsed
         )}

      _ ->
        Logger.warning("No confident movie match found",
          title: parsed.title,
          best_score: elem(Enum.at(scored_results, 0, {nil, 0.0}), 1)
        )

        {:error, :low_confidence_match}
    end
  end

  defp select_best_tv_match(results, parsed) do
    scored_results =
      Enum.map(results, fn result ->
        score = calculate_tv_match_score(result, parsed)
        {result, score}
      end)

    case Enum.max_by(scored_results, fn {_result, score} -> score end, fn -> nil end) do
      {best_match, score} when score >= 0.5 ->
        Logger.info("Found TV show match",
          title: best_match.title,
          year: best_match.year,
          provider_id: best_match.provider_id,
          provider: best_match.provider,
          match_score: score
        )

        tv_metadata =
          MediaMetadata.from_api_response(
            Map.from_struct(best_match),
            :tv_show,
            to_string(best_match.provider_id)
          )

        # Normalize the search result's provider to a concrete TV source.
        # TVDB results carry provider: :tvdb; TMDB results carry
        # provider: :metadata_relay, which maps to :tmdb.
        provider_type = if best_match.provider == :tvdb, do: :tvdb, else: :tmdb

        {:ok,
         MatchResult.new(
           provider_id: to_string(best_match.provider_id),
           provider_type: provider_type,
           title: best_match.title,
           year: best_match.year,
           match_confidence: score,
           match_type: :full_match,
           metadata: tv_metadata,
           parsed_info: parsed
         )}

      _ ->
        Logger.warning("No confident TV show match found",
          title: parsed.title,
          best_score: elem(Enum.at(scored_results, 0, {nil, 0.0}), 1)
        )

        {:error, :low_confidence_match}
    end
  end

  defp calculate_movie_match_score(result, parsed) do
    base_score = 0.5
    title_sim = title_similarity(result.title, parsed.title)

    score =
      base_score
      |> add_score(title_sim, 0.2)
      |> add_score(year_match?(result.year, parsed.year), 0.15)
      # Movies cannot suffer the title-tie inversion the TV scorer did -- year
      # outweighs the exact-title bonus here, so a correct-year candidate
      # already outranks a same-title wrong-year one, and TMDB does not append
      # "(YYYY)" to titles the way TVDB does. What they do share is the other
      # half: an exact title with a popular but wrong-year result reaches 0.9
      # and auto-accepts a remake as its original. Same penalty, same reason.
      |> add_score(year_contradiction?(result.year, parsed.year), -@year_contradiction_penalty)
      |> add_score(popularity_score(result.popularity), 0.1)
      # Bonus for exact title match (when search exactly matches result title)
      |> add_score(exact_title_match?(result.title, parsed.title), 0.1)
      # Penalty for derivative titles (prefer "Inception" over "Inception: The IMAX Experience")
      |> add_score(title_derivative_penalty(result.title, parsed.title), 1.0)

    min(score, 1.0)
  end

  defp calculate_tv_match_score(result, parsed) do
    # TVDB disambiguates same-title reboots by appending the premiere year to
    # the series name: the 2019 revival of "Passe-Partout" is filed as
    # "Passe-Partout (2019)" alongside the 1977 original's bare
    # "Passe-Partout". Compared verbatim, that suffix reads as a *derivative*
    # title -- the "Bluey Cookalongs" shape -- so the revival lost the exact
    # title bonus, dropped to 0.8 similarity and took the derivative penalty on
    # top, a 0.25 swing against it. The one marker that identifies the right
    # show was being scored as evidence against it. Strip it before comparing,
    # and treat the year it carries as the result's year when the provider
    # sends none of its own.
    {result_title, title_year} = split_title_year(result.title)
    result_year = result.year || title_year
    title_sim = title_similarity(result_title, parsed.title)
    base_score = 0.5

    score =
      base_score
      |> add_score(title_sim, 0.25)
      |> add_score(year_match?(result_year, parsed.year), 0.1)
      # A year we know to be wrong is not the same as a year we do not know,
      # and scoring both as a missing 0.1 bonus is what let the original
      # outrank the revival. An exact title alone floors the score at 0.9,
      # comfortably over the 0.85 auto-accept threshold, so no bonus this
      # scorer can withhold is able to overturn a title tie -- only a real
      # penalty is. TVDB never sends `popularity`, so for the whole TV path
      # the year is the *only* signal left that separates a show from its
      # reboot.
      |> add_score(year_contradiction?(result_year, parsed.year), -@year_contradiction_penalty)
      |> add_score(popularity_score(result.popularity), 0.1)
      |> add_score(result.first_air_date != nil, 0.05)
      # Bonus for exact title match (when search exactly matches result title)
      |> add_score(exact_title_match?(result_title, parsed.title), 0.15)
      # Penalty for derivative titles (prefer "Bluey" over "Bluey Cookalongs")
      |> add_score(title_derivative_penalty(result_title, parsed.title), 1.0)

    min(score, 1.0)
  end

  defp add_score(current, true, amount), do: current + amount
  defp add_score(current, score, amount) when is_float(score), do: current + score * amount
  defp add_score(current, _false_or_nil, _amount), do: current

  # Normalized popularity score using logarithmic scaling
  # Returns 0.0 to 1.0 based on TMDB popularity (typically 0-1000+)
  # Main shows like "Bluey" have popularity ~200+, spin-offs are typically <50
  defp popularity_score(nil), do: 0.0
  defp popularity_score(popularity) when popularity <= 0, do: 0.0

  defp popularity_score(popularity) do
    # Log scale: popularity of 10 = 0.25, 50 = 0.5, 200 = 0.75, 1000 = 1.0
    # Formula: min(log10(popularity) / 3, 1.0)
    min(:math.log10(popularity) / 3, 1.0)
  end

  # Check if the result title exactly matches the search query (after normalization)
  defp exact_title_match?(result_title, search_title)
       when is_binary(result_title) and is_binary(search_title) do
    norm_result = normalize_title(result_title)
    norm_search = normalize_title(search_title)
    norm_result == norm_search
  end

  defp exact_title_match?(_result_title, _search_title), do: false

  # Calculate penalty for derivative titles
  # When searching for "Bluey" and result is "Bluey Cookalongs", we want to prefer "Bluey"
  # Returns a negative value (penalty) when result title is longer than search query
  # and search query is a substring of result title
  defp title_derivative_penalty(result_title, search_title)
       when is_binary(result_title) and is_binary(search_title) do
    norm_result = String.downcase(result_title) |> String.trim()
    norm_search = String.downcase(search_title) |> String.trim()

    # Only apply penalty if search is a proper substring of result
    # (i.e., result is "Bluey Cookalongs" and search is "Bluey")
    if norm_result != norm_search and String.contains?(norm_result, norm_search) do
      # Penalty proportional to how much extra content is in the result title
      # "Bluey" (5 chars) vs "Bluey Cookalongs" (16 chars) = penalty
      search_len = String.length(norm_search)
      result_len = String.length(norm_result)
      extra_ratio = (result_len - search_len) / result_len

      # Scale to -0.15 max penalty (negative because we want to reduce score)
      -extra_ratio * 0.15
    else
      0.0
    end
  end

  defp title_derivative_penalty(_result_title, _search_title), do: 0.0

  defp title_similarity(title1, title2) when is_binary(title1) and is_binary(title2) do
    Text.title_similarity(title1, title2)
  end

  defp title_similarity(_title1, _title2), do: 0.0

  # Delegates to `Mydia.Library.Text.normalize_title/1` — the shared
  # title-normalization helper (promoted in V3 parser Unit 7).
  defp normalize_title(title), do: Text.normalize_title(title)

  defp year_match?(result_year, nil), do: result_year != nil
  defp year_match?(nil, _parsed_year), do: false

  defp year_match?(result_year, parsed_year) when is_integer(result_year) do
    # Allow ±1 year difference (for release date variations)
    abs(result_year - parsed_year) <= 1
  end

  defp year_match?(_result_year, _parsed_year), do: false

  # True only when both years are known and disagree by more than the ±1
  # release-date slack `year_match?/2` allows. Deliberately narrower than
  # `not year_match?/2`: a year missing from either side is an absence of
  # evidence and must stay unpenalised, or every show whose folder carries no
  # year would be pushed into review.
  defp year_contradiction?(result_year, parsed_year)
       when is_integer(result_year) and is_integer(parsed_year) do
    abs(result_year - parsed_year) > 1
  end

  defp year_contradiction?(_result_year, _parsed_year), do: false

  # Splits a provider's disambiguating year suffix off a title:
  # "Passe-Partout (2019)" -> {"Passe-Partout", 2019}, "Bluey" -> {"Bluey", nil}.
  # Only a trailing parenthesised four-digit year is treated this way, so a
  # genuine parenthetical ("The Office (US)") is left intact.
  defp split_title_year(title) when is_binary(title) do
    case Regex.run(~r/^(.*?)\s*\((\d{4})\)\s*$/u, title) do
      [_, bare, year] when bare != "" -> {bare, String.to_integer(year)}
      _ -> {title, nil}
    end
  end

  defp split_title_year(title), do: {title, nil}

  # Convert database metadata to MediaMetadata struct
  # If metadata is nil, create a minimal struct from the media item
  # If metadata is already a MediaMetadata struct, return it as-is
  # If metadata is a plain map, convert it using from_api_response
  defp convert_db_metadata(nil, item, media_type) do
    {provider_id, provider} = provider_id_for_item(item, media_type)

    %MediaMetadata{
      provider_id: provider_id,
      provider: provider,
      media_type: media_type,
      title: item.title,
      year: item.year
    }
  end

  defp convert_db_metadata(%MediaMetadata{} = metadata, _item, _media_type) do
    metadata
  end

  defp convert_db_metadata(metadata_map, item, media_type) when is_map(metadata_map) do
    {provider_id, _provider} = provider_id_for_item(item, media_type)
    MediaMetadata.from_api_response(metadata_map, media_type, provider_id)
  end

  defp provider_id_for_item(item, :tv_show) do
    cond do
      item.tvdb_id -> {to_string(item.tvdb_id), :tvdb}
      item.tmdb_id -> {to_string(item.tmdb_id), :tmdb}
      true -> {nil, nil}
    end
  end

  defp provider_id_for_item(item, _media_type) do
    if item.tmdb_id, do: {to_string(item.tmdb_id), :tmdb}, else: {nil, nil}
  end
end
