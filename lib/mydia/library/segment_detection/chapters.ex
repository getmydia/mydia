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

  ## Why an intro span is bounded but a credits span is not

  A chapter's `end_time` is where the *next* chapter begins, not where the
  named thing stops. Container chapters partition the whole timeline, so a
  correct title carries no promise of a correct span, and the two failures are
  not symmetric.

  An intro is followed by the episode body. A release that marks only
  structural points gives its opening chapter an end at the *next* marker, so
  the span swallows everything the viewer came for. Bluey ships exactly two
  chapters, `Intro` and `Credits`, which made every episode's intro 96% of its
  runtime and a Skip Intro button that ended the episode.

  Credits are the last thing in an episode. That same chapter runs to the next
  marker or to EOF, and both are where the credits genuinely end: skipping to
  either lands at the end of the file or at a post-credits scene. Across 389
  chapter-derived credits rows in a production library, none had an implausible
  span, against 128 of 402 intros. So only the intro is bounded, by 180 seconds
  absolute and 25% of runtime, whichever is tighter.

  Rejection is per chapter rather than per file, so a release whose first title
  match is implausible can still resolve on a later one. Jujutsu Kaisen labels
  its cold open `Intro` and its real 90-second theme `Opening`; bounding the
  first lets the second win.
  """

  alias Mydia.Library.Ffmpeg

  @typedoc """
  Detected segments, keyed by type, each mapped to a `{start_ms, end_ms}` tuple.

  The only keys ever produced are `"intro"` and `"credits"`, and either may be
  absent since each type resolves independently. The spec cannot say so:
  Elixir has no singleton string literal type, so every key is `String.t()` to
  the type system. The narrow contract is pinned on `classify/1`, which returns
  `:intro | :credits | :unknown`; these keys are `Atom.to_string/1` of that.
  Strings rather than atoms because the key crosses into the
  `media_segments.type` column and out through GraphQL.
  """
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

  # Ceiling on a chapter-derived intro span. Measured real intros run 40 to 90
  # seconds and the fingerprint engine has never produced one over 121s across
  # 739 production rows, so 180s leaves half again as much headroom as anything
  # observed. The fraction is what catches short-form content, where an
  # episode-swallowing span is still well under the absolute bound.
  @max_intro_ms 180_000
  @max_intro_fraction 0.25

  @doc """
  Runs ffprobe against `path` and returns any recognisable chapter segments.

  `runtime_ms` is the file's duration, used to bound the intro span. Callers
  always have one: `analyze_season/2` filters to files with a known duration
  before any chapter read happens.

  The returned map is keyed by segment type (`"intro"`, `"credits"`) with
  `{start_ms, end_ms}` values. A file with no recognisable chapters yields
  `{:ok, %{}}`, which is a successful result and not an error.
  """
  @spec detect(String.t(), non_neg_integer()) :: {:ok, segments()} | {:error, term()}
  def detect(path, runtime_ms) when is_binary(path) and is_integer(runtime_ms) do
    args = ["-v", "quiet", "-print_format", "json", "-show_chapters", path]

    case Ffmpeg.probe(args) do
      {:ok, output} -> parse_chapters(output, runtime_ms)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Parses ffprobe `-show_chapters` JSON into recognisable segments.

  Separated from `detect/2` so it can be tested against fixture JSON without
  invoking ffprobe. Each segment type resolves independently, and the first
  chapter matching a type *with a plausible span* wins: a release carrying both
  `Opening` and `Intro` is usually describing the same thing twice, but when
  the first of them is implausible it is describing something else entirely.
  """
  @spec parse_chapters(String.t(), non_neg_integer()) :: {:ok, segments()} | {:error, term()}
  def parse_chapters(json, runtime_ms) when is_binary(json) and is_integer(runtime_ms) do
    case Jason.decode(json) do
      {:ok, %{"chapters" => chapters}} when is_list(chapters) ->
        {:ok, Enum.reduce(chapters, %{}, &collect(&1, &2, max_intro_ms(runtime_ms)))}

      {:ok, _without_chapters} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The longest span a chapter-derived intro may claim for a file of `runtime_ms`.

  Public so the backfill that clears already-stored bad spans applies the same
  rule this module enforces, rather than a second copy that could drift.
  """
  @spec max_intro_ms(non_neg_integer()) :: non_neg_integer()
  def max_intro_ms(runtime_ms) when is_integer(runtime_ms) and runtime_ms > 0 do
    min(@max_intro_ms, round(runtime_ms * @max_intro_fraction))
  end

  def max_intro_ms(_unknown_runtime), do: @max_intro_ms

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

  defp collect(chapter, acc, max_intro_ms) do
    with type when type != :unknown <- classify(chapter_title(chapter)),
         key = Atom.to_string(type),
         false <- Map.has_key?(acc, key),
         {:ok, start_ms} <- to_ms(chapter["start_time"]),
         {:ok, end_ms} <- to_ms(chapter["end_time"]),
         true <- end_ms > start_ms,
         true <- plausible?(type, end_ms - start_ms, max_intro_ms) do
      Map.put(acc, key, {start_ms, end_ms})
    else
      _no_usable_span -> acc
    end
  end

  defp plausible?(:intro, span_ms, max_intro_ms), do: span_ms <= max_intro_ms
  defp plausible?(:credits, _span_ms, _max_intro_ms), do: true

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
