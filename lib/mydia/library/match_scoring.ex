defmodule Mydia.Library.MatchScoring do
  @moduledoc """
  The scoring primitives `Mydia.Library.MetadataMatcher` builds its movie and
  TV confidence scores from: title and year comparisons against a provider
  search result, and a popularity curve. Each is a pure function of its
  arguments.
  """

  alias Mydia.Library.Text

  @doc "Adds `amount` for `true`, `score * amount` for a float score, nothing otherwise."
  def add_score(current, true, amount), do: current + amount
  def add_score(current, score, amount) when is_float(score), do: current + score * amount
  def add_score(current, _false_or_nil, _amount), do: current

  # Normalized popularity score using logarithmic scaling
  # Returns 0.0 to 1.0 based on TMDB popularity (typically 0-1000+)
  # Main shows like "Bluey" have popularity ~200+, spin-offs are typically <50
  def popularity_score(nil), do: 0.0
  def popularity_score(popularity) when popularity <= 0, do: 0.0

  def popularity_score(popularity) do
    # Log scale: popularity of 10 = 0.25, 50 = 0.5, 200 = 0.75, 1000 = 1.0
    # Formula: min(log10(popularity) / 3, 1.0)
    min(:math.log10(popularity) / 3, 1.0)
  end

  # Check if the result title exactly matches the search query (after normalization)
  def exact_title_match?(result_title, search_title)
      when is_binary(result_title) and is_binary(search_title) do
    Text.normalize_title(result_title) == Text.normalize_title(search_title)
  end

  def exact_title_match?(_result_title, _search_title), do: false

  # Calculate penalty for derivative titles
  # When searching for "Bluey" and result is "Bluey Cookalongs", we want to prefer "Bluey"
  # Returns a negative value (penalty) when result title is longer than search query
  # and search query is a substring of result title
  def title_derivative_penalty(result_title, search_title)
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

  def title_derivative_penalty(_result_title, _search_title), do: 0.0

  def title_similarity(title1, title2) when is_binary(title1) and is_binary(title2) do
    Text.title_similarity(title1, title2)
  end

  def title_similarity(_title1, _title2), do: 0.0

  def year_match?(result_year, nil), do: result_year != nil
  def year_match?(nil, _parsed_year), do: false

  def year_match?(result_year, parsed_year) when is_integer(result_year) do
    # Allow ±1 year difference (for release date variations)
    abs(result_year - parsed_year) <= 1
  end

  def year_match?(_result_year, _parsed_year), do: false

  # True only when both years are known and disagree by more than the ±1
  # release-date slack `year_match?/2` allows. Deliberately narrower than
  # `not year_match?/2`: a year missing from either side is an absence of
  # evidence and must stay unpenalised, or every show whose folder carries no
  # year would be pushed into review.
  def year_contradiction?(result_year, parsed_year)
      when is_integer(result_year) and is_integer(parsed_year) do
    abs(result_year - parsed_year) > 1
  end

  def year_contradiction?(_result_year, _parsed_year), do: false

  # Splits a provider's disambiguating year suffix off a title:
  # "Passe-Partout (2019)" -> {"Passe-Partout", 2019}, "Bluey" -> {"Bluey", nil}.
  # Only a trailing parenthesised four-digit year is treated this way, so a
  # genuine parenthetical ("The Office (US)") is left intact.
  def split_title_year(title) when is_binary(title) do
    case Regex.run(~r/^(.*?)\s*\((\d{4})\)\s*$/u, title) do
      [_, bare, year] when bare != "" -> {bare, String.to_integer(year)}
      _ -> {title, nil}
    end
  end

  def split_title_year(title), do: {title, nil}
end
