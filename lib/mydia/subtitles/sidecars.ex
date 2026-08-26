defmodule Mydia.Subtitles.Sidecars do
  @moduledoc """
  Adopts subtitle files that already sit next to a media file.

  `Mydia.Library.Scanner` only indexes video extensions, and the `subtitles`
  table is written by exactly one function, `Mydia.Subtitles.Downloader.download/3`.
  Anyone arriving from Plex or Jellyfin with `Movie.en.srt` beside `Movie.mkv`
  therefore gets nothing. This module closes that gap.
  """

  @extensions ~w(.srt .ass .ssa .vtt)

  # A fixed table, never `String.to_atom/1` on a filename fragment. Keys are
  # matched downcased. ISO 639-2 codes and English names both map onto the
  # 639-1 code the rest of the system uses.
  @languages %{
    "en" => "en",
    "eng" => "en",
    "english" => "en",
    "es" => "es",
    "spa" => "es",
    "esp" => "es",
    "spanish" => "es",
    "fr" => "fr",
    "fra" => "fr",
    "fre" => "fr",
    "french" => "fr",
    "de" => "de",
    "deu" => "de",
    "ger" => "de",
    "german" => "de",
    "it" => "it",
    "ita" => "it",
    "italian" => "it",
    "pt" => "pt",
    "por" => "pt",
    "portuguese" => "pt",
    "nl" => "nl",
    "nld" => "nl",
    "dut" => "nl",
    "dutch" => "nl",
    "sv" => "sv",
    "swe" => "sv",
    "swedish" => "sv",
    "da" => "da",
    "dan" => "da",
    "danish" => "da",
    "no" => "no",
    "nor" => "no",
    "norwegian" => "no",
    "fi" => "fi",
    "fin" => "fi",
    "finnish" => "fi",
    "pl" => "pl",
    "pol" => "pl",
    "polish" => "pl",
    "ru" => "ru",
    "rus" => "ru",
    "russian" => "ru",
    "ja" => "ja",
    "jpn" => "ja",
    "japanese" => "ja",
    "ko" => "ko",
    "kor" => "ko",
    "korean" => "ko",
    "zh" => "zh",
    "chi" => "zh",
    "zho" => "zh",
    "chinese" => "zh",
    "ar" => "ar",
    "ara" => "ar",
    "arabic" => "ar",
    "he" => "he",
    "heb" => "he",
    "hebrew" => "he",
    "hi" => "hi",
    "hin" => "hi",
    "hindi" => "hi",
    "tr" => "tr",
    "tur" => "tr",
    "turkish" => "tr",
    "cs" => "cs",
    "ces" => "cs",
    "cze" => "cs",
    "czech" => "cs",
    "el" => "el",
    "ell" => "el",
    "gre" => "el",
    "greek" => "el",
    "hu" => "hu",
    "hun" => "hu",
    "hungarian" => "hu",
    "ro" => "ro",
    "ron" => "ro",
    "rum" => "ro",
    "romanian" => "ro",
    "th" => "th",
    "tha" => "th",
    "thai" => "th",
    "uk" => "uk",
    "ukr" => "uk",
    "ukrainian" => "uk",
    "vi" => "vi",
    "vie" => "vi",
    "vietnamese" => "vi"
  }

  @forced_tags ~w(forced)
  @hearing_impaired_tags ~w(sdh cc)

  @doc "The sidecar file extensions this module adopts."
  @spec extensions() :: [String.t()]
  def extensions, do: @extensions

  @doc """
  Reads language and flags out of a sidecar filename.

  `media_basename` is the media file's name with its own extension removed,
  and may itself contain dots (`Some.Movie.2019.1080p`). Everything between
  it and the subtitle extension is a dot-separated tag list, matched against
  `basename` case-insensitively.

  An unrecognized tag is ignored rather than treated as a language, so
  `Movie.HDR.en.srt` still resolves to `en`. A file with no recognizable
  language tag resolves to `"und"`.

  Note the collision between the ISO 639-1 code for Hindi and the common
  shorthand for "hearing impaired", both spelled `hi`. It reads as a
  language, because that tag position means language and Hindi subtitles
  are real; `sdh` and `cc` remain unambiguous. A file wanting both says
  `Movie.hi.sdh.srt`.
  """
  @spec parse_filename(String.t(), String.t()) :: %{
          language: String.t(),
          forced: boolean(),
          hearing_impaired: boolean()
        }
  def parse_filename(basename, media_basename) do
    tags =
      basename
      |> Path.rootname()
      |> String.downcase()
      |> String.replace_prefix(String.downcase(media_basename), "")
      |> String.split(".", trim: true)

    %{
      language: Enum.find_value(tags, "und", &Map.get(@languages, &1)),
      forced: Enum.any?(tags, &(&1 in @forced_tags)),
      hearing_impaired: Enum.any?(tags, &(&1 in @hearing_impaired_tags))
    }
  end
end
