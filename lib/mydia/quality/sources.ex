defmodule Mydia.Quality.Sources do
  @moduledoc """
  The release-source vocabulary: every source label the release parser emits,
  which of them are cam-tier, and `detect/1` for callers that only want the
  source of a name.

  Detection is not done here. `detect/1` reads the source that
  `Mydia.Indexers.QualityParser.parse/1` reports, which is
  `Mydia.Library.ReleaseParser` with its token table in
  `priv/release_parser/sources.exs`. A search result's quality, a profile's
  `excluded_sources` check and an on-disk file's cam-tier fallback therefore
  all read one tokenizer, and a spelling fixed there is fixed for all three.

  ## Cam-tier precision

  A false cam-tier detection silently refuses a legitimate release with no way
  for the operator to find out why; a missed one lets one bad release through.
  The parser leans toward precision accordingly, and the cases in
  `test/mydia/quality/sources_test.exs` pin it:

  - Cam-tier letters inside ordinary words (`Ghosts`, `Watchmen`, `Scream`)
    are not tokens, so they never match.
  - The short scene forms (`TS`, `TC`, `SCR`, `WP`, `CAM`) count only as
    whole capitalised tokens. A lowercase `ts` or `cam` is a word, not a tag.
  - The hyphenated group position (`x264-TS`) is a release group, and the
    first word of a title (`Ts.Marlow`) is title zone, so neither is a source.
  - A cam-tier word inside an episode title (`S02E03.Cam.and.Mitch`) is part
    of that title.
  - Every good source outranks every cam-tier one, so an explicit `BluRay`
    wins over a cam-tier token elsewhere in the name.
  """

  alias Mydia.Indexers.QualityParser

  @cam_tier ["CAM", "Telesync", "Telecine", "Screener", "Workprint"]

  # Display order for source pickers: good sources first, roughly best to
  # worst, then the cam-tier ones.
  @all [
    "REMUX",
    "BluRay",
    "WEB-DL",
    "WEBRip",
    "HDTV",
    "SDTV",
    "DVDRip",
    "Screener",
    "DVD",
    "Telecine",
    "Telesync",
    "CAM",
    "Workprint",
    "PDTV"
  ]

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
  Every source label `detect/1` can return, in display order.
  """
  @spec all() :: [String.t()]
  def all, do: @all

  @doc """
  Detects the source of a release name, or `nil` when no source token is found.

  This is `Mydia.Indexers.QualityParser.parse/1`'s source, so the two can
  never disagree.

      iex> Mydia.Quality.Sources.detect("Movie.2026.1080p.BluRay.x264")
      "BluRay"

      iex> Mydia.Quality.Sources.detect("Movie.2026.1080p.TELESYNC.x264")
      "Telesync"

      iex> Mydia.Quality.Sources.detect("Movie.2026.1080p.x264")
      nil
  """
  @spec detect(String.t()) :: String.t() | nil
  def detect(title) when is_binary(title), do: QualityParser.parse(title).source

  def detect(_), do: nil
end
