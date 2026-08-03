defmodule Mydia.Library.SegmentDetection.Chapters do
  @moduledoc """
  Reads container chapter markers and classifies them as intro or credits.

  Many well-mastered releases label their opening and ending. Reading those
  labels costs milliseconds and is strictly more accurate than any heuristic,
  so this runs before the fingerprinting path. Recall is limited (a sizeable
  share of files carry no chapter markers at all), which is why it is a fast
  path rather than the engine.

  Resolution is per segment type. A file whose chapters name an opening but not
  an ending resolves only `"intro"`, and its credits window still needs
  fingerprinting.

  ## Why matching is on whole titles

  A survey of 60 episode files from a real library found 129 titled chapters.
  The near misses are more common than the true positives:

    * `Prologue` (16 occurrences) is the cold open that runs *before* the
      opening theme. Calling it an intro would skip real story content.
    * `Preview` (15) is the next-episode teaser that runs *after* the ending.
    * `Epilogue` (12) is a post-credits scene.

  Compare those against `Intro` (2) and `Credits` (2): a sloppy matcher is
  wrong far more often than it is right on this data.

  So the title is lowercased, stripped of accents and punctuation, split into
  tokens, and the whole token sequence is compared for equality against the
  known titles. Nothing is ever matched as a substring, and no single token in
  a longer title is enough on its own:

    * Substring matching would be catastrophic for the two-letter titles.
      `OP` and `ED` occur inside a large fraction of English words, so `ed`
      alone would match `Wedding` and `Predator`, and `op` would match `Stop`
      and `Cooper`.
    * Matching any single token would still be wrong for the longer words.
      `The Credits Union Heist` contains the token `credits` but is a plot
      chapter, and `Opening Credits` has to resolve as an intro rather than as
      credits, which only the full sequence can decide.
  """

  alias Mydia.Library.Ffmpeg

  @typedoc "Segment type key (intro or credits) mapped to a {start_ms, end_ms} tuple."
  @type segments :: %{optional(String.t()) => {non_neg_integer(), non_neg_integer()}}

  # Normalised (lowercase, unaccented, punctuation-free) whole titles.
  @intro_titles [
    "intro",
    "opening",
    "op",
    "opening credits",
    "opening titles",
    "main titles",
    "title sequence",
    "theme",
    "opening theme",
    "vorspann",
    "generique de debut",
    "sigla iniziale",
    "apertura"
  ]

  @credits_titles [
    "credits",
    "end credits",
    "ending",
    "ed",
    "closing credits",
    "closing",
    "end titles",
    "outro",
    "ending theme",
    "abspann",
    "generique de fin",
    "sigla finale",
    "creditos finales"
  ]

  @doc """
  Runs ffprobe against `path` and returns any recognisable chapter segments.

  The returned map is keyed by segment type (`"intro"`, `"credits"`) with
  `{start_ms, end_ms}` values. A file with no recognisable chapters yields
  `{:ok, %{}}`, which is a successful result and not an error.
  """
  @spec detect(String.t()) :: {:ok, segments()} | {:error, term()}
  def detect(path) when is_binary(path) do
    args = ["-v", "quiet", "-print_format", "json", "-show_chapters", path]

    case Ffmpeg.probe(args) do
      {:ok, output} -> parse_chapters(output)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Parses ffprobe `-show_chapters` JSON into recognisable segments.

  Separated from `detect/1` so it can be tested against fixture JSON without
  invoking ffprobe. Each segment type resolves independently, and the first
  chapter matching a type wins: a release carrying both `Opening` and `Intro`
  is describing the same thing twice.
  """
  @spec parse_chapters(String.t()) :: {:ok, segments()} | {:error, term()}
  def parse_chapters(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"chapters" => chapters}} when is_list(chapters) ->
        {:ok, Enum.reduce(chapters, %{}, &collect/2)}

      {:ok, _without_chapters} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Classifies a chapter title as `:intro`, `:credits`, or `:unknown`.

  Comparison is against the whole normalised title. Accents and punctuation are
  stripped so "Générique de début" matches, and standalone numbers are dropped
  so the numbered variants common in anime ("OP1", "Ending 2") match their
  unnumbered form. No substring matching is done, and a matching token inside a
  longer title is not a match.
  """
  @spec classify(String.t() | nil) :: :intro | :credits | :unknown
  def classify(nil), do: :unknown

  def classify(title) when is_binary(title) do
    case normalise(title) do
      normalised when normalised in @intro_titles -> :intro
      normalised when normalised in @credits_titles -> :credits
      _unrecognised -> :unknown
    end
  end

  defp collect(chapter, acc) do
    with type when type != :unknown <- classify(chapter_title(chapter)),
         key = Atom.to_string(type),
         false <- Map.has_key?(acc, key),
         {:ok, start_ms} <- to_ms(chapter["start_time"]),
         {:ok, end_ms} <- to_ms(chapter["end_time"]),
         true <- end_ms > start_ms do
      Map.put(acc, key, {start_ms, end_ms})
    else
      _no_usable_span -> acc
    end
  end

  defp chapter_title(%{"tags" => %{"title" => title}}) when is_binary(title), do: title
  defp chapter_title(_chapter), do: nil

  defp to_ms(value) when is_binary(value) do
    # Float.parse/1 accepts a partial parse, so "12.3oops" comes back as
    # {12.3, "oops"}. Treat leftover text as malformed rather than silently
    # trusting the prefix: a wrong timestamp is worse than no timestamp,
    # because it ships a skip button that jumps to the wrong place.
    case Float.parse(value) do
      {seconds, rest} ->
        if String.trim(rest) == "", do: {:ok, round(seconds * 1000)}, else: :error

      :error ->
        :error
    end
  end

  defp to_ms(value) when is_number(value), do: {:ok, round(value * 1000)}
  defp to_ms(_value), do: :error

  # Lowercase, strip accents, split letter/digit runs apart ("ED1" -> "ed 1"),
  # replace punctuation with whitespace, then drop standalone numbers so
  # variant numbering does not defeat the match.
  defp normalise(title) do
    title
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
    |> String.replace(~r/(\p{L})(\p{N})/u, "\\1 \\2")
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split()
    |> Enum.reject(&number?/1)
    |> Enum.join(" ")
  end

  defp number?(token), do: String.match?(token, ~r/\A\p{N}+\z/u)
end
