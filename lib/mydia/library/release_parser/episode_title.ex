defmodule Mydia.Library.ReleaseParser.EpisodeTitle do
  @moduledoc """
  Recovers the episode title that follows the `SxxEyy` marker in a filename.

  `TitleAssembler.assemble/2` is not reusable here. It renders tokens whose
  byte offset falls *before* a boundary, because it exists to recover the show
  title preceding the episode marker. The episode title is on the other side of
  that anchor.

  The rule is the classifier's own output. In the metadata zone a token
  receives candidates only when an anchor or the vocabulary recognised it, so
  resolution, source, codec and release-group tokens carry candidates while
  ordinary title words carry none. The unclassified run immediately after the
  marker is therefore exactly the episode title, and a scene release with no
  title yields nothing at all.

  Kept deliberately separate from `TitleAssembler`: the show-title path is
  covered by the corpus and parity gates, and widening it to serve a second
  caller would put those gates at risk for no gain.
  """

  alias Mydia.Library.ReleaseParser.{Classifier, Token, Tokenizer}

  # `:season_marker` is part of `Candidate.label()`'s type, but
  # `Classifier.classify/2` never emits it on this path — only anchor
  # tagging (`:year` / `:resolution` / `:episode_marker`) and vocabulary
  # lookups produce candidates here, and neither ever yields
  # `:season_marker`. `Resolver`, a later stage this module never calls,
  # is the only place that label appears. Kept in the list defensively.
  @marker_labels [:episode_marker, :season_marker]

  # A single `SxxEyy` match can span more than one token: the tokenizer's
  # marker regex allows `[-\s.]?` between `S` and `E` (and between a
  # multi-episode tail like `.E06`), so a delimiter inside the match splits
  # it across tokens. `Tokenizer.anchor_positions/1` records only the
  # match's *starting* byte offset, and `Classifier.anchor_label_for/6`
  # tags only the one token whose byte range contains that offset — so
  # `S04.E01` tags `S04` and leaves `E01` with `candidates: []`,
  # indistinguishable from a title word. After dropping the tagged marker
  # token, also drop any immediately following bare season/episode
  # fragments before treating the rest as title. This can also eat a
  # genuine title that opens with a bare number directly adjacent to the
  # marker (no separator token in between); that trade-off is accepted
  # because the delimiter-split case is the common one.
  @marker_fragment ~r/\A[SE]?\d{1,4}\z/i

  # `-` is not a tokenizer delimiter, so a dash-separated name leaves a bare
  # `-` token at either end of the title run. Dropped at the token level —
  # never by trimming the joined string — so real punctuation that lives
  # inside a token's value (a trailing `!` or `?`, neither a delimiter) is
  # never touched.
  @bare_punctuation ~r/\A[\s\-_.,:;!?'"]+\z/u

  @doc """
  The episode title in `filename`, or `nil` when there is none to recover.
  """
  @spec extract(String.t() | nil) :: String.t() | nil
  def extract(nil), do: nil

  def extract(filename) when is_binary(filename) do
    anchors = Tokenizer.anchor_positions(filename)

    filename
    |> Tokenizer.tokenize()
    |> Classifier.classify(anchors)
    |> after_episode_marker()
    |> Enum.take_while(&unclassified?/1)
    |> render()
  end

  # Drops everything up to and including the classifier-tagged marker
  # token, then any residual marker-fragment tokens left over when the
  # tokenizer split a single `SxxEyy` match across more than one token.
  defp after_episode_marker(tokens) do
    case Enum.split_while(tokens, &(not marker?(&1))) do
      {_before, []} ->
        []

      {_before, [_marker | rest]} ->
        rest
        |> Enum.drop_while(&marker?/1)
        |> Enum.drop_while(&marker_fragment?/1)
    end
  end

  defp marker?(%Token{candidates: candidates}) do
    Enum.any?(candidates, &(&1.label in @marker_labels))
  end

  defp marker_fragment?(%Token{value: value}), do: String.match?(value, @marker_fragment)

  defp unclassified?(%Token{candidates: []}), do: true
  defp unclassified?(%Token{}), do: false

  defp render([]), do: nil

  defp render(tokens) do
    case trim_bare_punctuation(tokens) do
      [] -> nil
      trimmed -> trimmed |> Enum.map_join(" ", & &1.value) |> nil_if_empty()
    end
  end

  defp trim_bare_punctuation(tokens) do
    tokens
    |> Enum.drop_while(&bare_punctuation?/1)
    |> Enum.reverse()
    |> Enum.drop_while(&bare_punctuation?/1)
    |> Enum.reverse()
  end

  defp bare_punctuation?(%Token{value: value}), do: String.match?(value, @bare_punctuation)

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(value), do: value
end
