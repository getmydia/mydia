defmodule Mydia.Downloads.TorrentMatcher do
  @moduledoc """
  Matches parsed torrent information against library items.

  ## Multi-Layered Matching Approach

  The matcher uses a sophisticated, multi-layered approach to prevent incorrect matches
  while maintaining high accuracy:

  ### 1. Release Validation (Pre-filtering)
  Before matching begins, releases are validated to reject:
  - Hashed/obfuscated release names
  - Password-protected releases
  - Invalid naming patterns

  ### 2. ID-Based Matching (Primary - 98% confidence)
  When TMDB or IMDB IDs are available from indexer responses:
  - Matches directly against library item IDs
  - Provides highest confidence (0.98)
  - Prevents false positives from similar titles
  - Takes priority over all title-based matching

  ### 3. Title-Based Matching (Fallback)
  When ID matching is unavailable, uses sophisticated title comparison:

  #### Title Variants
  - Checks primary title, original title, and alternative/AKA titles from TMDB
  - Applies small penalty (-0.05) for alternative title matches to prefer primary

  #### String Similarity
  - Uses Jaro-Winkler distance algorithm for fuzzy matching
  - Normalizes titles: lowercase, removes articles (the/a/an), handles Unicode
  - Detects word boundary issues (e.g., "Alien" vs "Aliens")

  #### Sequel Detection
  - Identifies sequel markers: roman numerals, "Part X", "Returns", "Reloaded", etc.
  - Applies penalties (-0.4) when one title has sequel markers but not the other

  #### Year Validation (Critical for Movies)
  - Exact year match: +0.3 confidence boost
  - Within 1 year: +0.15 boost (accounts for different release dates)
  - >1 year difference: -0.5 penalty (prevents sequels/prequels)

  ### 4. TargetContext Binding
  Shortlisted candidates are re-parsed bound to their `TargetContext` (see
  `Mydia.Library.ReleaseParser`). A release whose own name does not bind to a
  candidate is demoted to suggestion-only, never a confident match.

  ## Confidence Scoring

  Movies: `(title_similarity * 0.7) + year_match + penalties`
  - Title similarity: 70% weight
  - Year validation: 30% weight
  - Penalties: sequel markers, word boundaries, alternative titles
  - Final score clamped to [0.0, 1.0]
  - Default threshold: 0.8

  TV Shows: Primarily title-based (no year weighting)

  ID-based matching prevents issues like:
  - "The Matrix" (1999) matching "The Matrix Reloaded" (2003)
  - "Alien" (1979) matching "Aliens" (1986)
  - Similar-sounding movies from different years
  """

  alias Mydia.Downloads.Structs.CandidatePool
  alias Mydia.Downloads.Structs.TorrentMatchResult
  alias Mydia.Library.ReleaseParser
  alias Mydia.Library.ReleaseParser.TargetContext
  alias Mydia.Library.Structs.ParsedFileInfo
  alias Mydia.Media
  alias Mydia.Metadata.Structs.MediaMetadata
  alias Mydia.Repo

  require Logger

  # --- TargetContext binding tuning ---
  # Max candidates re-parsed bound when the unbound title is confident enough
  # to trust a shortlist.
  @binding_shortlist_k 5
  # When the best unbound title score is below this, the shortlist is widened — a
  # weak unbound title (tracker prefix, CJK marker) may have buried the correct
  # candidate below the top-K cut.
  @binding_low_confidence 0.5
  # Hard cap on the widened shortlist. Bounds the worst case (a garbled title
  # against a large library) so binding never re-parses the whole library with
  # the heavy V3 parser, once per torrent, during an untracked scan.
  @binding_widened_max 25
  # Demoted (wrong-show) candidates are capped here: at/below the suggestion floor
  # and below the match threshold, so they surface as suggestions, never matches.
  @suggestion_floor 0.3
  # binding_confidence contributes only a small tiebreak nudge among survivors
  # that already clear the match threshold (never lifts a sub-threshold score).
  @binding_tiebreak_weight 0.05

  @type match_result :: TorrentMatchResult.t()

  @doc """
  Finds the best matching library item for parsed torrent info.

  Returns `{:ok, match}` with the best match above the confidence threshold,
  or `{:error, reason}` if no confident match is found.

  ## Matching Strategy

  1. **ID-based matching** (when available): If the torrent info includes TMDB or IMDB IDs,
     these are matched against library items first. ID matches have 0.98+ confidence.
  2. **Title-based matching** (fallback): When IDs are unavailable or don't match,
     falls back to fuzzy string matching with year validation.

  ## Options
    - `:confidence_threshold` - Minimum confidence (0.0 to 1.0) required for a match (default: 0.8)
    - `:monitored_only` - Only match against monitored items (default: true)
    - `:require_id_match` - Reject matches without ID confirmation (default: false)
  """
  def find_match(torrent_info, opts \\ []) do
    confidence_threshold = Keyword.get(opts, :confidence_threshold, 0.8)
    monitored_only = Keyword.get(opts, :monitored_only, true)
    require_id_match = Keyword.get(opts, :require_id_match, false)

    case info_kind(torrent_info) do
      :movie ->
        find_movie_match(torrent_info, monitored_only, confidence_threshold, require_id_match)

      :tv ->
        find_tv_match(torrent_info, monitored_only, confidence_threshold, require_id_match)

      :tv_season ->
        find_tv_season_match(
          torrent_info,
          monitored_only,
          confidence_threshold,
          require_id_match
        )

      # An unclassifiable release (ReleaseParser :unknown that still carried a
      # usable title) is never auto-matched — that would risk a wrong grab.
      :unknown ->
        {:error, :no_match_found}
    end
  end

  @doc """
  Finds the top N candidate matches for parsed torrent info, sorted by confidence descending.

  Unlike `find_match/2`, this does not filter by a confidence threshold — it returns
  all candidates with confidence > 0, up to `max_results`. Used for generating
  match suggestions for unmatched downloads.

  Suggestions intentionally use unbound title similarity only and do NOT apply the
  TargetContext binding veto: these are advisory candidates a human picks from, so
  surfacing a near-miss the auto-matcher would demote is acceptable (and cheaper).

  ## Options
    - `:max_results` - Maximum number of candidates to return (default: 3)
    - `:monitored_only` - Only match against monitored items (default: false)
  """
  def find_top_candidates(torrent_info, opts \\ []) do
    monitored_only = Keyword.get(opts, :monitored_only, false)

    CandidatePool.load(monitored_only: monitored_only)
    |> find_top_candidates_in(torrent_info, opts)
  end

  @doc """
  Same ranking as `find_top_candidates/2`, scored against a pre-loaded pool.

  Scores only what the pool contains, so a caller holding a stale pool gets
  stale results rather than a silent database read. `:monitored_only` is
  honoured at `CandidatePool.load/1` time and is ignored here.
  """
  @spec find_top_candidates_in(CandidatePool.t(), map(), keyword()) :: [map()]
  def find_top_candidates_in(%CandidatePool{} = pool, torrent_info, opts \\ []) do
    max_results = Keyword.get(opts, :max_results, 3)

    {items, calculate_fn} =
      case info_kind(torrent_info) do
        :movie ->
          {pool.movies, &calculate_movie_confidence(&1, torrent_info)}

        kind when kind in [:tv, :tv_season] ->
          {pool.tv_shows, &calculate_tv_show_confidence(&1, torrent_info)}

        # Unclassifiable: suggest from both pools using title similarity only, so a
        # usable-title :unknown release still surfaces candidates.
        :unknown ->
          {pool.movies ++ pool.tv_shows, &calculate_tv_show_confidence(&1, torrent_info)}
      end

    items
    |> Enum.map(fn item ->
      confidence = calculate_fn.(item)

      %{
        media_item_id: item.id,
        title: item.title,
        confidence: Float.round(confidence, 3),
        match_reason: "Title similarity: #{Float.round(confidence * 100, 1)}%"
      }
    end)
    |> Enum.filter(fn %{confidence: c} -> c > 0.3 end)
    |> Enum.sort_by(fn %{confidence: c} -> c end, :desc)
    |> Enum.take(max_results)
  end

  ## Private Functions - Movie Matching

  defp find_movie_match(torrent_info, monitored_only, threshold, require_id_match) do
    # Get all movies from the library
    movies = list_movies(monitored_only)

    # Try ID-based matching first if IDs are available
    id_match_result = try_id_based_match(torrent_info, movies, :movie)

    case id_match_result do
      {:ok, movie, confidence, reason} ->
        {:ok,
         TorrentMatchResult.new(%{
           media_item: movie,
           episode: nil,
           confidence: confidence,
           match_reason: reason
         })}

      {:error, :no_id_match} when require_id_match ->
        Logger.debug(
          "ID-based match required but not available for: #{torrent_info.title} (#{torrent_info.year})"
        )

        {:error, :no_match_found}

      {:error, :no_id_match} ->
        # Fall back to title-based matching
        find_movie_match_by_title(movies, torrent_info, threshold)
    end
  end

  defp find_movie_match_by_title(movies, torrent_info, threshold) do
    # Find potential matches with similarity scores
    matches =
      movies
      |> Enum.map(fn movie ->
        confidence = calculate_movie_confidence(movie, torrent_info)
        {movie, confidence}
      end)
      |> refine_scores_with_binding(torrent_info, threshold)
      |> Enum.filter(fn {_movie, confidence} -> confidence >= threshold end)
      |> Enum.sort_by(fn {_movie, confidence} -> confidence end, :desc)

    case matches do
      [{movie, confidence} | _] ->
        {:ok,
         TorrentMatchResult.new(%{
           media_item: movie,
           episode: nil,
           confidence: confidence,
           match_reason: build_movie_match_reason(movie, torrent_info, confidence)
         })}

      [] ->
        {:error, :no_match_found}
    end
  end

  defp calculate_movie_confidence(movie, torrent_info) do
    # Get all title variants (primary, original, and alternative titles)
    title_variants = get_title_variants(movie)

    # Calculate similarity for all title variants and take the best match
    {best_title, title_similarity, is_alternative} =
      title_variants
      |> Enum.map(fn {title, is_alt} ->
        similarity =
          string_similarity(normalize_string(title), normalize_string(torrent_info.title))

        {title, similarity, is_alt}
      end)
      |> Enum.max_by(fn {_title, similarity, _is_alt} -> similarity end)

    # Apply small penalty for alternative title matches to prefer primary titles
    alt_title_penalty = if is_alternative, do: -0.05, else: 0.0

    # Check for word boundary issues (e.g., "Alien" vs "Aliens")
    word_boundary_penalty =
      if word_boundary_substring?(best_title, torrent_info.title) do
        -0.5
      else
        0.0
      end

    # Check for sequel marker mismatches
    # If one has a sequel marker but the other doesn't, likely a sequel/prequel mismatch
    sequel_penalty =
      cond do
        # Both have sequel markers or neither has them - no penalty
        has_sequel_marker?(best_title) == has_sequel_marker?(torrent_info.title) ->
          0.0

        # One has a sequel marker but the other doesn't - likely a different movie
        # Only penalize if titles are somewhat similar (>0.7)
        title_similarity > 0.7 ->
          -0.4

        # Titles are different enough that sequel markers don't matter
        true ->
          0.0
      end

    # Year matching is critical for movies
    year_diff =
      if movie.year && torrent_info.year, do: abs(movie.year - torrent_info.year), else: nil

    year_match =
      cond do
        # Exact year match - high boost
        movie.year == torrent_info.year ->
          0.3

        # Within 1 year (sometimes release dates differ)
        year_diff && year_diff <= 1 ->
          0.15

        # Year difference >1 - significant penalty to prevent sequels
        # The larger the difference, the more likely it's a sequel/prequel
        year_diff && year_diff > 1 ->
          -0.5

        # No year available - cannot validate, small penalty
        true ->
          -0.1
      end

    # Calculate final confidence (weighted average)
    # Title is 70% weight, year is 30% weight (added as boost/penalty)
    confidence =
      title_similarity * 0.7 + year_match + sequel_penalty + word_boundary_penalty +
        alt_title_penalty

    # Clamp between 0 and 1
    max(0.0, min(1.0, confidence))
  end

  defp build_movie_match_reason(movie, torrent_info, confidence) do
    "Matched '#{torrent_info.title}' (#{torrent_info.year}) to '#{movie.title}' (#{movie.year}) with #{Float.round(confidence * 100, 1)}% confidence"
  end

  ## Private Functions - TV Show Matching

  defp find_tv_match(torrent_info, monitored_only, threshold, require_id_match) do
    # Get all TV shows from the library
    tv_shows = list_tv_shows(monitored_only)

    # Try ID-based matching first
    id_match_result = try_id_based_match(torrent_info, tv_shows, :tv)

    case id_match_result do
      {:ok, show, confidence, _reason} ->
        # Found ID match, now find the specific episode
        case find_episode(show, torrent_info) do
          {:ok, episode} ->
            {:ok,
             TorrentMatchResult.new(%{
               media_item: show,
               episode: episode,
               confidence: confidence,
               match_reason:
                 build_tv_match_reason_with_id(show, episode, torrent_info, confidence)
             })}

          {:error, :episode_not_found} ->
            {:error, :episode_not_found}
        end

      {:error, :no_id_match} when require_id_match ->
        Logger.debug(
          "ID-based match required but not available for: #{torrent_info.title} S#{torrent_info.season}E#{info_episode(torrent_info)}"
        )

        {:error, :no_match_found}

      {:error, :no_id_match} ->
        # Fall back to title-based matching
        find_tv_match_by_title(tv_shows, torrent_info, threshold)
    end
  end

  defp find_tv_match_by_title(tv_shows, torrent_info, threshold) do
    # Find potential show matches
    show_matches =
      tv_shows
      |> Enum.map(fn show ->
        confidence = calculate_tv_show_confidence(show, torrent_info)
        {show, confidence}
      end)
      |> refine_scores_with_binding(torrent_info, threshold)
      |> Enum.filter(fn {_show, confidence} -> confidence >= threshold end)
      |> Enum.sort_by(fn {_show, confidence} -> confidence end, :desc)

    case show_matches do
      [{show, confidence} | _] ->
        # Found a matching show, now find the specific episode
        case find_episode(show, torrent_info) do
          {:ok, episode} ->
            {:ok,
             TorrentMatchResult.new(%{
               media_item: show,
               episode: episode,
               confidence: confidence,
               match_reason: build_tv_match_reason(show, episode, torrent_info, confidence)
             })}

          {:error, :episode_not_found} ->
            {:error, :episode_not_found}
        end

      [] ->
        {:error, :no_match_found}
    end
  end

  defp calculate_tv_show_confidence(show, torrent_info) do
    # For TV shows, we primarily rely on title matching
    # since torrents don't include the show's year
    title_similarity =
      string_similarity(normalize_string(show.title), normalize_string(torrent_info.title))

    # TV show matching is more straightforward - just title similarity
    title_similarity
  end

  defp find_episode(show, torrent_info) do
    case Media.get_episode_by_number(show.id, torrent_info.season, info_episode(torrent_info)) do
      nil -> {:error, :episode_not_found}
      episode -> {:ok, episode}
    end
  end

  defp build_tv_match_reason(show, episode, torrent_info, confidence) do
    "Matched '#{torrent_info.title}' S#{torrent_info.season}E#{info_episode(torrent_info)} to '#{show.title}' S#{episode.season_number}E#{episode.episode_number} with #{Float.round(confidence * 100, 1)}% confidence"
  end

  ## Private Functions - TV Season Pack Matching

  defp find_tv_season_match(torrent_info, monitored_only, threshold, require_id_match) do
    # Get all TV shows from the library
    tv_shows = list_tv_shows(monitored_only)

    # Try ID-based matching first
    id_match_result = try_id_based_match(torrent_info, tv_shows, :tv_season)

    case id_match_result do
      {:ok, show, confidence, reason} ->
        {:ok,
         TorrentMatchResult.new(%{
           media_item: show,
           episode: nil,
           confidence: confidence,
           match_reason: reason
         })}

      {:error, :no_id_match} when require_id_match ->
        Logger.debug(
          "ID-based match required but not available for: #{torrent_info.title} S#{torrent_info.season}"
        )

        {:error, :no_match_found}

      {:error, :no_id_match} ->
        # Fall back to title-based matching
        find_tv_season_match_by_title(tv_shows, torrent_info, threshold)
    end
  end

  defp find_tv_season_match_by_title(tv_shows, torrent_info, threshold) do
    # Find potential show matches
    show_matches =
      tv_shows
      |> Enum.map(fn show ->
        confidence = calculate_tv_show_confidence(show, torrent_info)
        {show, confidence}
      end)
      |> refine_scores_with_binding(torrent_info, threshold)
      |> Enum.filter(fn {_show, confidence} -> confidence >= threshold end)
      |> Enum.sort_by(fn {_show, confidence} -> confidence end, :desc)

    case show_matches do
      [{show, confidence} | _] ->
        # For season packs, match the show but don't require a specific episode
        {:ok,
         TorrentMatchResult.new(%{
           media_item: show,
           episode: nil,
           confidence: confidence,
           match_reason: build_tv_season_match_reason(show, torrent_info, confidence)
         })}

      [] ->
        {:error, :no_match_found}
    end
  end

  defp build_tv_season_match_reason(show, torrent_info, confidence) do
    "Matched season pack '#{torrent_info.title}' S#{torrent_info.season} to '#{show.title}' with #{Float.round(confidence * 100, 1)}% confidence"
  end

  defp build_tv_match_reason_with_id(show, episode, torrent_info, confidence) do
    "ID-matched '#{torrent_info.title}' S#{torrent_info.season}E#{info_episode(torrent_info)} to '#{show.title}' S#{episode.season_number}E#{episode.episode_number} with #{Float.round(confidence * 100, 1)}% confidence (TMDB/IMDB ID match)"
  end

  ## Private Functions - ID-Based Matching

  @doc false
  def try_id_based_match(torrent_info, library_items, media_type) do
    # Derive TVDB/TMDB/IMDB IDs from the parsed info. ParsedFileInfo carries a
    # single `external_id` (string) + `external_provider`; legacy maps may carry
    # explicit `:tvdb_id`/`:tmdb_id`/`:imdb_id` keys. info_ids/1 normalizes both
    # and casts numeric provider IDs to integers (the find_by_* guards require it).
    {tvdb_id, tmdb_id, imdb_id} = info_ids(torrent_info)

    cond do
      # Try TVDB ID first for TV shows (most native for indexers)
      is_integer(tvdb_id) and tvdb_id > 0 ->
        case find_by_tvdb_id(library_items, tvdb_id) do
          nil ->
            Logger.info(
              "TVDB ID #{tvdb_id} from torrent not found in library for #{torrent_info.title}"
            )

            # Fall through to try TMDB ID
            try_tmdb_or_imdb_match(torrent_info, library_items, media_type, tmdb_id, imdb_id)

          item ->
            confidence = 0.98
            reason = build_id_match_reason(item, torrent_info, "TVDB ID #{tvdb_id}", media_type)
            Logger.info("Matched via TVDB ID #{tvdb_id}: #{torrent_info.title} -> #{item.title}")
            {:ok, item, confidence, reason}
        end

      # Try TMDB ID
      is_integer(tmdb_id) and tmdb_id > 0 ->
        try_tmdb_or_imdb_match(torrent_info, library_items, media_type, tmdb_id, imdb_id)

      # Try IMDB ID as fallback
      is_binary(imdb_id) and imdb_id != "" ->
        try_tmdb_or_imdb_match(torrent_info, library_items, media_type, nil, imdb_id)

      # No IDs available - fall back to title matching
      true ->
        {:error, :no_id_match}
    end
  end

  defp try_tmdb_or_imdb_match(torrent_info, library_items, media_type, tmdb_id, imdb_id) do
    cond do
      is_integer(tmdb_id) and tmdb_id > 0 ->
        case find_by_tmdb_id(library_items, tmdb_id) do
          nil ->
            Logger.info(
              "TMDB ID #{tmdb_id} from torrent not found in library for #{torrent_info.title}"
            )

            if is_binary(imdb_id) and imdb_id != "" do
              try_imdb_match(torrent_info, library_items, media_type, imdb_id)
            else
              {:error, :no_id_match}
            end

          item ->
            confidence = 0.98
            reason = build_id_match_reason(item, torrent_info, "TMDB ID #{tmdb_id}", media_type)
            Logger.info("Matched via TMDB ID #{tmdb_id}: #{torrent_info.title} -> #{item.title}")
            {:ok, item, confidence, reason}
        end

      is_binary(imdb_id) and imdb_id != "" ->
        try_imdb_match(torrent_info, library_items, media_type, imdb_id)

      true ->
        {:error, :no_id_match}
    end
  end

  defp try_imdb_match(torrent_info, library_items, media_type, imdb_id) do
    case find_by_imdb_id(library_items, imdb_id) do
      nil ->
        Logger.info(
          "IMDB ID #{imdb_id} from torrent not found in library for #{torrent_info.title}"
        )

        {:error, :no_id_match}

      item ->
        confidence = 0.98
        reason = build_id_match_reason(item, torrent_info, "IMDB ID #{imdb_id}", media_type)
        Logger.info("Matched via IMDB ID #{imdb_id}: #{torrent_info.title} -> #{item.title}")
        {:ok, item, confidence, reason}
    end
  end

  defp find_by_tmdb_id(items, tmdb_id) do
    Enum.find(items, fn item ->
      item.tmdb_id == tmdb_id
    end)
  end

  defp find_by_tvdb_id(items, tvdb_id) do
    Enum.find(items, fn item ->
      item.tvdb_id == tvdb_id
    end)
  end

  defp find_by_imdb_id(items, imdb_id) do
    Enum.find(items, fn item ->
      item.imdb_id == imdb_id
    end)
  end

  defp build_id_match_reason(item, torrent_info, id_info, media_type) do
    case media_type do
      :movie ->
        "ID-matched '#{torrent_info.title}' (#{torrent_info.year}) to '#{item.title}' (#{item.year}) via #{id_info} with 98.0% confidence"

      :tv ->
        "ID-matched '#{torrent_info.title}' S#{torrent_info.season}E#{info_episode(torrent_info)} to '#{item.title}' via #{id_info} with 98.0% confidence"

      :tv_season ->
        "ID-matched season pack '#{torrent_info.title}' S#{torrent_info.season} to '#{item.title}' via #{id_info} with 98.0% confidence"
    end
  end

  ## Private Functions - Title Variants

  # Get all title variants for a media item (primary, original, and alternative titles)
  # Returns a list of {title, is_alternative} tuples
  defp get_title_variants(media_item) do
    primary_titles =
      [
        {media_item.title, false},
        # Include original title if different from primary
        if(media_item.original_title && media_item.original_title != media_item.title,
          do: {media_item.original_title, false},
          else: nil
        )
      ]
      |> Enum.reject(&is_nil/1)

    # Get alternative titles from metadata
    alternative_titles =
      case media_item.metadata do
        %MediaMetadata{alternative_titles: alt_titles} when is_list(alt_titles) ->
          Enum.map(alt_titles, fn title -> {title, true} end)

        _ ->
          []
      end

    # Combine primary and alternative titles, ensuring uniqueness
    (primary_titles ++ alternative_titles)
    |> Enum.uniq_by(fn {title, _} -> normalize_string(title) end)
  end

  ## Private Functions - String Similarity

  defp string_similarity(str1, str2) do
    # Use Jaro-Winkler distance for better matching
    # This gives more weight to matching prefixes
    jaro_winkler_distance(str1, str2)
  end

  # Detects sequel/suffix markers in titles
  # Returns true if the title contains sequel markers like: II, 2, Part 2, Reloaded, etc.
  defp has_sequel_marker?(str) do
    normalized = String.downcase(str)

    sequel_patterns = [
      ~r/\b(ii|iii|iv|v|vi|vii|viii|ix|x)\b/,
      # Roman numerals
      ~r/\b(part|chapter|episode|volume)\s*\d+\b/,
      # Part 2, Chapter 3, etc.
      ~r/\b\d{1,2}\b/,
      # Just numbers: "2", "3", etc.
      ~r/\b(reloaded|revolutions|returns|resurrection|rises|begins|origins)\b/,
      # Common sequel words
      ~r/\b(revenge|redemption|reckoning|reborn|awakening|legacy)\b/,
      # More sequel words
      ~r/\b(quest|journey|chronicles|saga)\b/
      # Series indicators
    ]

    Enum.any?(sequel_patterns, fn pattern ->
      Regex.match?(pattern, normalized)
    end)
  end

  # Checks if one string is a word-boundary substring of another
  # Returns true specifically for cases like "alien" vs "aliens" (singular/plural)
  # where one is just the other with an 's' added
  defp word_boundary_substring?(str1, str2) do
    # Normalize both strings (remove articles, special chars) for comparison
    n1 = normalize_string(str1)
    n2 = normalize_string(str2)

    cond do
      # Exact match - not a substring issue
      n1 == n2 ->
        false

      # Check if n1 ends with 's' and n2 is the singular form (e.g., "aliens" vs "alien")
      # Only penalize if they are very similar otherwise (to avoid false positives)
      String.ends_with?(n1, "s") and String.slice(n1, 0..-2//1) == n2 ->
        # Double-check: both should be short (single word titles)
        # to avoid penalizing "Dr. Strangelove" vs "Dr. Strangelove or: ..."
        word_count_1 = length(String.split(n1, " ", trim: true))
        word_count_2 = length(String.split(n2, " ", trim: true))
        word_count_1 <= 2 and word_count_2 <= 2

      # Check if n2 ends with 's' and n1 is the singular form
      String.ends_with?(n2, "s") and String.slice(n2, 0..-2//1) == n1 ->
        word_count_1 = length(String.split(n1, " ", trim: true))
        word_count_2 = length(String.split(n2, " ", trim: true))
        word_count_1 <= 2 and word_count_2 <= 2

      # Not a singular/plural issue
      true ->
        false
    end
  end

  defp normalize_string(nil), do: ""

  defp normalize_string(str) do
    str
    |> String.downcase()
    # Normalize Unicode characters (accents, umlauts)
    |> normalize_unicode()
    # Remove common words that might cause issues
    |> String.replace(~r/\b(the|a|an)\b/, "")
    # Remove special characters
    |> String.replace(~r/[^\w\s]/, "")
    # Normalize whitespace
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Normalize Unicode characters: accents, umlauts, etc.
  defp normalize_unicode(str) do
    str
    # German umlauts
    |> String.replace("ä", "ae")
    |> String.replace("ö", "oe")
    |> String.replace("ü", "ue")
    |> String.replace("ß", "ss")
    # Common accented characters - decompose to base ASCII
    |> String.replace(~r/[àáâãäå]/u, "a")
    |> String.replace(~r/[èéêë]/u, "e")
    |> String.replace(~r/[ìíîï]/u, "i")
    |> String.replace(~r/[òóôõö]/u, "o")
    |> String.replace(~r/[ùúûü]/u, "u")
    |> String.replace(~r/[ýÿ]/u, "y")
    |> String.replace(~r/[ñ]/u, "n")
    |> String.replace(~r/[ç]/u, "c")
  end

  # Jaro-Winkler distance implementation
  # Returns a value between 0.0 (no match) and 1.0 (perfect match)
  defp jaro_winkler_distance(str1, str2) do
    # Handle edge cases
    cond do
      str1 == str2 -> 1.0
      str1 == "" or str2 == "" -> 0.0
      true -> calculate_jaro_winkler(str1, str2)
    end
  end

  defp calculate_jaro_winkler(str1, str2) do
    jaro = jaro_similarity(str1, str2)

    # Jaro-Winkler adds a prefix boost
    prefix_length = common_prefix_length(str1, str2, 4)
    prefix_scale = 0.1

    jaro + prefix_length * prefix_scale * (1.0 - jaro)
  end

  defp jaro_similarity(str1, str2) do
    len1 = String.length(str1)
    len2 = String.length(str2)

    # Match window
    match_distance = max(0, div(max(len1, len2), 2) - 1)

    # Find matches
    {matches1, matches2} = find_matches(str1, str2, match_distance)
    match_count = Enum.count(matches1, & &1)

    if match_count == 0 do
      0.0
    else
      # Count transpositions
      transpositions = count_transpositions(str1, str2, matches1, matches2)

      # Jaro similarity formula
      (match_count / len1 + match_count / len2 + (match_count - transpositions) / match_count) /
        3.0
    end
  end

  defp find_matches(str1, str2, match_distance) do
    chars1 = String.graphemes(str1)
    chars2 = String.graphemes(str2)

    # Initialize match arrays
    matches1 = List.duplicate(false, length(chars1))
    matches2 = List.duplicate(false, length(chars2))

    # Find matches
    {matches1, matches2} =
      Enum.reduce(Enum.with_index(chars1), {matches1, matches2}, fn {char1, i}, {m1, m2} ->
        start = max(0, i - match_distance)
        stop = min(i + match_distance + 1, length(chars2))

        case find_match_in_range(char1, chars2, m2, start, stop) do
          nil ->
            {m1, m2}

          j ->
            {List.replace_at(m1, i, true), List.replace_at(m2, j, true)}
        end
      end)

    {matches1, matches2}
  end

  defp find_match_in_range(char, chars, matches, start, stop) do
    Enum.find(start..(stop - 1)//1, fn j ->
      not Enum.at(matches, j) and Enum.at(chars, j) == char
    end)
  end

  defp count_transpositions(str1, str2, matches1, matches2) do
    chars1 = String.graphemes(str1)
    chars2 = String.graphemes(str2)

    # Get matched characters in order
    matched_chars1 =
      matches1
      |> Enum.with_index()
      |> Enum.filter(fn {match, _} -> match end)
      |> Enum.map(fn {_, i} -> Enum.at(chars1, i) end)

    matched_chars2 =
      matches2
      |> Enum.with_index()
      |> Enum.filter(fn {match, _} -> match end)
      |> Enum.map(fn {_, i} -> Enum.at(chars2, i) end)

    # Count transpositions
    Enum.zip(matched_chars1, matched_chars2)
    |> Enum.count(fn {c1, c2} -> c1 != c2 end)
    |> div(2)
  end

  defp common_prefix_length(str1, str2, max_length) do
    chars1 = String.graphemes(str1)
    chars2 = String.graphemes(str2)

    Enum.zip(chars1, chars2)
    |> Enum.take(max_length)
    |> Enum.take_while(fn {c1, c2} -> c1 == c2 end)
    |> length()
  end

  ## Private Functions - TargetContext binding

  # Refine base title-similarity scores by re-parsing each shortlisted candidate
  # bound to its TargetContext. Binding signals act as gates: a wrong-show parse
  # is demoted to suggestion-only (never a confident match), an implausible season
  # is penalized, and binding_confidence breaks ties among clean survivors.
  #
  # Only runs for ParsedFileInfo inputs carrying the original release name (the
  # re-parse needs it). Legacy plain-map inputs return their scores unchanged, so
  # the matcher's existing behavior — and its characterization suite — is preserved.
  defp refine_scores_with_binding(scored, %ParsedFileInfo{original_filename: name}, threshold)
       when is_binary(name) and name != "" do
    shortlist = binding_shortlist(scored)

    # Preload :episodes only for the shortlisted candidates — TargetContext needs
    # it, but loading it for every candidate (including those that never bind, or
    # when an ID match already won) is wasteful.
    preloaded_by_id =
      shortlist
      |> Enum.map(fn {item, _base} -> item end)
      |> Repo.preload(:episodes)
      |> Map.new(&{&1.id, &1})

    refined_by_id =
      Map.new(shortlist, fn {item, base} ->
        preloaded = Map.fetch!(preloaded_by_id, item.id)
        {item.id, refine_with_binding(preloaded, name, base, threshold)}
      end)

    Enum.map(scored, fn {item, base} ->
      case Map.fetch(refined_by_id, item.id) do
        {:ok, score} -> {item, score}
        :error -> {item, base}
      end
    end)
  end

  defp refine_scores_with_binding(scored, _torrent_info, _threshold), do: scored

  defp binding_shortlist(scored) do
    sorted = Enum.sort_by(scored, fn {_item, base} -> base end, :desc)

    best =
      case sorted do
        [{_item, base} | _] -> base
        [] -> 0.0
      end

    # Weak unbound title — widen the shortlist (a tracker/CJK prefix may have
    # buried the right candidate), but bound it so a garbled title can never
    # trigger a whole-library re-parse.
    limit =
      if best < @binding_low_confidence, do: @binding_widened_max, else: @binding_shortlist_k

    Enum.take(sorted, limit)
  end

  defp refine_with_binding(item, release_name, base, threshold) do
    target = TargetContext.from_media_item(item)
    bound = ReleaseParser.parse(release_name, target: target)
    flags = bound.engine_flags || %{}

    # Note on :season_out_of_range — deliberately NOT used here. That flag fires
    # when the release's season is absent from the candidate's known seasons,
    # which is the right suspicion for *library import* but inverted for
    # *downloads*: we fetch seasons we don't have yet (next season or a missing
    # middle season), so an out-of-range season is the normal case, not a
    # mismatch. Episode existence is already enforced by find_episode/2.
    cond do
      Map.get(flags, :binding_suspect) || Map.get(flags, :parsed_title_unbound) ->
        # Wrong-show guard: the release's own title doesn't bind to this candidate.
        # Demote to suggestion-only so it never clears the match threshold.
        min(base, @suggestion_floor)

      base >= threshold ->
        # Tiebreak nudge — only among candidates that already clear the threshold,
        # so binding can reorder real matches but never manufacture one from a
        # sub-threshold base.
        binding = (bound.field_confidence || %{})[:binding] || 0.0
        min(1.0, base + binding * @binding_tiebreak_weight)

      true ->
        base
    end
  rescue
    e ->
      # One bad candidate (e.g. an item whose episodes failed to preload) must not
      # fail the whole match — fall back to the unbound base score.
      Logger.warning("Binding re-parse failed for media item #{item.id}: #{inspect(e)}")
      base
  end

  ## Private Functions - ParsedFileInfo accessors

  # Classify a parsed release into the matcher's internal branch. Accepts both
  # the native ParsedFileInfo struct and legacy plain maps (used by the existing
  # characterization test suite, which already speaks :movie/:tv/:tv_season).
  defp info_kind(%ParsedFileInfo{type: :movie}), do: :movie

  defp info_kind(%ParsedFileInfo{type: :tv_show, episodes: episodes}) do
    if has_episodes?(episodes), do: :tv, else: :tv_season
  end

  defp info_kind(%ParsedFileInfo{type: :unknown}), do: :unknown
  defp info_kind(%{type: type}), do: type

  # Single episode number for season+episode lookup. ParsedFileInfo carries an
  # `episodes` list; legacy maps carry a singular `episode`.
  defp info_episode(%ParsedFileInfo{} = info), do: ParsedFileInfo.primary_episode(info)
  defp info_episode(%{episode: episode}), do: episode
  defp info_episode(_), do: nil

  defp has_episodes?(episodes) when is_list(episodes), do: episodes != []
  defp has_episodes?(_), do: false

  # Normalize external IDs to the {tvdb, tmdb, imdb} tuple the matcher's ID path
  # expects. ParsedFileInfo's `external_id` is always a string, so numeric
  # provider IDs are cast to integers (find_by_tvdb_id/find_by_tmdb_id compare
  # against integer columns). Legacy maps with explicit ID keys pass through.
  defp info_ids(%ParsedFileInfo{external_provider: provider, external_id: id}) do
    ids_from_provider(provider, id)
  end

  defp info_ids(map) when is_map(map) do
    {Map.get(map, :tvdb_id), Map.get(map, :tmdb_id), Map.get(map, :imdb_id)}
  end

  defp ids_from_provider(:tvdb, id), do: {parse_id(id), nil, nil}
  defp ids_from_provider(:tmdb, id), do: {nil, parse_id(id), nil}
  defp ids_from_provider(:imdb, id) when is_binary(id) and id != "", do: {nil, nil, id}
  defp ids_from_provider(_, _), do: {nil, nil, nil}

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    # Require a clean integer — reject "603abc" rather than silently casting to 603.
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_id(_), do: nil

  ## Private Functions - Library Queries

  # :episodes is NOT preloaded here — the binding step preloads it only for the
  # shortlisted candidates it actually re-parses (see refine_scores_with_binding/3),
  # which avoids loading every episode row for candidates that never bind.
  defp list_movies(monitored_only) do
    opts = if monitored_only, do: [type: "movie", monitored: true], else: [type: "movie"]
    Media.list_media_items(opts)
  end

  defp list_tv_shows(monitored_only) do
    opts = if monitored_only, do: [type: "tv_show", monitored: true], else: [type: "tv_show"]
    Media.list_media_items(opts)
  end
end
