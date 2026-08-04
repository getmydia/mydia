defmodule Mydia.Quality.Sources do
  @moduledoc """
  The single source-detection vocabulary for release names.

  Every consumer that needs to know whether a release is a BluRay, a WEB-DL, or
  a camcorder recording goes through this module. Before it existed the project
  had three independent implementations that disagreed with each other.

  ## Why the short tokens are delimiter-anchored

  Scene names abbreviate Telesync to `TS`, Telecine to `TC`, Workprint to `WP`,
  and Screener to `SCR`. Matching those as bare substrings misclassifies
  ordinary words: `Ghosts` contains `ts`, `Watchmen` contains `tc`, `Scream`
  contains `scr`.

  Word boundaries alone are still not enough, because `\\bts\\b` matches the
  release-group suffix in `Some.Movie.2020.1080p.x264-TS` and the leading word
  in `Ts.Madison.Show.2021.1080p.x264`.

  So the ambiguous short tokens require a dot, space, or bracket on both sides,
  which excludes the hyphenated group position and the start of the string.
  Unambiguous long forms (`telesync`, `workprint`, `hdcam`) keep plain `\\b`.

  The tradeoff is deliberate: a genuine telesync marked only as `-TS` in the
  group position is not detected. A false negative means one bad release slips
  through, which is the pre-existing behavior anyway. A false positive means a
  legitimate release is silently refused with no way for the operator to find
  out why. Precision wins.
  """

  @cam_tier ["CAM", "Telesync", "Telecine", "Screener", "Workprint"]

  @doc """
  The release types that are camcorder or pre-release captures rather than
  clean digital sources.

      iex> Mydia.Quality.Sources.cam_tier()
      ["CAM", "Telesync", "Telecine", "Screener", "Workprint"]
  """
  @spec cam_tier() :: [String.t()]
  def cam_tier, do: @cam_tier

  @doc """
  Whether a detected source label is cam-tier. `nil` is not cam-tier.

      iex> Mydia.Quality.Sources.cam_tier?("Telesync")
      true

      iex> Mydia.Quality.Sources.cam_tier?("BluRay")
      false

      iex> Mydia.Quality.Sources.cam_tier?(nil)
      false
  """
  @spec cam_tier?(String.t() | nil) :: boolean()
  def cam_tier?(nil), do: false
  def cam_tier?(source) when is_binary(source), do: source in @cam_tier

  @doc """
  Every source label this module can detect, in match order.
  """
  @spec all() :: [String.t()]
  def all, do: Enum.map(patterns(), fn {label, _pattern} -> label end)

  @doc """
  Detects the source of a release name, or `nil` when no source token is found.

  Matching is first-wins in table order, so a name carrying an explicit good
  source token resolves to that source even if a cam-tier abbreviation also
  appears later in the string.

      iex> Mydia.Quality.Sources.detect("Movie.2026.1080p.BluRay.x264")
      "BluRay"

      iex> Mydia.Quality.Sources.detect("Movie.2026.1080p.TELESYNC.x264")
      "Telesync"

      iex> Mydia.Quality.Sources.detect("Movie.2026.1080p.x264")
      nil
  """
  @spec detect(String.t()) :: String.t() | nil
  def detect(title) when is_binary(title) do
    Enum.find_value(patterns(), fn {label, pattern} ->
      if Regex.match?(pattern, title), do: label
    end)
  end

  def detect(_), do: nil

  @doc """
  The label/pattern table, in match order.

  Order is load-bearing in two places:

  1. `Screener` sits above `DVD`, otherwise `DVDScr` matches the bare `dvd`
     pattern first and resolves to `DVD`.
  2. Every good source is checked before every cam-tier source, so an explicit
     `BluRay` token beats a `-TS` release-group suffix.
  """
  @spec patterns() :: [{String.t(), Regex.t()}]
  def patterns do
    [
      {"REMUX", ~r/remux/i},
      {"BluRay", ~r/blu[\-\s]?ray|bluray|bdrip|brrip|bd(?:$|[\.\s])/i},
      {"WEB-DL", ~r/web[\-\s]?dl|webdl/i},
      {"WEBRip", ~r/web[\-\s]?rip|webrip/i},
      {"HDTV", ~r/hdtv/i},
      {"SDTV", ~r/sdtv/i},
      {"DVDRip", ~r/dvd[\-\s]?rip|dvdrip/i},
      # Screener must precede DVD so DVDScr does not match the bare dvd pattern.
      {"Screener", ~r/\b(?:dvd|bd|web)scr(?:eener)?\b|\bscreener\b|#{delimited("scr")}/i},
      {"DVD", ~r/dvd/i},
      {"Telecine", ~r/\btelecine\b|\bhd\-?tc\b|#{delimited("tc")}/i},
      {"Telesync", ~r/\btelesync\b|\bhd\-?ts\b|\bpdvd\b|\bpredvd\b|#{delimited("ts")}/i},
      {"CAM", ~r/\bhd\-?cam\b|\bcam\-?rip\b|\bhqcam\b|#{delimited("cam")}/i},
      {"Workprint", ~r/\bworkprint\b|#{delimited("wp")}/i},
      {"PDTV", ~r/pdtv/i}
    ]
  end

  # Requires a dot, space, or bracket on both sides of the token. This excludes
  # the hyphenated release-group position (`x264-TS`) and the start of the
  # string (`Ts.Madison`), both of which plain \b would match.
  defp delimited(token), do: "(?<=[.\\s\\[])#{token}(?=[.\\s\\]]|$)"
end
