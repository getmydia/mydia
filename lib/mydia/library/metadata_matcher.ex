defmodule Mydia.Library.MetadataMatcher do
  @moduledoc """
  Matches parsed file information to metadata provider entries (TMDB/TVDB).

  This module takes parsed file information from `FileParser` and searches
  metadata providers to find the best match. It uses:
  - Title and year information for matching
  - Confidence scoring to determine match quality
  - Fallback strategies when exact matches aren't found
  """

  require Logger
  alias Mydia.{Media, Metadata}
  alias Mydia.Library.FileParser.V2, as: FileParser
  alias Mydia.Library.Structs.MatchResult

  @type match_result :: MatchResult.t()

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

    # Parse the file name
    parsed = FileParser.parse(file_path)

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
  """
  @spec match_movie(map(), map(), keyword()) :: {:ok, match_result()} | {:error, term()}
  def match_movie(%{type: :movie} = parsed, config, opts \\ []) do
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

    case Metadata.search(config, parsed.title, search_opts) do
      {:ok, []} ->
        # Try without year if we got no results
        if parsed.year do
          Logger.debug("No results with year, retrying without year",
            title: parsed.title,
            year: parsed.year
          )

          retry_opts = Keyword.delete(search_opts, :year)

          case Metadata.search(config, parsed.title, retry_opts) do
            {:ok, results} when length(results) > 0 ->
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
  """
  @spec match_tv_show(map(), map(), keyword()) :: {:ok, match_result()} | {:error, term()}
  def match_tv_show(%{type: :tv_show} = parsed, config, opts \\ []) do
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

    case Metadata.search(config, parsed.title, search_opts) do
      {:ok, []} ->
        # Try without year if we got no results
        if parsed.year do
          Logger.debug("No TV show results with year, retrying without year",
            title: parsed.title,
            year: parsed.year
          )

          retry_opts = Keyword.delete(search_opts, :year)

          case Metadata.search(config, parsed.title, retry_opts) do
            {:ok, results} when length(results) > 0 ->
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
          {:ok, match} = success ->
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
      [media_type: :tv_show] |> Keyword.merge(Keyword.take(opts, [:language, :include_adult]))

    case Metadata.search(config, parsed.title, search_opts) do
      {:ok, results} when length(results) > 0 ->
        # Find best matching series
        case find_best_series_match(results, parsed) do
          {:ok, series} ->
            Logger.info("Found series-level match for future/unreleased episode",
              series_title: series.title,
              parsed_season: parsed.season,
              parsed_episodes: parsed.episodes
            )

            # Return partial match result
            {:ok,
             MatchResult.new(
               provider_id: to_string(series.provider_id),
               provider_type: :tmdb,
               title: series.title,
               year: series.year,
               match_confidence: 0.70,
               # Lower confidence for partial match
               match_type: :partial_match,
               partial_reason: :episode_not_found,
               metadata: series,
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

  # Find the best matching series from search results
  defp find_best_series_match(results, parsed) do
    scored_results =
      Enum.map(results, fn result ->
        score = calculate_series_match_score(result, parsed)
        {result, score}
      end)

    case Enum.max_by(scored_results, fn {_result, score} -> score end, fn -> nil end) do
      {best_match, score} when score >= 0.5 ->
        {:ok, best_match}

      _ ->
        {:error, :low_confidence_match}
    end
  end

  # Calculate match score for series-level matching
  defp calculate_series_match_score(result, parsed) do
    base_score = 0.5

    score =
      base_score
      |> add_score(title_similarity(result.title, parsed.title), 0.35)
      |> add_score(year_match?(result.year, parsed.year), 0.1)
      |> add_score(result.popularity > 10, 0.05)

    min(score, 1.0)
  end

  # Try to find a matching movie in the local database
  defp find_local_movie(parsed) do
    # Search for movies with matching title (case-insensitive)
    media_items =
      Media.list_media_items()
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
        {:ok,
         MatchResult.new(
           provider_id: to_string(item.tmdb_id),
           provider_type: :tmdb,
           title: item.title,
           year: item.year,
           match_confidence: 0.95,
           metadata: item.metadata || %{},
           parsed_info: parsed,
           from_local_db: true
         )}
    end
  end

  # Try to find a matching TV show in the local database
  defp find_local_tv_show(parsed) do
    # Search for TV shows with matching title (case-insensitive)
    media_items =
      Media.list_media_items()
      |> Enum.filter(fn item ->
        item.type == "tv_show" &&
          titles_match?(item.title, parsed.title) &&
          years_compatible?(item.year, parsed.year)
      end)

    case media_items do
      [] ->
        {:error, :no_local_match}

      [item | _] ->
        # Found a match! Return a match_result struct
        {:ok,
         MatchResult.new(
           provider_id: to_string(item.tmdb_id),
           provider_type: :tmdb,
           title: item.title,
           year: item.year,
           match_confidence: 0.95,
           metadata: item.metadata || %{},
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
    |> Keyword.merge(Keyword.take(opts, [:language, :include_adult]))
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

        {:ok,
         MatchResult.new(
           provider_id: to_string(best_match.provider_id),
           provider_type: :tmdb,
           title: best_match.title,
           year: best_match.year,
           match_confidence: score,
           metadata: best_match,
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
          match_score: score
        )

        {:ok,
         MatchResult.new(
           provider_id: to_string(best_match.provider_id),
           provider_type: :tmdb,
           title: best_match.title,
           year: best_match.year,
           match_confidence: score,
           match_type: :full_match,
           metadata: best_match,
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

    score =
      base_score
      |> add_score(title_similarity(result.title, parsed.title), 0.3)
      |> add_score(year_match?(result.year, parsed.year), 0.15)
      |> add_score(result.popularity > 10, 0.05)

    min(score, 1.0)
  end

  defp calculate_tv_match_score(result, parsed) do
    base_score = 0.5

    score =
      base_score
      |> add_score(title_similarity(result.title, parsed.title), 0.3)
      |> add_score(year_match?(result.year, parsed.year), 0.1)
      |> add_score(result.popularity > 10, 0.05)
      |> add_score(Map.get(result, :first_air_date) != nil, 0.05)

    min(score, 1.0)
  end

  defp add_score(current, true, amount), do: current + amount
  defp add_score(current, score, amount) when is_float(score), do: current + score * amount
  defp add_score(current, _false_or_nil, _amount), do: current

  defp title_similarity(title1, title2) when is_binary(title1) and is_binary(title2) do
    # Check for substring match on lightly normalized versions first
    # (before removing articles, which can affect substring matching)
    light_norm1 = String.downcase(title1) |> String.replace(~r/[^\w\s]/, "") |> String.trim()
    light_norm2 = String.downcase(title2) |> String.replace(~r/[^\w\s]/, "") |> String.trim()

    cond do
      # Exact match on light normalization
      light_norm1 == light_norm2 ->
        1.0

      # Substring match on light normalization
      String.contains?(light_norm1, light_norm2) || String.contains?(light_norm2, light_norm1) ->
        0.8

      # Otherwise, do full normalization for fuzzy matching
      true ->
        # Normalize both titles with article removal and roman numeral conversion
        norm1 = normalize_title(title1)
        norm2 = normalize_title(title2)

        cond do
          # Exact match after full normalization
          norm1 == norm2 ->
            1.0

          # Substring match after full normalization
          String.contains?(norm1, norm2) || String.contains?(norm2, norm1) ->
            0.9

          # Jaro distance for fuzzy matching
          true ->
            jaro_similarity(norm1, norm2)
        end
    end
  end

  defp title_similarity(_title1, _title2), do: 0.0

  defp normalize_title(title) do
    title
    |> String.downcase()
    # Convert roman numerals to numbers (common in movie sequels)
    |> convert_roman_numerals()
    # Normalize "and" vs "&"
    |> String.replace(~r/\s+&\s+/, " and ")
    # Move leading articles to the end: "The Matrix" -> "Matrix The"
    |> normalize_articles()
    # Remove all punctuation
    |> String.replace(~r/[^\w\s]/, "")
    # Normalize whitespace
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Convert common roman numerals to arabic numbers
  defp convert_roman_numerals(title) do
    # Match roman numerals at word boundaries (often used for sequels)
    # Handle I through X (1-10), which covers most movie sequels
    replacements = [
      {~r/\bX\b/i, "10"},
      {~r/\bIX\b/i, "9"},
      {~r/\bVIII\b/i, "8"},
      {~r/\bVII\b/i, "7"},
      {~r/\bVI\b/i, "6"},
      {~r/\bV\b/i, "5"},
      {~r/\bIV\b/i, "4"},
      {~r/\bIII\b/i, "3"},
      {~r/\bII\b/i, "2"}
      # Note: Don't replace single "I" as it's too ambiguous (could be "I" as in "me")
    ]

    Enum.reduce(replacements, title, fn {pattern, replacement}, acc ->
      String.replace(acc, pattern, replacement)
    end)
  end

  # Move leading articles (the, a, an) to the end: "The Matrix" -> "Matrix The"
  defp normalize_articles(title) do
    case Regex.run(~r/^(the|a|an)\s+(.+)$/i, title) do
      [_, article, rest] -> "#{rest} #{article}"
      _ -> title
    end
  end

  defp year_match?(result_year, nil), do: result_year != nil
  defp year_match?(nil, _parsed_year), do: false

  defp year_match?(result_year, parsed_year) when is_integer(result_year) do
    # Allow ±1 year difference (for release date variations)
    abs(result_year - parsed_year) <= 1
  end

  defp year_match?(_result_year, _parsed_year), do: false

  # Simple Jaro similarity implementation
  # Returns a value between 0.0 (no match) and 1.0 (exact match)
  defp jaro_similarity(s1, s2) do
    len1 = String.length(s1)
    len2 = String.length(s2)

    # Empty strings
    if len1 == 0 and len2 == 0, do: 1.0
    if len1 == 0 or len2 == 0, do: 0.0

    # Match window
    match_distance = max(div(max(len1, len2), 2) - 1, 0)

    s1_chars = String.graphemes(s1)
    s2_chars = String.graphemes(s2)

    {matches, transpositions} = calculate_matches(s1_chars, s2_chars, match_distance)

    if matches == 0 do
      0.0
    else
      (matches / len1 + matches / len2 + (matches - transpositions) / matches) / 3
    end
  end

  defp calculate_matches(s1_chars, s2_chars, match_distance) do
    len1 = length(s1_chars)
    len2 = length(s2_chars)

    s1_matches = List.duplicate(false, len1)
    s2_matches = List.duplicate(false, len2)

    # Find matches
    {matches, s1_matches, s2_matches} =
      Enum.reduce(0..(len1 - 1), {0, s1_matches, s2_matches}, fn i, {match_count, s1m, s2m} ->
        char1 = Enum.at(s1_chars, i)
        range_start = max(0, i - match_distance)
        range_end = min(i + match_distance + 1, len2)

        case find_match_in_range(char1, s2_chars, s2m, range_start, range_end) do
          {:ok, j} ->
            {match_count + 1, List.replace_at(s1m, i, true), List.replace_at(s2m, j, true)}

          :not_found ->
            {match_count, s1m, s2m}
        end
      end)

    # Count transpositions
    transpositions = count_transpositions(s1_chars, s2_chars, s1_matches, s2_matches)

    {matches, div(transpositions, 2)}
  end

  defp find_match_in_range(char, chars, matches, range_start, range_end) do
    Enum.reduce_while(range_start..(range_end - 1), :not_found, fn j, _acc ->
      if !Enum.at(matches, j) and Enum.at(chars, j) == char do
        {:halt, {:ok, j}}
      else
        {:cont, :not_found}
      end
    end)
  end

  defp count_transpositions(s1_chars, s2_chars, s1_matches, s2_matches) do
    s1_matched =
      Enum.zip(s1_chars, s1_matches) |> Enum.filter(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))

    s2_matched =
      Enum.zip(s2_chars, s2_matches) |> Enum.filter(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))

    Enum.zip(s1_matched, s2_matched)
    |> Enum.count(fn {c1, c2} -> c1 != c2 end)
  end
end
