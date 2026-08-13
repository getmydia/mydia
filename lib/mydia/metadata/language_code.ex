defmodule Mydia.Metadata.LanguageCode do
  @moduledoc """
  Maps configured language codes to the form TVDB uses, selects a translation
  from a TVDB translation bundle by an ordered preference list, and decides
  whether two language tags name the same language.

  The configured metadata language arrives as a BCP-47 / ISO 639-1 value
  (e.g. `"en-US"`, `"de"`, `"ja-JP"`), while TVDB extended endpoints key
  their translation arrays off ISO 639-2/T 3-letter codes (`"eng"`, `"deu"`,
  `"jpn"`). This module bridges the two and centralizes the selection logic
  that was previously duplicated (and hardcoded to English) across the relay
  transform and the season/episode structs.

  `matches?/2` serves a different consumer: matching a configured audio
  language against the tag ffprobe read off a media file. That needs a wider
  table than TVDB does, and specifically needs ISO 639-2/B (bibliographic)
  codes, because Matroska writes `"ger"` and `"fre"` where the /T variants
  are `"deu"` and `"fra"`. Keeping both tables here means one place to look
  when a language does not match; `@iso_639_1_to_639_2` stays narrow so TVDB
  lookups keep their existing behaviour.
  """

  # ISO 639-1 (primary subtag) -> ISO 639-2/T, covering the metadata config's
  # supported language set. TVDB v4 uses the /T ("terminological") variant.
  @iso_639_1_to_639_2 %{
    "en" => "eng",
    "es" => "spa",
    "fr" => "fra",
    "de" => "deu",
    "it" => "ita",
    "pt" => "por",
    "ja" => "jpn",
    "zh" => "zho",
    "ko" => "kor",
    "ru" => "rus"
  }

  @doc """
  Maps a BCP-47 / ISO 639-1 language code to its TVDB (ISO 639-2/T) 3-letter
  code, stripping any region suffix. Returns `nil` for unknown or blank input
  so callers can skip that tier of the fallback chain.

  ## Examples

      iex> Mydia.Metadata.LanguageCode.to_tvdb_code("en-US")
      "eng"

      iex> Mydia.Metadata.LanguageCode.to_tvdb_code("de")
      "deu"

      iex> Mydia.Metadata.LanguageCode.to_tvdb_code("xx")
      nil
  """
  def to_tvdb_code(code) when is_binary(code) do
    primary =
      code
      |> String.downcase()
      |> String.split(["-", "_"], parts: 2)
      |> List.first()

    Map.get(@iso_639_1_to_639_2, primary)
  end

  def to_tvdb_code(_), do: nil

  @doc """
  Returns the ordered list of TVDB language codes to try for a configured or
  original-language value. TVDB's translation keys are mostly ISO 639-2/T
  3-letter codes, but it is inconsistent — Portuguese appears as both `"por"`
  and `"pt"`, and some shows carry only one of them. So each language expands to
  both its 3-letter and 2-letter forms; the form TVDB didn't use simply never
  matches. Accepts 2-letter (`"pt-BR"`, TMDB) or 3-letter (`"jpn"`, TVDB) input.
  Returns `[]` for blank or `nil` input.

  ## Examples

      iex> Mydia.Metadata.LanguageCode.tvdb_candidates("pt-BR")
      ["por", "pt"]

      iex> Mydia.Metadata.LanguageCode.tvdb_candidates("jpn")
      ["jpn"]
  """
  def tvdb_candidates(code) when is_binary(code) do
    primary =
      code
      |> String.downcase()
      |> String.split(["-", "_"], parts: 2)
      |> List.first()

    [to_tvdb_code(primary), primary]
    |> Enum.reject(fn c -> is_nil(c) or c == "" end)
    |> Enum.uniq()
  end

  def tvdb_candidates(_), do: []

  @doc """
  Extracts a show's original-language code from a metadata struct or map,
  returning `nil` when absent or blank. Nil-safe so callers can thread it into
  fetch options without guarding the metadata themselves.
  """
  def original_language_from(%{original_language: lang})
      when is_binary(lang) and lang != "",
      do: lang

  # Some paths carry metadata as a string-key map rather than a MediaMetadata struct.
  def original_language_from(%{"original_language" => lang})
      when is_binary(lang) and lang != "",
      do: lang

  def original_language_from(_), do: nil

  @doc """
  Selects a field value from a TVDB translation list by trying each preferred
  language code in order. TVDB translation entries look like
  `%{"language" => "eng", "name" => "..."}`. Returns the first non-empty match,
  or `nil` when no preferred code has a usable value (callers fall back to the
  raw field).

  `preferred_codes` is an ordered list of 3-letter codes, e.g.
  `["spa", "jpn", "eng"]` for "Spanish, then original, then English".
  """
  def select_translation(translations, field, preferred_codes)
      when is_list(translations) and is_list(preferred_codes) do
    Enum.find_value(preferred_codes, fn code ->
      case Enum.find(translations, fn t -> t["language"] == code end) do
        %{} = translation ->
          value = translation[field]
          if is_binary(value) and value != "", do: value

        _ ->
          nil
      end
    end)
  end

  def select_translation(_translations, _field, _preferred_codes), do: nil

  # ISO 639-1 -> every 3-letter form that names the same language. Where a
  # language has both a terminological (/T) and a bibliographic (/B) code,
  # both are listed, /T first. Matroska and ffprobe overwhelmingly write /B,
  # so omitting those would leave German and French tracks unmatchable.
  #
  # Wider than @iso_639_1_to_639_2 because that map answers "what does TVDB
  # call this", bounded by the languages mydia offers for metadata, while this
  # one answers "is this the same language as that", bounded only by what
  # someone might have muxed into a file.
  @equivalents %{
    "af" => ["afr"],
    "am" => ["amh"],
    "ar" => ["ara"],
    "az" => ["aze"],
    "be" => ["bel"],
    "bg" => ["bul"],
    "bn" => ["ben"],
    "bs" => ["bos"],
    "ca" => ["cat"],
    "cs" => ["ces", "cze"],
    "cy" => ["cym", "wel"],
    "da" => ["dan"],
    "de" => ["deu", "ger"],
    "el" => ["ell", "gre"],
    "en" => ["eng"],
    "eo" => ["epo"],
    "es" => ["spa"],
    "et" => ["est"],
    "eu" => ["eus", "baq"],
    "fa" => ["fas", "per"],
    "fi" => ["fin"],
    "fr" => ["fra", "fre"],
    "ga" => ["gle"],
    "gl" => ["glg"],
    "gu" => ["guj"],
    "ha" => ["hau"],
    "he" => ["heb"],
    "hi" => ["hin"],
    "hr" => ["hrv"],
    "hu" => ["hun"],
    "hy" => ["hye", "arm"],
    "id" => ["ind"],
    "ig" => ["ibo"],
    "is" => ["isl", "ice"],
    "it" => ["ita"],
    "ja" => ["jpn"],
    "ka" => ["kat", "geo"],
    "kk" => ["kaz"],
    "km" => ["khm"],
    "kn" => ["kan"],
    "ko" => ["kor"],
    "la" => ["lat"],
    "lo" => ["lao"],
    "lt" => ["lit"],
    "lv" => ["lav"],
    "mi" => ["mri", "mao"],
    "mk" => ["mkd", "mac"],
    "ml" => ["mal"],
    "mn" => ["mon"],
    "mr" => ["mar"],
    "ms" => ["msa", "may"],
    "my" => ["mya", "bur"],
    "ne" => ["nep"],
    "nl" => ["nld", "dut"],
    "no" => ["nor"],
    "pa" => ["pan"],
    "pl" => ["pol"],
    "pt" => ["por"],
    "ro" => ["ron", "rum"],
    "ru" => ["rus"],
    "si" => ["sin"],
    "sk" => ["slk", "slo"],
    "sl" => ["slv"],
    "sq" => ["sqi", "alb"],
    "sr" => ["srp"],
    "sv" => ["swe"],
    "sw" => ["swa"],
    "ta" => ["tam"],
    "te" => ["tel"],
    "th" => ["tha"],
    "tl" => ["tgl"],
    "tr" => ["tur"],
    "uk" => ["ukr"],
    "ur" => ["urd"],
    "uz" => ["uzb"],
    "vi" => ["vie"],
    "xh" => ["xho"],
    "yi" => ["yid"],
    "yo" => ["yor"],
    "zh" => ["zho", "chi"],
    "zu" => ["zul"]
  }

  # Reverse index, so a 3-letter tag resolves back to its 2-letter form
  # without scanning the map on every comparison.
  @three_to_two Map.new(
                  for {two, threes} <- @equivalents, three <- threes do
                    {three, two}
                  end
                )

  @doc """
  Every code naming the same language as `code`, including `code` itself,
  lowercased and with any region suffix stripped.

  Accepts ISO 639-1 (`"de"`), BCP-47 (`"pt-BR"`), ISO 639-2/T (`"deu"`) or
  ISO 639-2/B (`"ger"`). Unknown codes return just themselves, so an
  unrecognised tag still matches an identical one.

  ## Examples

      iex> Mydia.Metadata.LanguageCode.equivalents("de")
      ["de", "deu", "ger"]

      iex> Mydia.Metadata.LanguageCode.equivalents("ger")
      ["de", "deu", "ger"]

      iex> Mydia.Metadata.LanguageCode.equivalents("pt-BR")
      ["pt", "por"]

      iex> Mydia.Metadata.LanguageCode.equivalents("kling")
      ["kling"]
  """
  @spec equivalents(String.t() | nil) :: [String.t()]
  def equivalents(code) when is_binary(code) do
    primary =
      code
      |> String.downcase()
      |> String.trim()
      |> String.split(["-", "_"], parts: 2)
      |> List.first()

    equivalents_for_primary(primary)
  end

  def equivalents(_), do: []

  # "und" is ffprobe's explicit "undetermined" tag, and a bare "" is what a
  # file with no language tag at all yields. Neither names a language, so
  # neither may satisfy a request for one.
  defp equivalents_for_primary(primary) when primary in ["", "und"], do: []

  defp equivalents_for_primary(primary) do
    case Map.get(@equivalents, primary) do
      nil ->
        # Either a 3-letter tag, or something not in the table at all.
        case Map.get(@three_to_two, primary) do
          nil -> [primary]
          two -> [two | Map.fetch!(@equivalents, two)]
        end

      threes ->
        [primary | threes]
    end
  end

  @doc """
  Whether two language tags name the same language, across ISO 639-1,
  639-2/T, 639-2/B and BCP-47 region suffixes.

  Blank or `nil` on either side is never a match: an untagged audio track must
  not satisfy a viewer's request for a specific language.

  ## Examples

      iex> Mydia.Metadata.LanguageCode.matches?("en", "eng")
      true

      iex> Mydia.Metadata.LanguageCode.matches?("de", "ger")
      true

      iex> Mydia.Metadata.LanguageCode.matches?("pt-BR", "por")
      true

      iex> Mydia.Metadata.LanguageCode.matches?("en", "rus")
      false

      iex> Mydia.Metadata.LanguageCode.matches?("en", nil)
      false
  """
  @spec matches?(String.t() | nil, String.t() | nil) :: boolean()
  def matches?(a, b) when is_binary(a) and is_binary(b) do
    case {equivalents(a), equivalents(b)} do
      {[], _} -> false
      {_, []} -> false
      {left, right} -> Enum.any?(left, &(&1 in right))
    end
  end

  def matches?(_, _), do: false
end
