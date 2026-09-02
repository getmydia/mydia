defmodule Mydia.Library.Text do
  @moduledoc """
  Shared text-normalization and similarity helpers for the Library
  domain.

  Promoted from `Mydia.Library.MetadataMatcher` as part of the V3
  release-parser migration (Unit 7) so that the parser, metadata
  matcher, and search seam can all canonicalize titles the same way.

  ## Normalization pipeline

  `normalize_title/1` applies, in order:

  1. Lowercase via `String.downcase/1`.
  2. Roman numeral conversion for sequels (`II..X` → `2..10`).
  3. Replace `&` with `"and"`.
  4. Unicode NFKD normalization (`:unicode.characters_to_nfd_binary/1`).
  5. Accent folding — strip combining marks (`\p{Mn}`).
  6. Leading-article rotation (`"The Matrix"` → `"matrix the"`).
  7. Strip punctuation (keep only word characters + whitespace).
  8. Collapse whitespace.

  ## Similarity

  `title_similarity/2` returns a float in `[0.0, 1.0]` using the
  same staged comparison the metadata matcher uses (light
  normalization → full normalization → Jaro distance). No threshold is
  baked in — callers decide what value to gate on (the metadata
  matcher's `same_title?/2` keeps using 0.70).
  """

  @doc """
  Normalize a title for comparison.

  Returns a canonicalized string that is byte-comparable across
  variants such as `"The Matrix"` / `"Matrix, The"` / `"Pokémon"` /
  `"Pokemon"` / `"Spider-Man II"` / `"Spider-Man 2"`.

  ## Examples

      iex> Mydia.Library.Text.normalize_title("The Matrix")
      "matrix the"

      iex> Mydia.Library.Text.normalize_title("Pokémon")
      "pokemon"

      iex> Mydia.Library.Text.normalize_title("Spider-Man II")
      "spiderman 2"
  """
  @spec normalize_title(String.t()) :: String.t()
  def normalize_title(title) when is_binary(title) do
    title
    |> String.downcase()
    |> convert_roman_numerals()
    |> String.replace(~r/\s+&\s+/, " and ")
    |> nfkd_normalize()
    |> strip_combining_marks()
    |> normalize_articles()
    |> String.replace(~r/[^\w\s]/u, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @doc """
  Compute title similarity in `[0.0, 1.0]`.

  Strategy:

  - `0.0` when either side is empty.
  - `1.0` when both sides are byte-equal after light downcase + collapse.
  - `0.8` when one normalized form contains the other (light).
  - `1.0` when both sides are byte-equal after full `normalize_title/1`.
  - `0.9` when one full-normalized form contains the other.
  - Otherwise Jaro distance of the fully-normalized strings.

  This matches the existing `MetadataMatcher.title_similarity/2`
  behavior — callers decide what threshold to gate on.
  """
  @spec title_similarity(String.t(), String.t()) :: float()
  def title_similarity(title1, title2) when is_binary(title1) and is_binary(title2) do
    light1 = light_normalize(title1)
    light2 = light_normalize(title2)

    cond do
      light1 == "" or light2 == "" ->
        0.0

      light1 == light2 ->
        1.0

      String.contains?(light1, light2) or String.contains?(light2, light1) ->
        0.8

      true ->
        norm1 = normalize_title(title1)
        norm2 = normalize_title(title2)

        cond do
          norm1 == norm2 -> 1.0
          String.contains?(norm1, norm2) or String.contains?(norm2, norm1) -> 0.9
          true -> String.jaro_distance(norm1, norm2)
        end
    end
  end

  def title_similarity(_title1, _title2), do: 0.0

  @doc """
  Fraction of `library_title`'s significant words that appear in `release_title`.

  One-directional on purpose. Extra words on the release side are normal:
  subtitles, edition markers, and release cruft the parser did not strip.
  A word missing from the release side means the release is a different work.
  A symmetric measure cannot express that difference, which is why this is not
  a Jaccard or F1 score.

  Normalization differs from `normalize_title/1` in three ways that are
  load-bearing:

    * punctuation becomes whitespace instead of vanishing, so `"Iron-Ridge"`
      and `"Iron Ridge"` agree rather than becoming `ironridge` and
      `iron ridge`
    * German umlauts expand before accent folding, so `"Bäume"` and
      `"Baeume"` agree rather than becoming `baume` and `baeume`
    * articles are dropped rather than rotated to the end, so a stray `the`
      cannot change the score depending on which side carried it

  Returns `0.0` when either side has no significant words.
  """
  @spec title_token_coverage(String.t(), String.t()) :: float()
  def title_token_coverage(library_title, release_title)
      when is_binary(library_title) and is_binary(release_title) do
    library_tokens = coverage_tokens(library_title)
    release_tokens = coverage_tokens(release_title)

    if MapSet.size(library_tokens) == 0 or MapSet.size(release_tokens) == 0 do
      0.0
    else
      matched =
        library_tokens
        |> MapSet.intersection(release_tokens)
        |> MapSet.size()

      matched / MapSet.size(library_tokens)
    end
  end

  def title_token_coverage(_library_title, _release_title), do: 0.0

  # ---- Internals ----

  defp light_normalize(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/u, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp convert_roman_numerals(title) do
    Enum.reduce(roman_replacements(), title, fn {pattern, replacement}, acc ->
      String.replace(acc, pattern, replacement)
    end)
  end

  # Roman numerals at word boundaries, ordered longest-first so `IX`
  # doesn't match before `IX` is tried.
  defp roman_replacements do
    [
      {~r/\bX\b/i, "10"},
      {~r/\bIX\b/i, "9"},
      {~r/\bVIII\b/i, "8"},
      {~r/\bVII\b/i, "7"},
      {~r/\bVI\b/i, "6"},
      {~r/\bV\b/i, "5"},
      {~r/\bIV\b/i, "4"},
      {~r/\bIII\b/i, "3"},
      {~r/\bII\b/i, "2"}
      # Single "I" is too ambiguous ("I" as pronoun) — leave it alone.
    ]
  end

  # NFKD-normalize so composed and decomposed forms compare equal
  # after accent folding. `:unicode.characters_to_nfd_binary/1` raises
  # on invalid input — for the title-normalization use case, raising
  # loudly is preferable to silently producing garbage.
  defp nfkd_normalize(title) do
    :unicode.characters_to_nfd_binary(title)
  end

  # Strip Unicode combining marks (category Mn). After NFD/NFKD this
  # removes accents while preserving the base letter.
  defp strip_combining_marks(title) do
    String.replace(title, ~r/\p{Mn}+/u, "")
  end

  # Move leading articles (the / a / an) to the end:
  # `"The Matrix"` → `"matrix the"`.
  defp normalize_articles(title) do
    case Regex.run(~r/^(the|a|an)\s+(.+)$/i, title) do
      [_, article, rest] -> "#{rest} #{article}"
      _ -> title
    end
  end

  # Articles carry no identifying signal and appear on one side as often as
  # both. Dropping them beats `normalize_articles/1`'s rotation here, which
  # would leave a `the` token in one set and not the other.
  @coverage_stopwords MapSet.new(~w(the a an))

  # Umlaut expansion must run before `nfkd_normalize/1`, which would otherwise
  # fold "ä" to a bare "a". Mirrors the order in
  # `Mydia.Downloads.TorrentMatcher.normalize_unicode/1`, whose behaviour the
  # matcher's existing tests depend on.
  defp coverage_tokens(title) do
    title
    |> String.downcase()
    |> convert_roman_numerals()
    |> String.replace(~r/\s+&\s+/, " and ")
    |> expand_umlauts()
    |> nfkd_normalize()
    |> strip_combining_marks()
    |> String.replace(~r/[^\w\s]/u, " ")
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.reject(&insignificant_token?/1)
    |> MapSet.new()
  end

  defp insignificant_token?(token) do
    String.length(token) < 2 or MapSet.member?(@coverage_stopwords, token)
  end

  defp expand_umlauts(title) do
    title
    |> String.replace("ä", "ae")
    |> String.replace("ö", "oe")
    |> String.replace("ü", "ue")
    |> String.replace("ß", "ss")
  end
end
